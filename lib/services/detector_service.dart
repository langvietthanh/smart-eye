import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../models/Recognition.dart';
import '../utils/image_utils.dart';
import '../utils/label_catalog.dart';
import 'processing_worker.dart';

/// Dịch vụ nhận diện vật thể dùng YOLOv8 TFLite.
/// Kích thước input, layout (NCHW/NHWC) và kiểu dữ liệu được đọc từ chính model,
/// nên đổi model (320/640, float/int8) không cần sửa code.
class DetectorService {
  static const String _modelPath = 'assets/models/yolov8n_int8.tflite';
  static const String _labelPath = 'assets/labels/coco.txt';

  ProcessingWorker<_DetectionRequest, _DetectionResult>? _worker;
  Future<void>? _loading;
  Future<void>? _disposing;
  bool _disposed = false;
  bool _busy = false;

  bool get isLoaded => _worker != null && !_disposed;
  int lastFrameMs = 0;
  double lastMaxScore = 0;
  String lastMaxLabel = '';

  Future<void> loadModel() {
    if (_disposed) return Future.error(StateError('Detector is disposed'));
    if (isLoaded) return Future.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    // Asset access stays on the root isolate. Native model creation and all
    // frame processing happen in the same persistent background isolate.
    final model = await rootBundle.load(_modelPath);
    final labels = (await rootBundle.loadString(_labelPath))
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (_disposed) return;
    final worker = await ProcessingWorker.start(
      _DetectorProcessor(
        model.buffer.asUint8List(model.offsetInBytes, model.lengthInBytes),
        labels,
      ),
    );
    if (_disposed) {
      await worker.close();
    } else {
      _worker = worker;
    }
  }

  Future<List<Recognition>> detect({
    required CameraImage image,
    required double screenWidth,
    required double screenHeight,
    int rotationDegrees = 90,
  }) async {
    final worker = _worker;
    if (_disposed || worker == null || _busy) return [];
    _busy = true;
    try {
      final result = await worker.run(
        _DetectionRequest(image, screenWidth, screenHeight, rotationDegrees),
      );
      if (_disposed) return [];
      lastFrameMs = result.elapsedMs;
      lastMaxScore = result.maxScore;
      lastMaxLabel = result.maxLabel;
      return result.detections;
    } finally {
      _busy = false;
    }
  }

  Future<void> dispose() {
    _disposed = true;
    return _disposing ??= _dispose();
  }

  Future<void> _dispose() async {
    try {
      await _loading;
    } catch (_) {
      // A failed initialization already disposes its worker resources.
    }
    final worker = _worker;
    _worker = null;
    await worker?.close();
  }
}

class _DetectionRequest {
  const _DetectionRequest(this.image, this.width, this.height, this.rotation);
  final CameraImage image;
  final double width;
  final double height;
  final int rotation;
}

class _DetectionResult {
  const _DetectionResult(
    this.detections,
    this.elapsedMs,
    this.maxScore,
    this.maxLabel,
  );
  final List<Recognition> detections;
  final int elapsedMs;
  final double maxScore;
  final String maxLabel;
}

