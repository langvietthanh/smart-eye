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
import 'detection/model_metadata.dart';
import 'performance_metrics.dart';
import 'processing_worker.dart';

/// Dịch vụ nhận diện vật thể dùng YOLOv8 TFLite.
/// Kích thước input, layout (NCHW/NHWC) và kiểu dữ liệu được đọc từ chính model,
/// nên đổi model (320/640, float/int8) không cần sửa code.
class DetectorService {
  /// Model v4 (YOLO11n, 27 lớp, FP32) — tên lớp nhúng trong metadata của model.
  static const String _customModelPath = 'assets/models/smart_eye.tflite';

  /// Model COCO mặc định — dùng khi chưa có model v4 hoặc model không có tên lớp trong metadata.
  static const String _defaultModelPath = 'assets/models/yolov8n_int8.tflite';
  static const String _labelPath = 'assets/labels/coco.txt';

  // Ngưỡng lọc, theo model:
  // - YOLOv8n COCO int8: 0.25 (mặc định Ultralytics; COCO128: precision 0.83, 64 box sai).
  // - Model v4 FP32 (có metadata): 0.35. Đo trên 1100 ảnh val (COCO val2017 + BPID + cầu thang):
  //   0.25 → precision 0.71, 857 box sai; 0.35 → precision 0.78, 513 box sai, recall vật lớn 0.73 → 0.70.
  static const double defaultModelConfidence = 0.25;
  static const double customModelConfidence = 0.35;
  static const double iouThreshold = 0.45;

  /// Đường dẫn model đang dùng (cập nhật sau khi nạp).
  String modelPath = _defaultModelPath;

  ProcessingWorker<_DetectionRequest, _DetectionResult>? _worker;
  Future<void>? _loading;
  Future<void>? _disposing;
  bool _disposed = false;
  bool _busy = false;

  bool get isLoaded => _worker != null && !_disposed;
  int lastFrameMs = 0;
  double lastMaxScore = 0;
  String lastMaxLabel = '';

  /// Mean brightness of the last processed frame; null if it could not be read.
  double? lastMeanLuma;
  final DetectorPerformance performance = DetectorPerformance();

  Future<void> loadModel() {
    if (_disposed) return Future.error(StateError('Detector is disposed'));
    if (isLoaded) return Future.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    // Asset access stays on the root isolate. Native model creation and all
    // frame processing happen in the same persistent background isolate.
    final selected = await _selectModel();
    if (_disposed) return;
    modelPath = selected.path;
    debugPrint(
      'Detector model: ${selected.path} · ${selected.labels.length} nhãn '
      '(${selected.namesFromMetadata ? 'metadata' : 'coco.txt'}) · '
      'ngưỡng ${selected.confidence}',
    );
    final worker = await ProcessingWorker.start(
      _DetectorProcessor(selected.bytes, selected.labels, selected.confidence),
    );
    if (_disposed) {
      await worker.close();
    } else {
      _worker = worker;
    }
  }

  /// Ưu tiên model v4 (tên lớp từ metadata, ngưỡng 0.35). Thiếu file hoặc
  /// metadata không có tên lớp → YOLOv8n int8 + coco.txt (ngưỡng 0.25).
  Future<_SelectedModel> _selectModel() async {
    try {
      final data = await rootBundle.load(_customModelPath);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final names = ModelMetadata.parse(bytes).names;
      if (names != null && names.isNotEmpty) {
        return _SelectedModel(
          _customModelPath,
          bytes,
          List.unmodifiable(names),
          customModelConfidence,
          namesFromMetadata: true,
        );
      }
      debugPrint(
        '$_customModelPath không có tên lớp trong metadata → dùng model mặc định',
      );
    } catch (e) {
      debugPrint('Không tải được $_customModelPath ($e) → dùng model mặc định');
    }
    final data = await rootBundle.load(_defaultModelPath);
    final labels = (await rootBundle.loadString(_labelPath))
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    return _SelectedModel(
      _defaultModelPath,
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      labels,
      defaultModelConfidence,
      namesFromMetadata: false,
    );
  }

