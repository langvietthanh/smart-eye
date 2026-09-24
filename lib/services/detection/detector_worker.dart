import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:tflite_flutter/tflite_flutter.dart';

import '../../utils/image_utils.dart';
import 'frame_data.dart';
import 'yolo_decoder.dart';

/// Thông tin model + cách chạy mà isolate AI đã chọn
class WorkerInfo {
  final String backend; // cpu / gpu / metal / coreml
  final int inputSize;
  final bool channelsFirst;
  final List<int> outputShape;

  /// Thời gian chạy model trung bình (ms) của từng cách đã thử lúc khởi động; -1 = lỗi / cho kết quả sai
  final Map<String, double> benchmark;

  /// Lý do cách chạy bị loại (VD GPU không hỗ trợ op, kết quả lệch CPU...)
  final Map<String, String> rejected;

  const WorkerInfo(this.backend, this.inputSize, this.channelsFirst, this.outputShape, this.benchmark,
      [this.rejected = const {}]);
}

/// Kết quả 1 lần quét
class DetectionBatch {
  final List<RawDetection> detections;
  final double maxScore;
  final int maxClassId;
  final CropRect crop;
  final String backend;

  /// Thời gian từng bước (ms): tiền xử lý / chạy model / đọc kết quả
  final double prepMs;
  final double inferMs;
  final double parseMs;

  /// Mức thay đổi cảnh so với lần quét trước (0 = đứng yên, 1 = khác hoàn toàn)
  final double motion;
  final String? error;

  const DetectionBatch({
    required this.detections,
    required this.maxScore,
    required this.maxClassId,
    required this.crop,
    required this.backend,
    required this.prepMs,
    required this.inferMs,
    required this.parseMs,
    required this.motion,
    this.error,
  });

  double get totalMs => prepMs + inferMs + parseMs;
}

/// Isolate chạy AI (tiền xử lý + model + đọc kết quả) tách khỏi luồng giao diện.
/// Luồng UI chỉ còn việc copy frame (~1 ms) và nhận danh sách vật.
class DetectorWorker {
  final Isolate _isolate;
  final SendPort _send;
  final ReceivePort _receive;
  final Map<int, Completer<Object?>> _pending = {};
  int _nextId = 0;
  final WorkerInfo info;

  DetectorWorker._(this._isolate, this._send, this._receive, this.info);

  /// Khởi động isolate, nạp model và tự chọn cách chạy nhanh nhất.
  /// [preferredBackend]: 'auto' (mặc định) hoặc ép 'cpu' / 'gpu' / 'metal' / 'coreml'.
  static Future<DetectorWorker> start({
    required Uint8List modelBytes,
    required List<int> classIds,
    double confThreshold = 0.25,
    double iouThreshold = 0.45,
    String preferredBackend = 'auto',
  }) async {
    final receive = ReceivePort();
    final isolate = await Isolate.spawn(_workerMain, receive.sendPort, debugName: 'SmartEyeDetector');
    final events = StreamIterator(receive);

    await events.moveNext();
    final send = events.current as SendPort;
    send.send(_Init(
      TransferableTypedData.fromList([modelBytes]),
      classIds,
      confThreshold,
      iouThreshold,
      preferredBackend,
    ));

    await events.moveNext();
    final reply = events.current;
    if (reply is _Failure) {
      isolate.kill(priority: Isolate.immediate);
      receive.close();
      throw StateError('Không nạp được model: ${reply.message}');
    }
    final worker = DetectorWorker._(isolate, send, receive, reply as WorkerInfo);

    // Các phản hồi sau đó: (id, kết quả)
    unawaited(() async {
      while (await events.moveNext()) {
        final msg = events.current;
        if (msg is _Reply) worker._pending.remove(msg.id)?.complete(msg.value);
      }
    }());
    return worker;
  }

  /// Quét 1 frame. [packet] bị "tiêu thụ" (chuyển quyền sở hữu sang isolate AI).
  Future<DetectionBatch> detect(FramePacket packet, {required int rotation, CropRect crop = CropRect.full}) async =>
      (await _call(_Detect(packet, rotation, crop))) as DetectionBatch;

  /// Ảnh thumbnail JPEG của frame vừa quét gần nhất (cho ảnh ghi nhớ — CN12)
  Future<Uint8List?> thumbnail() async => (await _call(const _Thumbnail())) as Uint8List?;