class _DetectorProcessor
    implements IsolateProcessor<_DetectionRequest, _DetectionResult> {
  _DetectorProcessor(this._modelBytes, this._labels);

  Uint8List? _modelBytes;
  final List<String> _labels;
  final List<Delegate> _delegates = [];

  // Ngưỡng lọc — 0.25 là mặc định Ultralytics. Đo trên COCO128 (xem README):
  // 0.15 → precision 0.71, 149 box sai; 0.25 → precision 0.83, 64 box sai, recall vật lớn gần như giữ nguyên.
  static const double _confidenceThreshold = 0.25;
  static const double _iouThreshold = 0.45;

  // Các class ID liên quan đến an toàn/di chuyển của người mù
  static const Set<int> _relevantClasses = {
    0, 1, 2, 3, 5, 6, 7, // person, bicycle, car, motorcycle, bus, train, truck
    9, 10, 11, 13, // traffic light, fire hydrant, stop sign, bench
    15, 16, // cat, dog
    56, 57, 58, 60, // chair, couch, potted plant, dining table
  };

  Interpreter? _interpreter;
  late Uint8List _inputBuffer;
  late Tensor _inputTensor;
  late Tensor _outputTensor;
  int _frameCount = 0;

  // Thông tin model đọc lúc load
  int _inputSize = 0;
  bool _channelsFirst = false;
  TensorType _inputType = TensorType.float32;
  double _inputScale = 0;
  int _inputZeroPoint = 0;

  // Chẩn đoán hiển thị trên màn hình
  int lastFrameMs = 0; // Thời gian xử lý 1 frame (tiền xử lý + model + parse)
  double lastMaxScore = 0; // Điểm cao nhất model thấy được (kể cả dưới ngưỡng)
  String lastMaxLabel = '';

  // ---------------------------------------------------------------------------
  // Khởi tạo
  // ---------------------------------------------------------------------------

  /// Load model TFLite và labels vào bộ nhớ.
  /// Gọi 1 lần duy nhất khi app khởi động.
  @override
  void initialize() {
    try {
      try {
        _createInterpreter(accelerated: true);
      } catch (error) {
        debugPrint('Delegate không khả dụng, dùng CPU: $error');
        _releaseInterpreter();
        _createInterpreter(accelerated: false);
      }
      final inputTensor = _interpreter!.getInputTensor(0);
      final outputTensor = _interpreter!.getOutputTensor(0);
      final shape =
          inputTensor.shape; // [1, 3, S, S] (NCHW) hoặc [1, S, S, 3] (NHWC)
      if (shape.length != 4 ||
          shape[0] != 1 ||
          (shape[1] != 3 && shape[3] != 3)) {
        throw UnsupportedError('Input tensor không hỗ trợ: $shape');
      }
      _channelsFirst = shape[1] == 3;
      _inputSize = _channelsFirst ? shape[2] : shape[1];
      final inputHeight = _channelsFirst ? shape[3] : shape[2];
      if (_inputSize <= 0 || inputHeight != _inputSize) {
        throw UnsupportedError('Model cần input vuông: $shape');
      }
      _inputType = inputTensor.type;
      if (!{
        TensorType.float32,
        TensorType.int8,
        TensorType.uint8,
      }.contains(_inputType)) {
        throw UnsupportedError('Kiểu input không hỗ trợ: $_inputType');
      }
      _inputScale = inputTensor.params.scale;
      _inputZeroPoint = inputTensor.params.zeroPoint;
      _inputTensor = inputTensor;
      _inputBuffer = Uint8List(
        3 *
            _inputSize *
            _inputSize *
            (_inputType == TensorType.float32 ? 4 : 1),
      );
      _outputTensor = outputTensor;
      if (outputTensor.shape.length != 3 ||
          outputTensor.shape[0] != 1 ||
          !{
            TensorType.float32,
            TensorType.int8,
            TensorType.uint8,
          }.contains(outputTensor.type)) {
        throw UnsupportedError('Output tensor không hỗ trợ');
      }

      final numClasses = min(outputTensor.shape[1], outputTensor.shape[2]) - 4;
      if (numClasses != _labels.length) {
        debugPrint(
          '⚠️ Model có $numClasses lớp nhưng file nhãn có ${_labels.length} dòng — nhãn sẽ bị lệch!',
        );
      }

      debugPrint('=== SMART EYE TFLITE DIAGNOSTICS ===');
      debugPrint(
        'Input Tensor: shape=$shape (${_channelsFirst ? 'NCHW' : 'NHWC'}), type=${inputTensor.type}, '
        'scale=$_inputScale, zeroPoint=$_inputZeroPoint',
      );
      debugPrint(
        'Output Tensor: shape=${outputTensor.shape}, type=${outputTensor.type}, '
        'scale=${outputTensor.params.scale}, zeroPoint=${outputTensor.params.zeroPoint}',
      );
    } finally {
      _modelBytes = null;
    }
  }

  void _createInterpreter({required bool accelerated}) {
    final options = InterpreterOptions()..threads = 4;
    try {
      if (accelerated && (Platform.isAndroid || Platform.isIOS)) {
        final xnnOptions = XNNPackDelegateOptions(numThreads: 4);
        try {
          _delegates.add(XNNPackDelegate(options: xnnOptions));
        } finally {
          xnnOptions.delete();
        }
        if (Platform.isIOS) _delegates.add(CoreMlDelegate());
        for (final delegate in _delegates) {
          options.addDelegate(delegate);
        }
      }
      _interpreter = Interpreter.fromBuffer(_modelBytes!, options: options);
    } finally {
      options.delete();
    }
  }

  // ---------------------------------------------------------------------------
  // Inference
  // ---------------------------------------------------------------------------

  @override
  _DetectionResult process(_DetectionRequest request) {
    final watch = Stopwatch()..start();
    try {
      // Dùng hàm tối ưu hoá mới: xử lý trực tiếp ra bytes của model, không dùng float
      final inputBytes = ImageUtils.cameraImageToModelBytes(
        request.image,
        size: _inputSize,
        channelsFirst: _channelsFirst,
        inputType: _inputType,
        scale: _inputScale,
        zeroPoint: _inputZeroPoint,
        rotationDegrees: request.rotation,
        outputBuffer: _inputBuffer,
      );
      if (inputBytes == null) throw StateError('Frame camera không hợp lệ');

      // Fixed-size input: copy directly into the allocated tensor. runInference
      // would allocate and copy through an extra native buffer on every frame.
      _inputTensor.data = inputBytes;
      _interpreter!.invoke();
      _frameCount++;

      final results = _parseOutput(
        _outputTensor,
        screenWidth: request.width,
        screenHeight: request.height,
      );
      lastFrameMs = watch.elapsedMilliseconds;
      return _DetectionResult(results, lastFrameMs, lastMaxScore, lastMaxLabel);
    } finally {
      watch.stop();
    }
  }

  // ---------------------------------------------------------------------------
  // Parse & NMS
  // ---------------------------------------------------------------------------

  List<Recognition> _parseOutput(
    Tensor output, {
    required double screenWidth,
    required double screenHeight,
  }) {
    // YOLOv8: [1, 4 + số lớp, số anchor] (VD [1, 84, 2100] với input 320)
    final shape = output.shape;
    final bool transposed =
        shape[1] > shape[2]; // một số bản export ra [1, anchor, 4 + lớp]
    final int channels = transposed ? shape[2] : shape[1];
    final int numAnchors = transposed ? shape[1] : shape[2];
    final int numClasses = min(channels - 4, _labels.length);

    final bytes = ByteData.sublistView(output.data);
    final type = output.type;
    final double outScale = output.params.scale;
    final int outZero = output.params.zeroPoint;

    double value(int c, int i) {
      final int idx = transposed ? i * channels + c : c * numAnchors + i;
      switch (type) {
        case TensorType.int8:
          return (bytes.getInt8(idx) - outZero) * outScale;
        case TensorType.uint8:
          return (bytes.getUint8(idx) - outZero) * outScale;
        default:
          return bytes.getFloat32(idx * 4, Endian.little);
      }
    }

    final List<Recognition> candidates = [];
    double maxOverallScore = 0.0;
    int maxOverallClass = -1;

    for (int i = 0; i < numAnchors; i++) {
      double maxScore = 0.0;
      int maxClassIdx = -1;
      for (int c = 0; c < numClasses; c++) {
        final double score = value(4 + c, i);
        if (score > maxScore) {
          maxScore = score;
          maxClassIdx = c;
        }
      }

      if (maxScore > maxOverallScore) {
        maxOverallScore = maxScore;
        maxOverallClass = maxClassIdx;
      }

      if (maxScore < _confidenceThreshold || maxClassIdx < 0) continue;

      // BỎ QUA các vật thể không ảnh hưởng đến đường đi để tránh tốn CPU xử lý toạ độ và NMS
      if (!_relevantClasses.contains(maxClassIdx)) continue;

      final double cx = value(0, i);
      final double cy = value(1, i);
      final double bw = value(2, i);
      final double bh = value(3, i);

      // Tự động phát hiện tọa độ là chuẩn hóa [0..1] hay pixel [0..inputSize]
      final bool isNormalized = (cx <= 1.5 && bw <= 1.5);
      final double scaleX = isNormalized
          ? screenWidth
          : (screenWidth / _inputSize);
      final double scaleY = isNormalized
          ? screenHeight
          : (screenHeight / _inputSize);

      final double left = ((cx - bw / 2) * scaleX).clamp(0, screenWidth);
      final double top = ((cy - bh / 2) * scaleY).clamp(0, screenHeight);
      final double right = ((cx + bw / 2) * scaleX).clamp(0, screenWidth);
      final double bottom = ((cy + bh / 2) * scaleY).clamp(0, screenHeight);

      if (right <= left || bottom <= top) continue;

      final labelEn = _labels[maxClassIdx];
      candidates.add(
        Recognition(
          maxClassIdx,
          labelVi[labelEn] ?? labelEn,
          maxScore,
          Rect.fromLTRB(left, top, right, bottom),
          labelEn: labelEn,
        ),
      );
    }

    lastMaxScore = maxOverallScore;
    lastMaxLabel = maxOverallClass >= 0
        ? (labelVi[_labels[maxOverallClass]] ?? _labels[maxOverallClass])
        : '';
    if (_frameCount % 10 == 0) {
      final maxLabel = maxOverallClass >= 0 ? _labels[maxOverallClass] : 'none';
      debugPrint(
        '[Frame $_frameCount] ${lastFrameMs}ms, Max score: ${(maxOverallScore * 100).toStringAsFixed(1)}% ($maxLabel), Candidates: ${candidates.length}',
      );
    }

    // Non-Maximum Suppression
    return _applyNMS(candidates);
  }

  /// Non-Maximum Suppression: loại bỏ các box bị chồng lấp quá nhiều
  List<Recognition> _applyNMS(List<Recognition> detections) {
    if (detections.isEmpty) return [];

    // Sắp xếp theo score giảm dần
    detections.sort((a, b) => b.score.compareTo(a.score));

    final List<Recognition> result = [];
    final List<bool> suppressed = List.filled(detections.length, false);

    for (int i = 0; i < detections.length; i++) {
      if (suppressed[i]) continue;
      result.add(detections[i]);

      // Giới hạn tối đa 10 box để không quá rối UI
      if (result.length >= 10) break;

      for (int j = i + 1; j < detections.length; j++) {
        if (suppressed[j]) continue;
        // Chỉ NMS trong cùng class
        if (detections[i].id != detections[j].id) continue;

        final iou = _computeIoU(detections[i].location, detections[j].location);
        if (iou > _iouThreshold) {
          suppressed[j] = true;
        }
      }
    }
    return result;
  }

  /// Tính IoU (Intersection over Union) giữa 2 hình chữ nhật
  double _computeIoU(Rect a, Rect b) {
    final double interLeft = max(a.left, b.left);
    final double interTop = max(a.top, b.top);
    final double interRight = min(a.right, b.right);
    final double interBottom = min(a.bottom, b.bottom);

    if (interRight <= interLeft || interBottom <= interTop) return 0.0;

    final double intersection =
        (interRight - interLeft) * (interBottom - interTop);
    final double aArea = a.width * a.height;
    final double bArea = b.width * b.height;
    final double union = aArea + bArea - intersection;

    return union <= 0 ? 0.0 : intersection / union;
  }

  // ---------------------------------------------------------------------------
  // Giải phóng
  // ---------------------------------------------------------------------------

  @override
  void dispose() => _releaseInterpreter();

  void _releaseInterpreter() {
    _interpreter?.close();
    _interpreter = null;
    for (final delegate in _delegates.reversed) {
      delegate.delete();
    }
    _delegates.clear();
  }
}
