import 'dart:math';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import '../models/Recognition.dart';
import '../utils/image_utils.dart';
import '../utils/label_catalog.dart';

/// Dịch vụ nhận diện vật thể dùng YOLOv8 TFLite.
/// Kích thước input, layout (NCHW/NHWC) và kiểu dữ liệu được đọc từ chính model,
/// nên đổi model (320/640, float/int8) không cần sửa code.
class DetectorService {
  static const String _modelPath = 'assets/models/yolov8n_int8.tflite';
  static const String _labelPath = 'assets/labels/coco.txt';

  // Ngưỡng lọc — 0.25 là mặc định Ultralytics. Đo trên COCO128 (xem README):
  // 0.15 → precision 0.71, 149 box sai; 0.25 → precision 0.83, 64 box sai, recall vật lớn gần như giữ nguyên.
  static const double _confidenceThreshold = 0.25;
  static const double _iouThreshold = 0.45;

  Interpreter? _interpreter;
  List<String> _labels = [];
  bool _isLoaded = false;
  int _frameCount = 0;

  // Thông tin model đọc lúc load
  int _inputSize = 0;
  bool _channelsFirst = false;
  TensorType _inputType = TensorType.float32;
  double _inputScale = 0;
  int _inputZeroPoint = 0;

  bool get isLoaded => _isLoaded;

  // Chẩn đoán hiển thị trên màn hình
  int lastFrameMs = 0;          // Thời gian xử lý 1 frame (tiền xử lý + model + parse)
  double lastMaxScore = 0;      // Điểm cao nhất model thấy được (kể cả dưới ngưỡng)
  String lastMaxLabel = '';

  // ---------------------------------------------------------------------------
  // Khởi tạo
  // ---------------------------------------------------------------------------