  Future<Object?> _call(Object request) {
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _send.send(_Request(id, request));
    return completer.future;
  }

  void dispose() {
    _send.send(const _Shutdown());
    _receive.close();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('Detector đã tắt'));
    }
    _pending.clear();
    Future.delayed(const Duration(seconds: 1), () => _isolate.kill());
  }
}

// ---------------------------------------------------------------------------
// Tin nhắn giữa 2 isolate
// ---------------------------------------------------------------------------

class _Init {
  final TransferableTypedData model;
  final List<int> classIds;
  final double conf;
  final double iou;
  final String preferredBackend;
  const _Init(this.model, this.classIds, this.conf, this.iou, this.preferredBackend);
}

class _Request {
  final int id;
  final Object body;
  const _Request(this.id, this.body);
}

class _Reply {
  final int id;
  final Object? value;
  const _Reply(this.id, this.value);
}

class _Detect {
  final FramePacket packet;
  final int rotation;
  final CropRect crop;
  const _Detect(this.packet, this.rotation, this.crop);
}

class _Thumbnail {
  const _Thumbnail();
}

class _Shutdown {
  const _Shutdown();
}

class _Failure {
  final String message;
  const _Failure(this.message);
}

// ---------------------------------------------------------------------------
// Phía isolate AI
// ---------------------------------------------------------------------------

Future<void> _workerMain(SendPort toMain) async {
  final inbox = ReceivePort();
  toMain.send(inbox.sendPort);
  _Engine? engine;

  await for (final msg in inbox) {
    if (msg is _Init) {
      try {
        engine = _Engine.create(msg);
        toMain.send(engine.info);
      } catch (e) {
        toMain.send(_Failure('$e'));
        inbox.close();
      }
    } else if (msg is _Request && engine != null) {
      final body = msg.body;
      Object? value;
      if (body is _Detect) {
        value = engine.detect(body);
      } else if (body is _Thumbnail) {
        value = engine.thumbnail();
      }
      toMain.send(_Reply(msg.id, value));
    } else if (msg is _Shutdown) {
      engine?.close();
      inbox.close();
    }
  }
}

/// 1 cách chạy model đã khởi tạo xong
class _Runner {
  final String backend;
  final Interpreter interpreter;
  final Delegate? delegate;
  _Runner(this.backend, this.interpreter, this.delegate);

  void close() {
    interpreter.close();
    delegate?.delete();
  }
}

class _Engine {
  final Uint8List modelBytes;
  final List<int> classIds;
  final double conf;
  final double iou;
  _Runner runner;
  final WorkerInfo _info;

  late final int inputSize;
  late final bool channelsFirst;
  late final List<int> outputShape;
  late final TensorType inputType;
  late final double inputScale;
  late final int inputZeroPoint;

  FrameData? _lastFrame;
  int _lastRotation = 0;
  Uint8List? _lastSignature;

  _Engine._(this.modelBytes, this.classIds, this.conf, this.iou, this.runner, this._info) {
    _readShapes(runner.interpreter);
  }

  WorkerInfo get info =>
      WorkerInfo(runner.backend, _info.inputSize, _info.channelsFirst, _info.outputShape, _info.benchmark, _info.rejected);

  static _Engine create(_Init init) {
    final bytes = init.model.materialize().asUint8List();
    final candidates = switch (init.preferredBackend) {
      'auto' => Platform.isIOS ? ['cpu', 'metal', 'coreml'] : ['cpu', 'gpu'],
      final b => [b],
    };

    // Đo từng cách chạy trên cùng 1 input thử; cách tăng tốc phải cho kết quả giống CPU
    final bench = <String, double>{};
    final rejected = <String, String>{};
    _Runner? best;
    double bestMs = double.infinity;
    Float32List? reference;
    for (final backend in candidates) {
      _Runner? r;
      try {
        r = _createRunner(bytes, backend);
        final result = _benchmark(r.interpreter);
        if (reference == null) {
          reference = result.output;
        } else {
          final diff = _difference(reference, result.output);
          if (diff.max >= 0.05 || diff.mean >= 0.005) {
            throw StateError('kết quả lệch CPU: max ${diff.max.toStringAsFixed(4)}, '
                'trung bình ${diff.mean.toStringAsFixed(5)} (${result.ms.toStringAsFixed(0)} ms)');
          }
        }
        bench[backend] = result.ms;
        // Cách tăng tốc phải nhanh hơn CPU ≥ 15% mới đáng dùng (CPU ổn định hơn)
        final effective = backend == 'cpu' ? result.ms : result.ms / 0.85;
        if (effective < bestMs) {
          best?.close();
          best = r;
          bestMs = effective;
        } else {
          r.close();
        }
      } catch (e) {
        bench[backend] = -1;
        rejected[backend] = '$e';
        r?.close();
      }
    }
    if (best == null) throw StateError('không chạy được model bằng cách nào: $bench');

    final input = best.interpreter.getInputTensor(0).shape;
    final nchw = input[1] == 3;
    final info = WorkerInfo(
      best.backend,
      nchw ? input[2] : input[1],
      nchw,
      best.interpreter.getOutputTensor(0).shape,
      bench,
      rejected,
    );
    return _Engine._(bytes, init.classIds, init.conf, init.iou, best, info);
  }

