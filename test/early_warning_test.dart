import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/models/Recognition.dart';
import 'package:smart_eye/models/scene_info.dart';
import 'package:smart_eye/services/caption_builder.dart';
import 'package:smart_eye/services/hazard_engine.dart';
import 'package:smart_eye/services/object_tracker.dart';

const _frame = Size(400, 800);
Rect _box(double height) =>
    Rect.fromLTWH(160, 760 - 800 * height, 80, 800 * height);
Recognition _chair(double height, {double score = 0.9}) =>
    Recognition(56, 'ghế', score, _box(height), labelEn: 'chair');

void main() {
  test(
    'large central obstacle confirms after two strong observations, not one',
    () {
      final tracker = ObjectTracker();
      final engine = HazardEngine();
      final time = DateTime(2026);
      expect(tracker.update([_chair(0.48)], _frame, time), isEmpty);
      final tracks = tracker.update(
        [_chair(0.48)],
        _frame,
        time.add(const Duration(milliseconds: 150)),
      );
      final scene = engine.assess(tracks, _frame);
      expect(scene.alert?.level, AlertLevel.danger);
      expect(scene.alert?.message, 'Dừng lại! Ghế ngay phía trước.');
    },
  );

  test(
    'weak detections and one-frame flicker do not use early confirmation',
    () {
      final tracker = ObjectTracker();
      final time = DateTime(2026);
      expect(tracker.update([_chair(0.48, score: 0.3)], _frame, time), isEmpty);
      expect(tracker.update([_chair(0.48, score: 0.3)], _frame, time), isEmpty);
      tracker.reset();
      tracker.update([_chair(0.48, score: 0.3)], _frame, time);
      expect(tracker.update([_chair(0.48)], _frame, time), isEmpty);
      tracker.reset();
      tracker.update([_chair(0.48)], _frame, time);
      tracker.update([], _frame, time);
      expect(tracker.update([_chair(0.48)], _frame, time), isEmpty);
    },
  );

  test('a confirmed obstacle escalates from the raw box without EMA delay', () {
    final tracker = ObjectTracker();
    final engine = HazardEngine();
    final time = DateTime(2026);
    for (var i = 0; i < 3; i++) {
      tracker.update([_chair(0.35)], _frame, time);
    }
    final tracks = tracker.update(
      [_chair(0.48)],
      _frame,
      time.add(const Duration(milliseconds: 150)),
    );
    expect(
      tracks.single.box.height / _frame.height,
      lessThan(HazardEngine.nearEnter),
    );
    expect(engine.assess(tracks, _frame).alert?.level, AlertLevel.danger);
  });

  test(
    'a stationary obstacle growing in view triggers stop before near threshold',
    () {
      final tracker = ObjectTracker();
      final engine = HazardEngine();
      final time = DateTime(2026);
      var scene = SceneAssessment.empty;
      for (var i = 0; i < 3; i++) {
        final tracks = tracker.update(
          [_chair(0.22 + i * 0.06)],
          _frame,
          time.add(Duration(milliseconds: i * 150)),
        );
        scene = engine.assess(tracks, _frame);
      }
      expect(scene.objects.single.distance, DistanceLevel.medium);
      expect(scene.objects.single.approaching, isTrue);
      expect(scene.alert?.level, AlertLevel.danger);
    },
  );

  test('stable or receding objects do not gain a predicted stop warning', () {
    for (final heights in [
      [0.34, 0.34, 0.34],
      [0.36, 0.33, 0.30],
    ]) {
      final tracker = ObjectTracker();
      final engine = HazardEngine();
      var scene = SceneAssessment.empty;
      for (var i = 0; i < heights.length; i++) {
        scene = engine.assess(
          tracker.update(
            [_chair(heights[i])],
            _frame,
            DateTime(2026).add(Duration(milliseconds: i * 150)),
          ),
          _frame,
        );
      }
      expect(scene.objects.single.closingQuickly, isFalse);
      expect(scene.alert?.level, AlertLevel.caution);
    }
  });

  test(
    'moving a fixed-size box down does not invent approach at lower gate',
    () {
      final tracker = ObjectTracker();
      var scene = SceneAssessment.empty;
      for (var i = 0; i < 3; i++) {
        final detection = Recognition(
          56,
          'ghế',
          0.9,
          Rect.fromLTWH(100, 490 + i * 10, 200, 100),
          labelEn: 'chair',
        );
        scene = HazardEngine().assess(
          tracker.update(
            [detection],
            _frame,
            DateTime(2026).add(Duration(milliseconds: i * 150)),
          ),
          _frame,
        );
      }
      expect(scene.objects.single.approaching, isFalse);
      expect(scene.objects.single.closingQuickly, isFalse);
      expect(scene.alert?.level, AlertLevel.caution);
    },
  );

  test(
    'low wide obstacle is not treated as distant just because it is short',
    () {
      final tracker = ObjectTracker();
      final detections = [
        Recognition(
          60,
          'bàn',
          0.9,
          const Rect.fromLTWH(40, 650, 320, 100),
          labelEn: 'dining table',
        ),
      ];
      tracker.update(detections, _frame, DateTime(2026));
      final tracks = tracker.update(detections, _frame, DateTime(2026));
      expect(
        HazardEngine().assess(tracks, _frame).alert?.level,
        AlertLevel.danger,
      );
    },
  );

  test('old or missing observations cannot produce fresh stop warnings', () {
    final tracker = ObjectTracker();
    final engine = HazardEngine();
    final time = DateTime(2026);
    tracker.update([_chair(0.48)], _frame, time);
    tracker.update(
      [_chair(0.48)],
      _frame,
      time.add(const Duration(milliseconds: 150)),
    );
    final missing = tracker.update(
      [],
      _frame,
      time.add(const Duration(milliseconds: 300)),
    );
    expect(missing, hasLength(1));
    expect(engine.assess(missing, _frame).alert, isNull);
    expect(
      CaptionBuilder.describeScene(engine.assess(missing, _frame)),
      contains('Chưa nhận diện'),
    );
    expect(
      tracker.update(
        [_chair(0.48)],
        _frame,
        time.add(const Duration(seconds: 2)),
      ),
      isEmpty,
    );
  });

  test(
    'road signals and high central objects are not assumed to block walking',
    () {
      for (final detection in [
        Recognition(
          9,
          'đèn giao thông',
          0.9,
          _box(0.6),
          labelEn: 'traffic light',
        ),
        Recognition(
          56,
          'ghế',
          0.9,
          const Rect.fromLTWH(160, 30, 80, 300),
          labelEn: 'chair',
        ),
      ]) {
        final tracker = ObjectTracker();
        for (var i = 0; i < 3; i++) {
          tracker.update([detection], _frame, DateTime(2026));
        }
        final tracks = tracker.update([detection], _frame, DateTime(2026));
        expect(HazardEngine().assess(tracks, _frame).alert, isNull);
        expect(HazardEngine().assess(tracks, _frame).columnLoad, [
          0.0,
          0.0,
          0.0,
        ]);
      }
    },
  );

  test(
    'warning provides object and side without asserting empty escape routes',
    () {
      final tracker = ObjectTracker();
      final detection = Recognition(
        2,
        'xe ô tô',
        0.9,
        const Rect.fromLTWH(300, 200, 90, 550),
        labelEn: 'car',
      );
      for (var i = 0; i < 3; i++) {
        tracker.update([detection], _frame, DateTime(2026));
      }
      final scene = HazardEngine().assess(
        tracker.update([detection], _frame, DateTime(2026)),
        _frame,
      );
      expect(scene.alert?.message, 'Chú ý, xe ô tô bên phải. Đi chậm lại.');
      expect(scene.alert?.message, isNot(contains('trống')));
      expect(scene.alert?.message, isNot(contains('mét')));
    },
  );
}
