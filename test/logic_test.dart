import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/models/Recognition.dart';
import 'package:smart_eye/models/scene_info.dart';
import 'package:smart_eye/models/trip.dart';
import 'package:smart_eye/services/caption_builder.dart';
import 'package:smart_eye/services/hazard_engine.dart';
import 'package:smart_eye/services/object_tracker.dart';

const frame = Size(400, 800);

Recognition rec(String en, String vi, int id, Rect r) => Recognition(id, vi, 0.9, r, labelEn: en);

/// Box nằm giữa, cao [ratio] khung hình
Rect centerBox(double ratio, {double cx = 200, double aspect = 0.5}) {
  final h = frame.height * ratio;
  final w = h * aspect;
  return Rect.fromLTWH(cx - w / 2, frame.height * 0.95 - h, w, h);
}

/// Chạy [frames] frame với cùng 1 danh sách detection, trả về đánh giá cuối
SceneAssessment run(ObjectTracker tracker, HazardEngine engine, List<Recognition> dets,
    {int frames = 4, DateTime? start}) {
  var t = start ?? DateTime(2026);
  var scene = SceneAssessment.empty;
  for (int i = 0; i < frames; i++) {
    scene = engine.assess(tracker.update(dets, frame, t), frame);
    t = t.add(const Duration(milliseconds: 150));
  }
  return scene;
}

void main() {
  group('ObjectTracker (CN5)', () {
    test('vật xa: xác nhận sau 2 lần quét, giữ ID ổn định', () {
      final tracker = ObjectTracker();
      final d = [rec('car', 'xe ô tô', 2, centerBox(0.3))];
      final t0 = DateTime(2026);
      expect(tracker.update(d, frame, t0), isEmpty);
      final confirmed = tracker.update(d, frame, t0);
      expect(confirmed, hasLength(1));
      final id = confirmed.single.id;
      expect(tracker.update(d, frame, t0).single.id, id);
    });

    test('vật gần + điểm cao: báo ngay từ lần quét đầu tiên (không chờ)', () {
      final tracker = ObjectTracker();
      final near = [rec('person', 'người', 0, centerBox(0.6))];
      expect(tracker.update(near, frame, DateTime(2026)), hasLength(1));
      // Vật gần nhưng điểm thấp (dễ là báo nhầm) → vẫn chờ lần 2
      final weak = [Recognition(0, 'người', 0.3, centerBox(0.6, cx: 100), labelEn: 'person')];
      expect(ObjectTracker().update(weak, frame, DateTime(2026)), isEmpty);
    });

    test('mất 1–2 frame không làm mất vật (hysteresis)', () {
      final tracker = ObjectTracker();
      final d = [rec('car', 'xe ô tô', 2, centerBox(0.3))];
      final t0 = DateTime(2026);
      for (int i = 0; i < 3; i++) {
        tracker.update(d, frame, t0);
      }
      expect(tracker.update([], frame, t0), hasLength(1));
      expect(tracker.update([], frame, t0), hasLength(1));
      for (int i = 0; i < 4; i++) {
        tracker.update([], frame, t0);
      }
      expect(tracker.update([], frame, t0), isEmpty);
    });
  });

  group('HazardEngine (CN4/CN6/CN7)', () {
    test('khoảng cách theo % box có vùng trễ', () {
      expect(HazardEngine.distanceWithHysteresis(null, 0.65), DistanceLevel.near);
      expect(HazardEngine.distanceWithHysteresis(null, 0.55), DistanceLevel.medium);
      // Đang "gần" thì phải xuống dưới 0.52 mới đổi mức
      expect(HazardEngine.distanceWithHysteresis(DistanceLevel.near, 0.55), DistanceLevel.near);
      expect(HazardEngine.distanceWithHysteresis(null, 0.1), DistanceLevel.far);
    });

    test('vật cản rất gần ngay phía trước → Dừng lại', () {
      final scene = run(ObjectTracker(), HazardEngine(), [rec('chair', 'ghế', 56, centerBox(0.7))]);
      expect(scene.alert?.level, AlertLevel.danger);
      expect(scene.alert?.guidance, Guidance.stop);
      expect(scene.alert?.message, startsWith('Dừng lại!'));
    });

    test('vật cản cách ~2m ở giữa, bên trái có người → gợi ý đi sang phải', () {
      final scene = run(ObjectTracker(), HazardEngine(), [
        rec('chair', 'ghế', 56, centerBox(0.4)),
        rec('person', 'người', 0, Rect.fromLTWH(10, 100, 110, 600)),
      ]);
      expect(scene.alert?.level, AlertLevel.caution);
      expect(scene.alert?.guidance, Guidance.goRight);
      expect(scene.isColumnFree(HPos.left), isFalse);
      expect(scene.isColumnFree(HPos.right), isTrue);
    });

    test('người đi phía trước ở 2m không bị báo (nói ít)', () {
      final scene = run(ObjectTracker(), HazardEngine(), [rec('person', 'người', 0, centerBox(0.4))]);
      expect(scene.alert, isNull);
    });

    test('xe máy phình to dần → đang tới gần → nguy hiểm', () {
      final tracker = ObjectTracker();
      final engine = HazardEngine();
      var t = DateTime(2026);
      var scene = SceneAssessment.empty;
      for (int i = 0; i < 10; i++) {
        final ratio = 0.3 + i * 0.02; // vẫn dưới ngưỡng "gần"
        scene = engine.assess(tracker.update([rec('motorcycle', 'xe máy', 3, centerBox(ratio))], frame, t), frame);
        t = t.add(const Duration(milliseconds: 150));
      }
      expect(scene.objects.single.approaching, isTrue);
      expect(scene.alert?.level, AlertLevel.danger);
      expect(scene.alert?.message, contains('đang tới gần'));
    });

    test('vật không liên quan (cốc) không gây cảnh báo', () {
      final scene = run(ObjectTracker(), HazardEngine(), [rec('cup', 'cốc', 41, centerBox(0.7))]);
      expect(scene.alert, isNull);
    });
  });

  group('CaptionBuilder (CN8/CN13)', () {
    test('mô tả gộp vật cùng loại cùng phía', () {
      final scene = run(ObjectTracker(), HazardEngine(), [
        rec('person', 'người', 0, centerBox(0.4, cx: 180)),
        rec('person', 'người', 0, centerBox(0.2, cx: 230)),
        rec('motorcycle', 'xe máy', 3, centerBox(0.15, cx: 350)),
      ]);
      final text = CaptionBuilder.describeScene(scene);
      expect(text, contains('Phía trước có 2 người, gần nhất cách khoảng 2 mét.'));
      expect(text, contains('Bên phải có xe máy, ở xa.'));
    });

    test('không có gì → câu ngắn', () {
      expect(CaptionBuilder.describeScene(SceneAssessment.empty), 'Phía trước không thấy vật cản nào.');
    });

    test('recap chuyến đi', () {
      final trip = TripSummary(
        id: 'x',
        startTime: DateTime(2026, 9, 23, 7, 30),
        endTime: DateTime(2026, 9, 23, 8, 15),
        distanceMeters: 1234,
        dangerCount: 3,
      );
      expect(
        CaptionBuilder.recap(trip),
        'Chuyến đi lúc 7 giờ 30 sáng ngày 23 tháng 9: đi khoảng 1,2 ki lô mét trong 45 phút, '
        'gặp 3 cảnh báo nguy hiểm.',
      );
    });
  });
}
