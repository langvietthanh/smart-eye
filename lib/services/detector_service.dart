import 'dart:math';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import '../models/Recognition.dart';
import '../utils/image_utils.dart';

/// Map nhãn tiếng Anh → tiếng Việt cho TTS cảnh báo
const Map<String, String> _labelVi = {
  'person': 'người',
  'bicycle': 'xe đạp',
  'car': 'xe ô tô',
  'motorbike': 'xe máy',
  'aeroplane': 'máy bay',
  'bus': 'xe buýt',
  'train': 'tàu hỏa',
  'truck': 'xe tải',
  'boat': 'thuyền',
  'traffic light': 'đèn giao thông',
  'fire hydrant': 'trụ nước cứu hỏa',
  'stop sign': 'biển dừng',
  'parking meter': 'đồng hồ đỗ xe',
  'bench': 'ghế băng',
  'bird': 'chim',
  'cat': 'mèo',
  'dog': 'chó',
  'horse': 'ngựa',
  'sheep': 'cừu',
  'cow': 'bò',
  'elephant': 'voi',
  'bear': 'gấu',
  'zebra': 'ngựa vằn',
  'giraffe': 'hươu cao cổ',
  'backpack': 'ba lô',
  'umbrella': 'ô dù',
  'handbag': 'túi xách',
  'tie': 'cà vạt',
  'suitcase': 'vali',
  'bottle': 'chai',
  'cup': 'cốc',
  'chair': 'ghế',
  'sofa': 'ghế sofa',
  'laptop': 'máy tính xách tay',
  'cell phone': 'điện thoại',
  'book': 'sách',
  'clock': 'đồng hồ',
  'keyboard': 'bàn phím',
  'mouse': 'chuột máy tính',
};

/// Dịch vụ nhận diện vật thể dùng YOLOv8 TFLite
class DetectorService {
  static const String _modelPath = 'assets/models/yolov8n_int8.tflite';
  static const String _labelPath = 'assets/labels/coco.txt';

  // Ngưỡng lọc (Đặt 0.15 để độ nhạy cao hơn khi test webcam)
  static const double _confidenceThreshold = 0.15;
  static const double _iouThreshold = 0.45;

  Interpreter? _interpreter;
  List<String> _labels = [];
  bool _isLoaded = false;
  int _frameCount = 0;

  bool get isLoaded => _isLoaded;

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

      _isLoaded = true;
      
      final inputTensor = _interpreter!.getInputTensor(0);
      final outputTensor = _interpreter!.getOutputTensor(0);
      debugPrint('=== SMART EYE TFLITE DIAGNOSTICS ===');
      debugPrint('Input Tensor: shape=${inputTensor.shape}, type=${inputTensor.type}, scale=${inputTensor.params.scale}, zeroPoint=${inputTensor.params.zeroPoint}');
      debugPrint('Output Tensor: shape=${outputTensor.shape}, type=${outputTensor.type}, scale=${outputTensor.params.scale}, zeroPoint=${outputTensor.params.zeroPoint}');
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

    final inputTensor = ImageUtils.cameraImageToFloat32(image, rotationDegrees: rotationDegrees);
    if (inputTensor == null) return [];

    final inputShape = _interpreter!.getInputTensor(0).shape;
    final inputType = _interpreter!.getInputTensor(0).type;
    final inputScale = _interpreter!.getInputTensor(0).params.scale;
    final inputZeroPoint = _interpreter!.getInputTensor(0).params.zeroPoint;

    Object input;
    if (inputType == TensorType.int8) {
      final int8Input = Int8List(inputTensor.length);
      double realScale = inputScale == 0 ? (1.0 / 255.0) : inputScale;
      for (int i = 0; i < inputTensor.length; i++) {
        int quantized = ((inputTensor[i] / realScale) + inputZeroPoint).round();
        int8Input[i] = quantized.clamp(-128, 127);
      }
      input = int8Input.reshape(inputShape);
    } else if (inputType == TensorType.uint8) {
      final uint8Input = Uint8List(inputTensor.length);
      double realScale = inputScale == 0 ? (1.0 / 255.0) : inputScale;
      for (int i = 0; i < inputTensor.length; i++) {
        int quantized = ((inputTensor[i] / realScale) + inputZeroPoint).round();
        uint8Input[i] = quantized.clamp(0, 255);
      }
      input = uint8Input.reshape(inputShape);
    } else {
      input = inputTensor.reshape(inputShape);
    }