  static _Runner _createRunner(Uint8List bytes, String backend) {
    final options = InterpreterOptions();
    Delegate? delegate;
    switch (backend) {
      case 'gpu':
        delegate = GpuDelegateV2(
          options: GpuDelegateOptionsV2(
            isPrecisionLossAllowed: true, // FP16 trên GPU — nhanh hơn, sai số nhỏ (đã kiểm với CPU)
            inferencePreference: 1, // SUSTAINED_SPEED: chạy liên tục nhiều frame
            inferencePriority1: 2, // MIN_LATENCY
          ),
        );
      case 'metal':
        delegate = GpuDelegate(options: GpuDelegateOptions(allowPrecisionLoss: true));
      case 'coreml':
        delegate = CoreMlDelegate();
      default:
        options.threads = min(4, Platform.numberOfProcessors);
    }
    if (delegate != null) options.addDelegate(delegate);
    try {
      final interpreter = Interpreter.fromBuffer(bytes, options: options)..allocateTensors();
      return _Runner(backend, interpreter, delegate);
    } catch (_) {
      delegate?.delete();
      rethrow;
    }
  }

  /// 1 lần khởi động + 3 lần đo trên input thử cố định
  static ({double ms, Float32List output}) _benchmark(Interpreter interpreter) {
    final tensor = interpreter.getInputTensor(0);
    final count = tensor.shape.fold(1, (a, b) => a * b);
    final input = Float32List(count);
    var seed = 12345;
    for (var i = 0; i < count; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      input[i] = (i % 320) / 320 * 0.6 + (seed & 0xff) / 255 * 0.4; // gradient + nhiễu
    }
    final bytes = input.buffer.asUint8List();
    interpreter.runInference([bytes]); // khởi động (GPU biên dịch shader ở lần đầu)
    final sw = Stopwatch()..start();
    const runs = 3;
    for (var i = 0; i < runs; i++) {
      interpreter.runInference([bytes]);
    }
    final ms = sw.elapsedMicroseconds / 1000 / runs;
    return (ms: ms, output: Float32List.fromList(_readOutput(interpreter.getOutputTensor(0))));
  }

  static ({double max, double mean}) _difference(Float32List a, Float32List b) {
    if (a.length != b.length) return (max: double.infinity, mean: double.infinity);
    var maxDiff = 0.0, sum = 0.0;
    for (var i = 0; i < a.length; i++) {
      final d = (a[i] - b[i]).abs();
      sum += d;
      if (d > maxDiff) maxDiff = d;
    }
    return (max: maxDiff, mean: sum / a.length);
  }

  void _readShapes(Interpreter interpreter) {
    final input = interpreter.getInputTensor(0);
    channelsFirst = input.shape[1] == 3;
    inputSize = channelsFirst ? input.shape[2] : input.shape[1];
    inputType = input.type;
    inputScale = input.params.scale;
    inputZeroPoint = input.params.zeroPoint;
    outputShape = interpreter.getOutputTensor(0).shape;
  }

