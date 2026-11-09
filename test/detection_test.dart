import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/services/detection/model_metadata.dart';
import 'package:smart_eye/services/detection/scan_scheduler.dart';
import 'package:smart_eye/services/detection/yolo_decoder.dart';

/// Output giả dạng YOLOv8 `[1, 4 + numClasses, anchors]` (theo cột: channel-major)
Float32List fakeOutput(int numClasses, List<({double cx, double cy, double w, double h, int cls, double score})> boxes,
    {int anchors = 8}) {
  final out = Float32List((4 + numClasses) * anchors);
  for (var i = 0; i < boxes.length; i++) {
    final b = boxes[i];
    out[0 * anchors + i] = b.cx;
    out[1 * anchors + i] = b.cy;
    out[2 * anchors + i] = b.w;
    out[3 * anchors + i] = b.h;
    out[(4 + b.cls) * anchors + i] = b.score;
  }
  return out;
}

void main() {
  group('YoloDecoder', () {
    const shape = [1, 4 + 3, 8];

    test('lọc theo ngưỡng, chỉ xét lớp được chọn', () {
      final out = fakeOutput(3, [
        (cx: 0.5, cy: 0.5, w: 0.2, h: 0.4, cls: 0, score: 0.9),
        (cx: 0.2, cy: 0.2, w: 0.1, h: 0.1, cls: 1, score: 0.1), // dưới ngưỡng
        (cx: 0.8, cy: 0.8, w: 0.1, h: 0.1, cls: 2, score: 0.9), // lớp không được xét
      ]);
      final r = YoloDecoder.decode(output: out, shape: shape, classIds: [0, 1], inputSize: 320);
      expect(r.detections, hasLength(1));
      final d = r.detections.single;
      expect(d.classId, 0);
      expect(d.left, closeTo(0.4, 1e-6));
      expect(d.bottom, closeTo(0.7, 1e-6));
      expect(r.maxScore, closeTo(0.9, 1e-6));
    });

    test('toạ độ pixel [0..inputSize] được chuẩn hoá', () {
      final out = fakeOutput(1, [(cx: 160, cy: 160, w: 64, h: 128, cls: 0, score: 0.8)]);
      final d = YoloDecoder.decode(output: out, shape: const [1, 5, 8], classIds: [0], inputSize: 320).detections.single;
      expect(d.left, closeTo(0.4, 1e-6));
      expect(d.top, closeTo(0.3, 1e-6));
    });

    test('NMS: bỏ box trùng cùng lớp, gộp box gần như trùng hẳn khác lớp', () {
      final out = fakeOutput(3, [
        (cx: 0.5, cy: 0.5, w: 0.4, h: 0.4, cls: 0, score: 0.9),
        (cx: 0.52, cy: 0.5, w: 0.4, h: 0.4, cls: 0, score: 0.8), // trùng cùng lớp
        (cx: 0.5, cy: 0.5, w: 0.4, h: 0.41, cls: 1, score: 0.7), // "xe tải" trên cùng chiếc "ô tô"
        (cx: 0.15, cy: 0.15, w: 0.2, h: 0.2, cls: 1, score: 0.6), // vật khác
      ]);
      final r = YoloDecoder.decode(output: out, shape: shape, classIds: [0, 1, 2], inputSize: 320);
      expect(r.detections.map((d) => '${d.classId}:${d.score.toStringAsFixed(2)}').toList(), ['0:0.90', '1:0.60']);
    });


    test('output chuyển vị [1, anchors, 4 + lớp] cũng đọc được', () {
      const anchors = 8, channels = 5;
      final out = Float32List(anchors * channels);
      out.setAll(0, [0.5, 0.5, 0.2, 0.2, 0.9]); // anchor 0
      final r = YoloDecoder.decode(output: out, shape: const [1, anchors, channels], classIds: [0], inputSize: 320);
      expect(r.detections.single.score, closeTo(0.9, 1e-6));
    });
  });

  group('So sánh CPU / GPU', () {
    test('lệch toạ độ ở ô điểm ~0 được bỏ qua, lệch ở ô có vật thì bị bắt', () {
      final cpu = fakeOutput(1, [(cx: 0.5, cy: 0.5, w: 0.2, h: 0.2, cls: 0, score: 0.9)]);
      final gpu = Float32List.fromList(cpu);
      gpu[1] = 0.9; // anchor 1 (điểm 0): toạ độ lệch 0.9 — không ảnh hưởng kết quả
      var d = YoloDecoder.compareOutputs(cpu, gpu, const [1, 5, 8], inputSize: 320);
      expect(d.boxMax, 0);
      expect(d.confident, 1);
      gpu[0] = 0.6; // anchor 0 (điểm 0.9): cx lệch 0.1 → bị bắt
      d = YoloDecoder.compareOutputs(cpu, gpu, const [1, 5, 8], inputSize: 320);
      expect(d.boxMax, closeTo(0.1, 1e-6));
    });

    test('danh sách vật: vật chắc chắn phải khớp, vật sát ngưỡng được bỏ qua', () {
      const car = RawDetection(2, 0.8, 0.1, 0.1, 0.5, 0.5);
      const carShifted = RawDetection(2, 0.78, 0.11, 0.1, 0.51, 0.5);
      const weakPerson = RawDetection(0, 0.27, 0.6, 0.6, 0.7, 0.9);
      expect(YoloDecoder.sameDetections([car, weakPerson], [carShifted]), isTrue);
      expect(YoloDecoder.sameDetections([car], []), isFalse);
      expect(YoloDecoder.sameDetections([car], [const RawDetection(7, 0.8, 0.1, 0.1, 0.5, 0.5)]), isFalse);
    });
  });

  group('ModelMetadata', () {
    test('đọc được tên lớp + kích thước ảnh từ model thật của app', () {
      final bytes = File('assets/models/yolov8n_int8.tflite').readAsBytesSync();
      final meta = ModelMetadata.parse(bytes);
      expect(meta.imageSize, 320);
      expect(meta.names, hasLength(80));
      expect(meta.names!.first, 'person');
      expect(meta.names![3], 'motorcycle');
      // Khớp file nhãn dự phòng
      final labels = File('assets/labels/coco.txt').readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
      expect(meta.names, labels);
    });

    test('model không có metadata → rỗng, không ném lỗi', () {
      final meta = ModelMetadata.parse(Uint8List.fromList(List.filled(100, 7)));
      expect(meta.names, isNull);
      expect(meta.imageSize, isNull);
    });
  });

  group('ScanScheduler', () {
    final t0 = DateTime(2026);
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

    test('chỉ 1 lần quét tại một thời điểm; máy rảnh là quét ngay (chỉ nghỉ 30 ms)', () {
      final s = ScanScheduler();
      expect(s.shouldScan(at(0)), isTrue);
      expect(s.shouldScan(at(10)), isFalse); // đang bận
      s.onResult(at(80), motion: 0.1, hazard: false, relevantObjects: true);
      expect(s.shouldScan(at(81)), isTrue); // đã ≥ 30 ms từ lần gửi trước
    });


    test('có nguy hiểm → chế độ cảnh báo; hết nguy hiểm 2 giây → về bình thường', () {
      final s = ScanScheduler();
      s.shouldScan(at(0));
      s.onResult(at(50), motion: 0.1, hazard: true, relevantObjects: true);
      expect(s.mode, ScanMode.alert);
      expect(s.shouldScan(at(51)), isTrue); // quét tiếp ngay
      s.onResult(at(100), motion: 0.1, hazard: false, relevantObjects: true);
      expect(s.mode, ScanMode.alert); // còn giữ
      s.shouldScan(at(2200));
      s.onResult(at(2200), motion: 0.1, hazard: false, relevantObjects: true);
      expect(s.mode, ScanMode.normal);
    });

    test('cảnh đứng yên 3 giây, không có vật → tiết kiệm; người dùng hỏi → quét ngay', () {
      final s = ScanScheduler();
      for (var ms = 0; ms <= 3200; ms += 400) {
        s.shouldScan(at(ms));
        s.onResult(at(ms + 10), motion: 0.001, hazard: false, relevantObjects: false);
      }
      expect(s.mode, ScanMode.idle);
      expect(s.shouldScan(at(3500)), isFalse); // chưa đủ 1 giây
      s.wakeUp();
      expect(s.shouldScan(at(3501)), isTrue);
    });
  });

}
