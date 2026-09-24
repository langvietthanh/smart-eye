
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/Recognition.dart';
import '../models/scene_info.dart';
import '../utils/label_catalog.dart';
import 'detection/detector_worker.dart';
import 'detection/frame_data.dart';
import 'detection/model_metadata.dart';

/// F1 — Nhận diện vật thể YOLO (TFLite) chạy ở isolate riêng.
///
/// - Tên lớp đọc từ metadata nhúng trong model (fallback `coco.txt`) → thay model có lớp mới
///   (cầu thang, cột điện...) không cần sửa code.
/// - Chỉ xét các lớp liên quan tới đi lại (category khác "other").
/// - Tự chọn CPU / GPU (Android) hoặc CPU / Metal / CoreML (iOS) theo tốc độ đo lúc khởi động.
class DetectorService {
  /// Model train riêng (có lớp cầu thang, cột điện...) — chỉ cần chép file vào đây là app tự dùng.
  static const String _customModelPath = 'assets/models/smart_eye.tflite';

  /// Model COCO mặc định (dùng khi chưa có model train riêng)
  static const String _defaultModelPath = 'assets/models/yolov8n_int8.tflite';
  static const String _labelPath = 'assets/labels/coco.txt';

  // Ngưỡng lọc — 0.25 là mặc định Ultralytics. Đo trên COCO128 (xem README):
  // 0.15 → precision 0.71, 149 box sai; 0.25 → precision 0.83, 64 box sai, recall vật lớn gần như giữ nguyên.
  static const double confidenceThreshold = 0.25;
  static const double iouThreshold = 0.45;

  DetectorWorker? _worker;
  List<String> _labels = [];
  List<int> _classIds = [];

  bool get isLoaded => _worker != null;
  List<String> get labels => _labels;

  /// Số lớp model có / số lớp đang xét
  int get modelClassCount => _labels.length;
  int get activeClassCount => _classIds.length;

  WorkerInfo? get info => _worker?.info;

  /// Kết quả lần quét gần nhất — cho dòng chẩn đoán trên màn hình
  DetectionBatch? lastBatch;
  int _scanCount = 0;

  Future<void> loadModel({String preferredBackend = 'auto'}) async {
    final bytes = await _loadModelBytes();
    final meta = ModelMetadata.parse(bytes);
    _labels = meta.names ?? await _loadLabelFile();
    _classIds = [
      for (var i = 0; i < _labels.length; i++)
        if (categoryOf(_labels[i]) != ObjectCategory.other) i,
    ];

    _worker = await DetectorWorker.start(
      modelBytes: bytes,
      classIds: _classIds,
      confThreshold: confidenceThreshold,
      iouThreshold: iouThreshold,
      preferredBackend: preferredBackend,
    );

    final info = _worker!.info;
    debugPrint('=== SMART EYE DETECTOR ===');
    debugPrint('Model: $modelPath (${meta.description ?? '?'}) · nhãn từ ${meta.names != null ? 'metadata' : 'coco.txt'}');
    debugPrint('Lớp: ${_labels.length} (xét ${_classIds.length}) · input ${info.inputSize} '
        '${info.channelsFirst ? 'NCHW' : 'NHWC'} · output ${info.outputShape}');
    debugPrint('Backend: ${info.backend} · benchmark ms: ${info.benchmark}');
    info.rejected.forEach((backend, reason) => debugPrint('Không dùng $backend: $reason'));
  }

  /// Đường dẫn model đang dùng
  String modelPath = _defaultModelPath;

  Future<Uint8List> _loadModelBytes() async {
    for (final path in [_customModelPath, _defaultModelPath]) {
      try {
        final data = await rootBundle.load(path);
        modelPath = path;
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } catch (_) {
        // Chưa có model train riêng → thử model mặc định
      }
    }
    throw StateError('Không tìm thấy model trong assets/models/');
  }

  Future<List<String>> _loadLabelFile() async => (await rootBundle.loadString(_labelPath))
      .split('\n')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  /// Quét 1 frame ở isolate AI. Phần chạy trên luồng UI chỉ là copy frame (~1 ms).
  Future<DetectionBatch> detect(CameraImage image, {required int rotation, CropRect crop = CropRect.full}) async {
    final worker = _worker;
    if (worker == null) throw StateError('Model chưa nạp');
    final batch = await worker.detect(FramePacket.fromCameraImage(image), rotation: rotation, crop: crop);
    lastBatch = batch;
    if (batch.error != null) debugPrint('Detector: ${batch.error}');
    if (++_scanCount % 20 == 0) {
      debugPrint('[Scan $_scanCount] ${batch.backend}${batch.verifying ? ' (đối chiếu CPU)' : ''} ${batch.totalMs.toStringAsFixed(1)}ms '
          '(ảnh ${batch.prepMs.toStringAsFixed(1)} · AI ${batch.inferMs.toStringAsFixed(1)} · '
          'đọc ${batch.parseMs.toStringAsFixed(1)}) · ${batch.crop.isFull ? 'toàn khung' : 'hành lang'} · '
          'motion ${batch.motion.toStringAsFixed(3)} · ${batch.detections.length} vật · '
          'max ${labelOf(batch.maxClassId)} ${(batch.maxScore * 100).toStringAsFixed(0)}%');
    }
    return batch;
  }

  /// JPEG của frame vừa quét gần nhất (ảnh ghi nhớ)
  Future<Uint8List?> thumbnail() async => _worker?.thumbnail();

  /// Đổi kết quả (toạ độ chuẩn hoá) sang toạ độ màn hình + tên tiếng Việt
  List<Recognition> toRecognitions(DetectionBatch batch, Size screen) => [
        for (final d in batch.detections)
          Recognition(
            d.classId,
            labelVi[_labels[d.classId]] ?? _labels[d.classId],
            d.score,
            Rect.fromLTRB(d.left * screen.width, d.top * screen.height, d.right * screen.width, d.bottom * screen.height),
            labelEn: _labels[d.classId],
          ),
      ];

  /// Tên (tiếng Việt) của lớp — cho dòng chẩn đoán
  String labelOf(int classId) =>
      classId < 0 || classId >= _labels.length ? '' : (labelVi[_labels[classId]] ?? _labels[classId]);

  void dispose() {
    _worker?.dispose();
    _worker = null;
  }
}