    final outputTensor = _interpreter!.getOutputTensor(0);
    final outputShape = outputTensor.shape;
    final outputType = outputTensor.type;
    final outputScale = outputTensor.params.scale;
    final outputZeroPoint = outputTensor.params.zeroPoint;

    final outputData = List.generate(
      outputShape[0],
      (_) => List.generate(
        outputShape[1],
        (_) => List.filled(outputShape[2], 0.0),
      ),
    );

    _interpreter!.run(input, outputData);

    _frameCount++;

    return _parseOutput(
      outputData,
      screenWidth: screenWidth,
      screenHeight: screenHeight,
      outputScale: outputScale,
      outputZeroPoint: outputZeroPoint,
      isQuantized: outputType == TensorType.int8 || outputType == TensorType.uint8,
    );
  }

  // ---------------------------------------------------------------------------
  // Parse & NMS
  // ---------------------------------------------------------------------------

  List<Recognition> _parseOutput(
    List<List<List<double>>> output, {
    required double screenWidth,
    required double screenHeight,
    required double outputScale,
    required int outputZeroPoint,
    required bool isQuantized,
  }) {
    final data = output[0]; // [84, 8400]
    final numAnchors = data[0].length; // 8400
    final double inputSize = ImageUtils.inputSize.toDouble();

    final List<Recognition> candidates = [];

    double getValue(double val) {
      if (!isQuantized || outputScale == 0) return val;
      return (val - outputZeroPoint) * outputScale;
    }

    double maxOverallScore = 0.0;
    int maxOverallClass = -1;

    for (int i = 0; i < numAnchors; i++) {
      final double cx = getValue(data[0][i]);
      final double cy = getValue(data[1][i]);
      final double bw = getValue(data[2][i]);
      final double bh = getValue(data[3][i]);

      double maxScore = 0.0;
      int maxClassIdx = -1;
      for (int c = 0; c < _labels.length; c++) {
        final double score = getValue(data[4 + c][i]);
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

      // Tự động phát hiện tọa độ là chuẩn hóa [0..1] hay pixel [0..640]
      bool isNormalized = (cx <= 1.5 && bw <= 1.5);
      final double scaleX = isNormalized ? screenWidth : (screenWidth / inputSize);
      final double scaleY = isNormalized ? screenHeight : (screenHeight / inputSize);

      final double left   = (cx - bw / 2) * scaleX;
      final double top    = (cy - bh / 2) * scaleY;
      final double right  = (cx + bw / 2) * scaleX;
      final double bottom = (cy + bh / 2) * scaleY;

      final double clampedLeft   = left.clamp(0, screenWidth);
      final double clampedTop    = top.clamp(0, screenHeight);
      final double clampedRight  = right.clamp(0, screenWidth);
      final double clampedBottom = bottom.clamp(0, screenHeight);

      if (clampedRight <= clampedLeft || clampedBottom <= clampedTop) continue;

      final labelEn = _labels[maxClassIdx];
      final labelVi = _labelVi[labelEn] ?? labelEn;

      candidates.add(Recognition(
        maxClassIdx,
        labelVi,
        maxScore,
        Rect.fromLTRB(clampedLeft, clampedTop, clampedRight, clampedBottom),
      ));
    }

    if (_frameCount % 10 == 0) {
      final maxLabel = maxOverallClass >= 0 && maxOverallClass < _labels.length ? _labels[maxOverallClass] : 'none';
      debugPrint('[Frame $_frameCount] Max score: ${(maxOverallScore * 100).toStringAsFixed(1)}% ($maxLabel), Candidates: ${candidates.length}');
    }

    // Bước 5: Non-Maximum Suppression
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
