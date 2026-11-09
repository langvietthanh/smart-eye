import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/models/Recognition.dart';
import 'package:smart_eye/models/scene_info.dart';
import 'package:smart_eye/models/trip.dart';
import 'package:smart_eye/services/caption_builder.dart';
import 'package:smart_eye/services/hazard_engine.dart';
import 'package:smart_eye/services/object_tracker.dart';
import 'package:smart_eye/utils/label_catalog.dart';

const frame = Size(400, 800);

Recognition rec(String en, String vi, int id, Rect r) =>
    Recognition(id, vi, 0.9, r, labelEn: en);

/// Box nằm giữa, cao [ratio] khung hình
Rect centerBox(double ratio, {double cx = 200, double aspect = 0.5}) {
  final h = frame.height * ratio;
  final w = h * aspect;
  return Rect.fromLTWH(cx - w / 2, frame.height * 0.95 - h, w, h);
}

/// Chạy [frames] frame với cùng 1 danh sách detection, trả về đánh giá cuối
SceneAssessment run(
  ObjectTracker tracker,
  HazardEngine engine,
  List<Recognition> dets, {
  int frames = 4,
  DateTime? start,
}) {
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

    test('nhận diện chập chờn không cộng dồn thành vật đã xác nhận', () {
      final tracker = ObjectTracker();
      final d = [rec('car', 'xe ô tô', 2, centerBox(0.3))];
      final t0 = DateTime(2026);
      for (int i = 0; i < 4; i++) {
        expect(tracker.update(d, frame, t0), isEmpty);
        expect(tracker.update([], frame, t0), isEmpty);
      }
      expect(tracker.update(d, frame, t0), isEmpty);
      expect(tracker.update(d, frame, t0), isEmpty);
      expect(tracker.update(d, frame, t0), hasLength(1));
    });

    test('vật đã xác nhận giữ ID khi xuất hiện lại sau vài frame mất', () {
      final tracker = ObjectTracker();
      final d = [rec('car', 'xe ô tô', 2, centerBox(0.3))];
      final t0 = DateTime(2026);
      tracker.update(d, frame, t0);
      tracker.update(d, frame, t0);
      final id = tracker.update(d, frame, t0).single.id;
      for (int i = 0; i < 3; i++) {
        tracker.update([], frame, t0);
      }
      expect(tracker.update(d, frame, t0).single.id, id);
    });
  });

  group('HazardEngine (CN4/CN6/CN7)', () {
    test('khoảng cách theo % box có vùng trễ', () {
      expect(
        HazardEngine.distanceWithHysteresis(null, 0.65),
        DistanceLevel.near,
      );
      expect(
        HazardEngine.distanceWithHysteresis(null, 0.42),
        DistanceLevel.medium,
      );
      // Vùng trễ tránh nhảy mức khi chiếm ảnh dao động quanh ngưỡng.
      expect(
        HazardEngine.distanceWithHysteresis(DistanceLevel.near, 0.42),
        DistanceLevel.near,
      );
      expect(HazardEngine.distanceWithHysteresis(null, 0.1), DistanceLevel.far);
    });

    test('vật cản rất gần ngay phía trước → Dừng lại', () {
      final scene = run(ObjectTracker(), HazardEngine(), [
        rec('chair', 'ghế', 56, centerBox(0.7)),
      ]);
      expect(scene.alert?.level, AlertLevel.danger);
      expect(scene.alert?.guidance, Guidance.stop);
      expect(scene.alert?.message, startsWith('Dừng lại!'));
    });

    test('vật ở giữa → đi chậm, không suy diễn mét hay chỉ đường trống', () {
      final scene = run(ObjectTracker(), HazardEngine(), [
        rec('chair', 'ghế', 56, centerBox(0.4)),
        rec('person', 'người', 0, Rect.fromLTWH(10, 100, 110, 600)),
      ]);
      expect(scene.alert?.level, AlertLevel.caution);
      expect(scene.alert?.guidance, Guidance.slowDown);
      expect(scene.alert?.message, 'Chậm lại. Có ghế ngay phía trước.');
      expect(scene.alert?.message, isNot(contains('mét')));
      expect(scene.isColumnFree(HPos.left), isFalse);
      expect(scene.isColumnFree(HPos.right), isTrue);
    });

    test('người chắn phía trước được báo chú ý sớm', () {
      final scene = run(ObjectTracker(), HazardEngine(), [
        rec('person', 'người', 0, centerBox(0.4)),
      ]);
      expect(scene.alert?.level, AlertLevel.caution);
    });

    test('xe máy phình to dần → đang tới gần → nguy hiểm', () {
      final tracker = ObjectTracker();
      final engine = HazardEngine();
      var t = DateTime(2026);
      var scene = SceneAssessment.empty;
      for (int i = 0; i < 10; i++) {
        final ratio = 0.3 + i * 0.02; // vẫn dưới ngưỡng "gần"
        scene = engine.assess(
          tracker.update(
            [rec('motorcycle', 'xe máy', 3, centerBox(ratio))],
            frame,
            t,
          ),
          frame,
        );
        t = t.add(const Duration(milliseconds: 150));
      }
      expect(scene.objects.single.approaching, isTrue);
      expect(scene.alert?.level, AlertLevel.danger);
      expect(scene.alert?.message, 'Dừng lại! Có xe máy ngay phía trước.');
      expect(scene.alert?.message, isNot(contains('đang tới gần')));
    });

    test('vật không liên quan (cốc) không gây cảnh báo', () {
      final scene = run(ObjectTracker(), HazardEngine(), [
        rec('cup', 'cốc', 41, centerBox(0.7)),
      ]);
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
      expect(text, contains('Phía trước có 2 người, gần nhất khá gần.'));
      expect(text, contains('Bên phải có xe máy, còn xa.'));
    });

    test('nói hướng đi TRƯỚC, rồi mới tới vật (tối đa 2 nhóm)', () {
      final scene = run(ObjectTracker(), HazardEngine(), [
        rec('chair', 'ghế', 56, centerBox(0.4)),
        rec('person', 'người', 0, Rect.fromLTWH(10, 100, 110, 600)),
      ]);
      final text = CaptionBuilder.describeScene(scene);
      expect(text, startsWith('Phía trước bị chắn, bên phải trống.'));
    });

    test('phía trước trống nhưng một bên có vật → nói rõ bên nào', () {
      final scene = run(ObjectTracker(), HazardEngine(), [rec('person', 'người', 0, Rect.fromLTWH(10, 100, 110, 600))]);
      expect(CaptionBuilder.describeScene(scene), startsWith('Phía trước trống, bên trái có vật cản.'));
    });

    test('không có gì → câu ngắn', () {
      expect(
        CaptionBuilder.describeScene(SceneAssessment.empty),
        'Chưa nhận diện được vật, chưa có lối đi an toàn.',
      );
    });

    test('recap chuyến đi hôm nay và khác ngày', () {
      final trip = TripSummary(
        id: 'x',
        startTime: DateTime(2026, 9, 23, 7, 30),
        endTime: DateTime(2026, 9, 23, 8, 15),
        distanceMeters: 1234,
        dangerCount: 3,
      );
      // Cùng ngày (hôm nay)
      expect(
        CaptionBuilder.recap(trip, now: DateTime(2026, 9, 23, 12, 0)),
        'Chuyến đi lúc 7 giờ 30 sáng hôm nay: đi khoảng 1,2 ki lô mét trong 45 phút, '
        'gặp 3 cảnh báo nguy hiểm.',
      );
      // Khác ngày
      expect(
        CaptionBuilder.recap(trip, now: DateTime(2026, 9, 24, 10, 0)),
        'Chuyến đi lúc 7 giờ 30 sáng ngày 23 tháng 9: đi khoảng 1,2 ki lô mét trong 45 phút, '
        'gặp 3 cảnh báo nguy hiểm.',
      );
    });

    test('5 câu freeSpaceSentence', () {
      // 1. Giữa trống
      expect(
        CaptionBuilder.freeSpaceSentence(
          const SceneAssessment(objects: [], columnLoad: [1.0, 0.0, 1.0]),
        ),
        'Phía trước chưa thấy vật cản.',
      );

      // 2. Giữa có vật, hai bên trống
      expect(
        CaptionBuilder.freeSpaceSentence(
          const SceneAssessment(objects: [], columnLoad: [0.0, 1.0, 0.0]),
        ),
        'Vật phía trước. Hai bên chưa thấy vật.',
      );

      // 3. Giữa có vật, trái trống
      expect(
        CaptionBuilder.freeSpaceSentence(
          const SceneAssessment(objects: [], columnLoad: [0.0, 1.0, 1.0]),
        ),
        'Vật phía trước và bên phải. Bên trái chưa thấy vật.',
      );

      // 4. Giữa có vật, phải trống
      expect(
        CaptionBuilder.freeSpaceSentence(
          const SceneAssessment(objects: [], columnLoad: [1.0, 1.0, 0.0]),
        ),
        'Vật phía trước và bên trái. Bên phải chưa thấy vật.',
      );

      // 5. Cả 3 có vật
      expect(
        CaptionBuilder.freeSpaceSentence(
          const SceneAssessment(objects: [], columnLoad: [1.0, 1.0, 1.0]),
        ),
        'Đứng lại, có vật ở 3 hướng.',
      );
    });
  });

  group('HazardEngine câu cảnh báo mới', () {
    test('vật tĩnh (ghế, bàn) không bao giờ nói đang tới gần', () {
      final tracker = ObjectTracker();
      final engine = HazardEngine();
      var t = DateTime(2026);
      var scene = SceneAssessment.empty;
      // Ghế phình to dần ở tốc độ vừa phải, giữ khoảng cách medium
      for (int i = 0; i < 5; i++) {
        final ratio = 0.16 + i * 0.015;
        scene = engine.assess(
          tracker.update(
            [rec('chair', 'ghế', 56, centerBox(ratio))],
            frame,
            t,
          ),
          frame,
        );
        t = t.add(const Duration(milliseconds: 150));
      }
      expect(scene.alert?.level, AlertLevel.caution);
      expect(scene.alert?.message, 'Chậm lại. Có ghế ngay phía trước.');
      expect(scene.alert?.message, isNot(contains('đang tới gần')));
    });

    test('xe đang tới gần ở mức caution', () {
      final tracker = ObjectTracker();
      final engine = HazardEngine();
      var t = DateTime(2026);
      var scene = SceneAssessment.empty;
      // Xe máy ở cột phải phình to dần
      for (int i = 0; i < 5; i++) {
        final h = 100.0 + i * 20.0;
        final w = h * 0.6;
        final rightBox = Rect.fromLTWH(300, 400 - h, w, h);
        scene = engine.assess(
          tracker.update(
            [rec('motorcycle', 'xe máy', 3, rightBox)],
            frame,
            t,
          ),
          frame,
        );
        t = t.add(const Duration(milliseconds: 150));
      }
      expect(scene.alert?.level, AlertLevel.caution);
      expect(scene.alert?.message, 'Chậm lại. Xe máy bên phải đang tới gần.');
    });

    test('danger không bao giờ có đang tới gần', () {
      final tracker = ObjectTracker();
      final engine = HazardEngine();
      var t = DateTime(2026);
      var scene = SceneAssessment.empty;
      for (int i = 0; i < 10; i++) {
        final ratio = 0.3 + i * 0.03;
        scene = engine.assess(
          tracker.update(
            [rec('motorcycle', 'xe máy', 3, centerBox(ratio))],
            frame,
            t,
          ),
          frame,
        );
        t = t.add(const Duration(milliseconds: 150));
      }
      expect(scene.alert?.level, AlertLevel.danger);
      expect(scene.alert?.message, 'Dừng lại! Có xe máy ngay phía trước.');
      expect(scene.alert?.message, isNot(contains('đang tới gần')));
    });

    test('vật bên trái trong lối đi → bên trái', () {
      final tracker = ObjectTracker();
      final engine = HazardEngine();
      // center.dx = 50 + 70 = 120 < 133.33 (HPos.left); right = 190 lấn vào cột giữa > 133.33 + 53.33 (inPath)
      final leftInPathBox = Rect.fromLTWH(50, 200, 140, 550);
      final scene = run(tracker, engine, [
        rec('chair', 'ghế', 56, leftInPathBox),
      ]);
      expect(scene.alert?.level, AlertLevel.danger);
      expect(scene.alert?.message, 'Dừng lại! Có ghế bên trái.');
      expect(scene.alert?.message, isNot(contains('lệch')));
    });
  });

  group('Lọc nhãn không dùng trong pipeline', () {
    test('ignoredLabels chứa đúng 7 nhãn nhận nhầm và lọc sạch trước pipeline', () {
      expect(ignoredLabels, {
        'elephant',
        'giraffe',
        'zebra',
        'bear',
        'aeroplane',
        'airplane',
        'boat',
      });

      final rawDetections = [
        rec('elephant', 'voi', 20, centerBox(0.6)),
        rec('bear', 'gấu', 21, centerBox(0.6)),
        rec('airplane', 'máy bay', 4, centerBox(0.6)),
        rec('boat', 'thuyền', 8, centerBox(0.6)),
        rec('chair', 'ghế', 56, centerBox(0.5)),
      ];

      final filtered = rawDetections
          .where((d) => !ignoredLabels.contains(d.labelEn))
          .toList();

      expect(filtered.map((d) => d.labelEn), ['chair']);

      final tracker = ObjectTracker();
      final engine = HazardEngine();
      final scene = run(tracker, engine, filtered);

      expect(scene.objects.map((o) => o.track.labelEn), ['chair']);
      expect(scene.alert?.message, 'Dừng lại! Có ghế ngay phía trước.');
      expect(CaptionBuilder.describeScene(scene), isNot(contains('voi')));
      expect(CaptionBuilder.describeScene(scene), isNot(contains('gấu')));
    });

    test('từ điển nhãn tiếng Việt được cập nhật đúng', () {
      expect(labelVi['laptop'], 'laptop');
      expect(labelVi['parking meter'], 'cột đỗ xe');
      expect(labelVi['fire hydrant'], 'trụ cứu hỏa');
      expect(categoryOf('bear'), ObjectCategory.other);
    });
  });

  test('detector keeps every categorised class and signs, drops the rest', () {
    for (final label in ['cow', 'horse', 'suitcase', 'chair', 'car']) {
      expect(isDetectionRelevant(label), isTrue, reason: label);
    }
    expect(isDetectionRelevant('traffic light'), isTrue);
    expect(isDetectionRelevant('stop sign'), isTrue);
    expect(isDetectionRelevant('cup'), isFalse);
    expect(isDetectionRelevant('book'), isFalse);
  });
}
