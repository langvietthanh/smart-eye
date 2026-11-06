import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../utils/image_utils.dart';
import 'depth_analysis.dart';
import 'processing_worker.dart';

/// Monocular relative depth (MiDaS v2.1 small, 256×256 NHWC float32) in its
/// own background isolate, run less often than object detection.
class DepthService {
  static const String _modelPath = 'assets/models/midas_small.tflite';
  // Weights stored as float16 (tool/tflite_fp16_weights.py); I/O stays float32.

  ProcessingWorker<_DepthRequest, DepthReading?>? _worker;
  Future<void>? _loading;
  bool _disposed = false;
  bool _busy = false;

  bool get isLoaded => _worker != null && !_disposed;
  bool get busy => _busy;

  Future<void> loadModel() {
    if (_disposed) return Future.error(StateError('Depth is disposed'));
    if (isLoaded) return Future.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    final model = await rootBundle.load(_modelPath);
    if (_disposed) return;
    final worker = await ProcessingWorker.start(
      _DepthProcessor(
        model.buffer.asUint8List(model.offsetInBytes, model.lengthInBytes),
      ),
    );
    if (_disposed) {
      await worker.close();
    } else {
      _worker = worker;
    }
  }

  /// Null when unavailable, busy, or the frame could not be read.
  Future<DepthReading?> analyze(CameraImage image, int rotationDegrees) async {
    final worker = _worker;
    if (_disposed || worker == null || _busy) return null;
    _busy = true;
    try {
      final reading = await worker.run(_DepthRequest(image, rotationDegrees));
      return _disposed ? null : reading;
    } finally {
      _busy = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    try {
      await _loading;
    } catch (_) {
      // A failed load already released its worker.
    }
    final worker = _worker;
    _worker = null;
    await worker?.close();
  }
}

class _DepthRequest {
  const _DepthRequest(this.image, this.rotation);
  final CameraImage image;
  final int rotation;
}

class _DepthProcessor implements IsolateProcessor<_DepthRequest, DepthReading?> {
  _DepthProcessor(this._modelBytes);

  // ImageNet normalisation used to train MiDaS, in 0..1 units.
  static const _mean = [0.485, 0.456, 0.406];
  static const _std = [0.229, 0.224, 0.225];

  Uint8List? _modelBytes;
  Interpreter? _interpreter;
  final List<Delegate> _delegates = [];
  late Tensor _input;
  late Tensor _output;
  late int _size;
  late Uint8List _inputBuffer;
  late Float32List _inputFloats;

  @override
  void initialize() {
    try {
      final options = InterpreterOptions()..threads = 2;
      try {
        if (Platform.isAndroid || Platform.isIOS) {
          // Leave the remaining cores to object detection.
          final xnn = XNNPackDelegateOptions(numThreads: 2);
          try {
            _delegates.add(XNNPackDelegate(options: xnn));
          } finally {
            xnn.delete();
          }
          options.addDelegate(_delegates.last);
        }
        _interpreter = Interpreter.fromBuffer(_modelBytes!, options: options);
      } finally {
        options.delete();
      }
      _input = _interpreter!.getInputTensor(0);
      _output = _interpreter!.getOutputTensor(0);
      final shape = _input.shape;
      if (shape.length != 4 ||
          shape[3] != 3 ||
          shape[1] != shape[2] ||
          _input.type != TensorType.float32 ||
          _output.type != TensorType.float32) {
        throw UnsupportedError('Depth model không hỗ trợ: $shape');
      }
      _size = shape[1];
      _inputBuffer = Uint8List(3 * _size * _size * 4);
      _inputFloats = _inputBuffer.buffer.asFloat32List();
    } catch (_) {
      dispose();
      rethrow;
    } finally {
      _modelBytes = null;
    }
  }

  @override
  DepthReading? process(_DepthRequest request) {
    final bytes = ImageUtils.cameraImageToModelBytes(
      request.image,
      size: _size,
      channelsFirst: false,
      inputType: TensorType.float32,
      scale: 0,
      zeroPoint: 0,
      rotationDegrees: request.rotation,
      outputBuffer: _inputBuffer,
    );
    if (bytes == null) return null;
    for (int i = 0; i < _inputFloats.length; i++) {
      final c = i % 3;
      _inputFloats[i] = (_inputFloats[i] - _mean[c]) / _std[c];
    }
    _input.data = _inputBuffer;
    _interpreter!.invoke();
    final depth = Float32List.view(
      Uint8List.fromList(_output.data).buffer,
      0,
      _size * _size,
    );
    return DepthAnalysis.analyze(depth, _size, _size);
  }

  @override
  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    for (final delegate in _delegates.reversed) {
      delegate.delete();
    }
    _delegates.clear();
  }
}