  Future<List<Recognition>> detect({
    required CameraImage image,
    required double screenWidth,
    required double screenHeight,
    int rotationDegrees = 90,
  }) async {
    final worker = _worker;
    if (_disposed || worker == null) {
      performance.skippedUnavailable++;
      return [];
    }
    if (_busy) {
      performance.skippedBusy++;
      return [];
    }
    _busy = true;
    final watch = Stopwatch()..start();
    try {
      final result = await worker.run(
        _DetectionRequest(image, screenWidth, screenHeight, rotationDegrees),
      );
      watch.stop();
      if (_disposed) return [];
      performance.record(
        result.timings.withEndToEnd(watch.elapsedMicroseconds),
      );
      lastFrameMs = result.timings.workerUs ~/ 1000;
      lastMaxScore = result.maxScore;
      lastMaxLabel = result.maxLabel;
      lastMeanLuma = result.meanLuma;
      return result.detections;
    } catch (_) {
      performance.failedFrames++;
      rethrow;
    } finally {
      watch.stop();
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

class _SelectedModel {
  const _SelectedModel(
    this.path,
    this.bytes,
    this.labels,
    this.confidence, {
    required this.namesFromMetadata,
  });
  final String path;
  final Uint8List bytes;
  final List<String> labels;
  final double confidence;
  final bool namesFromMetadata;
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
    this.timings,
    this.maxScore,
    this.maxLabel,
    this.meanLuma,
  );
  final List<Recognition> detections;
  final DetectionTimings timings;
  final double maxScore;
  final String maxLabel;
  final double? meanLuma;
}

class _DetectorProcessor
    implements IsolateProcessor<_DetectionRequest, _DetectionResult> {
  _DetectorProcessor(this._modelBytes, this._labels, this._confidenceThreshold)
    : _relevantClasses = {
        for (int i = 0; i < _labels.length; i++)
          if (isDetectionRelevant(_labels[i])) i,
      };

  Uint8List? _modelBytes;
  final List<String> _labels;
  final List<Delegate> _delegates = [];

  // Ngưỡng lọc theo model (xem DetectorService.defaultModelConfidence / customModelConfidence).
  final double _confidenceThreshold;
  static const double _iouThreshold = DetectorService.iouThreshold;

  // Derived from label_catalog so the filter and hazard categories cannot drift.
  final Set<int> _relevantClasses;

  // Coordinate units are a property of the exported model; decided once from
  // the first frame because anchor centres always span the whole input.
  bool? _normalizedCoords;

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
      if (accelerated && Platform.isAndroid) {
        // Android: tflite_flutter 0.12.1 passes a 24-byte XNNPackDelegateOptions but LiteRT 1.4.0 reads 56 bytes -> SIGSEGV; null options make LiteRT use its own defaults.
        _delegates.add(XNNPackDelegate());
      } else if (accelerated && Platform.isIOS) {
        final xnnOptions = XNNPackDelegateOptions(numThreads: 4);
        try {
          _delegates.add(XNNPackDelegate(options: xnnOptions));
        } finally {
          xnnOptions.delete();
        }
        _delegates.add(CoreMlDelegate());
      }
      if (accelerated) {
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
      final preprocessedAt = watch.elapsedMicroseconds;

      // Fixed-size input: copy directly into the allocated tensor. runInference
      // would allocate and copy through an extra native buffer on every frame.
      _inputTensor.data = inputBytes;
      final copiedAt = watch.elapsedMicroseconds;
      _interpreter!.invoke();
      final inferredAt = watch.elapsedMicroseconds;
      _frameCount++;

      final results = _parseOutput(
        _outputTensor,
        screenWidth: request.width,
        screenHeight: request.height,
      );
      final finishedAt = watch.elapsedMicroseconds;
      lastFrameMs = finishedAt ~/ 1000;
      final timings = DetectionTimings(
        preprocessUs: preprocessedAt,
        inputCopyUs: copiedAt - preprocessedAt,
        inferenceUs: inferredAt - copiedAt,
        postprocessUs: finishedAt - inferredAt,
        workerUs: finishedAt,
        endToEndUs: 0, // Filled after the result returns to the UI isolate.
      );
      if (kDebugMode && _frameCount % 30 == 0) {
        debugPrint(
          '[Frame $_frameCount] ${lastFrameMs}ms, '
          'pre=${(timings.preprocessUs / 1000).toStringAsFixed(1)} '
          'copy=${(timings.inputCopyUs / 1000).toStringAsFixed(1)} '
          'infer=${(timings.inferenceUs / 1000).toStringAsFixed(1)} '
          'post=${(timings.postprocessUs / 1000).toStringAsFixed(1)}ms, '
          'max=${(lastMaxScore * 100).toStringAsFixed(1)}% ($lastMaxLabel)',
        );
      }
      return _DetectionResult(
        results,
        timings,
        lastMaxScore,
        lastMaxLabel,
        ImageUtils.meanLuma(request.image),
      );
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

    final bool isNormalized = _normalizedCoords ??= () {
      double maxCx = 0;
      for (int i = 0; i < numAnchors; i++) {
        maxCx = max(maxCx, value(0, i));
      }
      return maxCx <= 1.5;
    }();
    final double scaleX = isNormalized
        ? screenWidth
        : (screenWidth / _inputSize);
    final double scaleY = isNormalized
        ? screenHeight
        : (screenHeight / _inputSize);

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