  /// Load model TFLite và labels vào bộ nhớ.
  /// Gọi 1 lần duy nhất khi app khởi động.
  Future<void> loadModel() async {
    try {
      final options = InterpreterOptions()..threads = 2;
      _interpreter = await Interpreter.fromAsset(_modelPath, options: options);

      final labelsData = await rootBundle.loadString(_labelPath);
      _labels = labelsData
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      final inputTensor = _interpreter!.getInputTensor(0);
      final outputTensor = _interpreter!.getOutputTensor(0);
      final shape = inputTensor.shape; // [1, 3, S, S] (NCHW) hoặc [1, S, S, 3] (NHWC)
      _channelsFirst = shape[1] == 3;
      _inputSize = _channelsFirst ? shape[2] : shape[1];
      _inputType = inputTensor.type;
      _inputScale = inputTensor.params.scale;
      _inputZeroPoint = inputTensor.params.zeroPoint;

      final numClasses = min(outputTensor.shape[1], outputTensor.shape[2]) - 4;
      if (numClasses != _labels.length) {
        debugPrint('⚠️ Model có $numClasses lớp nhưng file nhãn có ${_labels.length} dòng — nhãn sẽ bị lệch!');
      }

      _isLoaded = true;
      debugPrint('=== SMART EYE TFLITE DIAGNOSTICS ===');
      debugPrint('Input Tensor: shape=$shape (${_channelsFirst ? 'NCHW' : 'NHWC'}), type=${inputTensor.type}, '
          'scale=$_inputScale, zeroPoint=$_inputZeroPoint');
      debugPrint('Output Tensor: shape=${outputTensor.shape}, type=${outputTensor.type}, '
          'scale=${outputTensor.params.scale}, zeroPoint=${outputTensor.params.zeroPoint}');
    } catch (e) {
      _isLoaded = false;
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Inference
  // ---------------------------------------------------------------------------

  List<Recognition> detect({
    required CameraImage image,
    required double screenWidth,
    required double screenHeight,
    int rotationDegrees = 90,
  }) {
    if (!_isLoaded || _interpreter == null) return [];

    final watch = Stopwatch()..start();
    try {
      final pixels = ImageUtils.cameraImageToFloat32(
        image,
        size: _inputSize,
        channelsFirst: _channelsFirst,
        rotationDegrees: rotationDegrees,
      );
      if (pixels == null) return [];

      _interpreter!.runInference([_toInputBytes(pixels)]);
      _frameCount++;

      final outputTensor = _interpreter!.getOutputTensor(0);
      final results = _parseOutput(
        outputTensor,
        screenWidth: screenWidth,
        screenHeight: screenHeight,
      );
      lastFrameMs = watch.elapsedMilliseconds;
      return results;
    } catch (e, stack) {
      // Không để 1 frame lỗi làm dừng cả luồng nhận diện
      debugPrint('Lỗi nhận diện: $e\n$stack');
      return [];
    }
  }

  /// Đóng gói tensor float [0..1] thành bytes đúng kiểu input của model (float32 / int8 / uint8)
  Uint8List _toInputBytes(Float32List pixels) {
    if (_inputType == TensorType.float32) return pixels.buffer.asUint8List();

    final double scale = _inputScale == 0 ? (1.0 / 255.0) : _inputScale;
    if (_inputType == TensorType.int8) {
      final q = Int8List(pixels.length);
      for (int i = 0; i < pixels.length; i++) {
        q[i] = ((pixels[i] / scale) + _inputZeroPoint).round().clamp(-128, 127);
      }
      return q.buffer.asUint8List();
    }
    final q = Uint8List(pixels.length);
    for (int i = 0; i < pixels.length; i++) {
      q[i] = ((pixels[i] / scale) + _inputZeroPoint).round().clamp(0, 255);
    }
    return q;
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
    final bool transposed = shape[1] > shape[2]; // một số bản export ra [1, anchor, 4 + lớp]
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

      final double cx = value(0, i);
      final double cy = value(1, i);
      final double bw = value(2, i);
      final double bh = value(3, i);

      // Tự động phát hiện tọa độ là chuẩn hóa [0..1] hay pixel [0..inputSize]
      final bool isNormalized = (cx <= 1.5 && bw <= 1.5);
      final double scaleX = isNormalized ? screenWidth : (screenWidth / _inputSize);
      final double scaleY = isNormalized ? screenHeight : (screenHeight / _inputSize);

      final double left = ((cx - bw / 2) * scaleX).clamp(0, screenWidth);
      final double top = ((cy - bh / 2) * scaleY).clamp(0, screenHeight);
      final double right = ((cx + bw / 2) * scaleX).clamp(0, screenWidth);
      final double bottom = ((cy + bh / 2) * scaleY).clamp(0, screenHeight);

      if (right <= left || bottom <= top) continue;

      final labelEn = _labels[maxClassIdx];
      candidates.add(Recognition(
        maxClassIdx,
        labelVi[labelEn] ?? labelEn,
        maxScore,
        Rect.fromLTRB(left, top, right, bottom),
        labelEn: labelEn,
      ));
    }

    lastMaxScore = maxOverallScore;
    lastMaxLabel = maxOverallClass >= 0 ? (labelVi[_labels[maxOverallClass]] ?? _labels[maxOverallClass]) : '';
    if (_frameCount % 10 == 0) {
      final maxLabel = maxOverallClass >= 0 ? _labels[maxOverallClass] : 'none';
      debugPrint('[Frame $_frameCount] ${lastFrameMs}ms, Max score: ${(maxOverallScore * 100).toStringAsFixed(1)}% ($maxLabel), Candidates: ${candidates.length}');
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
    final double interLeft   = max(a.left, b.left);
    final double interTop    = max(a.top, b.top);
    final double interRight  = min(a.right, b.right);
    final double interBottom = min(a.bottom, b.bottom);

    if (interRight <= interLeft || interBottom <= interTop) return 0.0;

    final double intersection = (interRight - interLeft) * (interBottom - interTop);
    final double aArea = a.width * a.height;
    final double bArea = b.width * b.height;
    final double union = aArea + bArea - intersection;

    return union <= 0 ? 0.0 : intersection / union;
  }

  // ---------------------------------------------------------------------------
  // Giải phóng
  // ---------------------------------------------------------------------------

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isLoaded = false;
  }
}