  DetectionBatch detect(_Detect request) {
    final sw = Stopwatch()..start();
    final frame = request.packet.open();
    _lastFrame = frame;
    _lastRotation = request.rotation;

    final signature = ImageUtils.lumaSignature(frame, rotationDegrees: request.rotation);
    final motion = signature != null && _lastSignature != null ? ImageUtils.signatureDiff(signature, _lastSignature!) : 1.0;
    _lastSignature = signature;

    final pixels = ImageUtils.toInputTensor(
      frame,
      size: inputSize,
      channelsFirst: channelsFirst,
      rotationDegrees: request.rotation,
      crop: request.crop,
    );
    if (pixels == null) {
      return _empty(request.crop, motion, sw.elapsedMicroseconds / 1000, 'định dạng frame không hỗ trợ');
    }
    final input = _toInputBytes(pixels);
    final prepMs = sw.elapsedMicroseconds / 1000;

    String? error;
    try {
      runner.interpreter.runInference([input]);
    } catch (e) {
      // Cách tăng tốc lỗi giữa chừng → chuyển hẳn về CPU và thử lại 1 lần
      if (runner.backend == 'cpu') return _empty(request.crop, motion, prepMs, '$e');
      error = 'Lỗi ${runner.backend}, chuyển về CPU: $e';
      runner.close();
      runner = _createRunner(modelBytes, 'cpu');
      runner.interpreter.runInference([input]);
    }
    final inferMs = sw.elapsedMicroseconds / 1000 - prepMs;

    final decoded = YoloDecoder.decode(
      output: _readOutput(runner.interpreter.getOutputTensor(0)),
      shape: outputShape,
      classIds: classIds,
      inputSize: inputSize,
      confThreshold: conf,
      iouThreshold: iou,
      crop: request.crop,
    );
    final detections = request.crop.isFull
        ? decoded.detections
        : decoded.detections.where((d) => !YoloDecoder.touchesCropEdge(d, request.crop)).toList();
    final parseMs = sw.elapsedMicroseconds / 1000 - prepMs - inferMs;

    return DetectionBatch(
      detections: detections,
      maxScore: decoded.maxScore,
      maxClassId: decoded.maxClassId,
      crop: request.crop,
      backend: runner.backend,
      prepMs: prepMs,
      inferMs: inferMs,
      parseMs: parseMs,
      motion: motion,
      error: error,
    );
  }

  DetectionBatch _empty(CropRect crop, double motion, double prepMs, String error) => DetectionBatch(
        detections: const [],
        maxScore: 0,
        maxClassId: -1,
        crop: crop,
        backend: runner.backend,
        prepMs: prepMs,
        inferMs: 0,
        parseMs: 0,
        motion: motion,
        error: error,
      );

  Uint8List? thumbnail() {
    final frame = _lastFrame;
    return frame == null ? null : ImageUtils.toJpeg(frame, rotationDegrees: _lastRotation);
  }

  /// Đóng gói tensor float [0..1] thành bytes đúng kiểu input của model (float32 / int8 / uint8)
  Uint8List _toInputBytes(Float32List pixels) {
    if (inputType == TensorType.float32) return pixels.buffer.asUint8List();
    final scale = inputScale == 0 ? 1 / 255 : inputScale;
    if (inputType == TensorType.int8) {
      final q = Int8List(pixels.length);
      for (var i = 0; i < pixels.length; i++) {
        q[i] = (pixels[i] / scale + inputZeroPoint).round().clamp(-128, 127);
      }
      return q.buffer.asUint8List();
    }
    final q = Uint8List(pixels.length);
    for (var i = 0; i < pixels.length; i++) {
      q[i] = (pixels[i] / scale + inputZeroPoint).round().clamp(0, 255);
    }
    return q;
  }

  /// Output của model thành Float32List (đọc thẳng bộ nhớ nếu được, giải lượng tử nếu model int8)
  static Float32List _readOutput(Tensor tensor) {
    final data = tensor.data;
    switch (tensor.type) {
      case TensorType.int8:
        final scale = tensor.params.scale, zero = tensor.params.zeroPoint;
        final q = Int8List.sublistView(data);
        return Float32List.fromList([for (final v in q) (v - zero) * scale]);
      case TensorType.uint8:
        final scale = tensor.params.scale, zero = tensor.params.zeroPoint;
        return Float32List.fromList([for (final v in data) (v - zero) * scale]);
      default:
        if (data.offsetInBytes % 4 == 0) {
          return data.buffer.asFloat32List(data.offsetInBytes, data.lengthInBytes ~/ 4);
        }
        return Float32List.sublistView(Uint8List.fromList(data));
    }
  }

  void close() => runner.close();
}
