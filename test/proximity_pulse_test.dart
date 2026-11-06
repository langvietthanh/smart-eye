import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/models/scene_info.dart';
import 'package:smart_eye/models/tracked_object.dart';
import 'package:smart_eye/services/proximity_pulse.dart';

ObjectInfo object(Rect box, ObjectCategory category, {int misses = 0}) {
  final track = TrackedObject(
    id: 1,
    classId: 56,
    labelEn: 'chair',
    labelVi: 'ghế',
    box: box,
    score: 0.9,
  )..misses = misses;
  return ObjectInfo(
    track: track,
    pos: HPos.center,
    distance: DistanceLevel.medium,
    category: category,
    approaching: false,
  );
}

SceneAssessment scene(List<ObjectInfo> objects) =>
    SceneAssessment(objects: objects, columnLoad: const [0, 0, 0]);

void main() {
  const frame = Size(300, 600);

  test('interval: silent when far, faster when nearer', () {
    expect(ProximityPulse.intervalFor(null), isNull);
    expect(ProximityPulse.intervalFor(0.1), isNull);
    expect(ProximityPulse.intervalFor(0.2), ProximityPulse.slowest);
    final mid = ProximityPulse.intervalFor(0.33)!;
    expect(mid < ProximityPulse.slowest && mid > ProximityPulse.fastest, isTrue);
    expect(ProximityPulse.intervalFor(0.45), ProximityPulse.fastest);
    expect(ProximityPulse.intervalFor(0.9), ProximityPulse.fastest);
  });

  test('path occupancy ignores off-path, irrelevant and unobserved objects', () {
    // Centre column, bottom half, 40% of frame height.
    final inPath = object(
      const Rect.fromLTWH(110, 340, 80, 240),
      ObjectCategory.obstacle,
    );
    final offPath = object(
      const Rect.fromLTWH(0, 0, 60, 580),
      ObjectCategory.obstacle,
    );
    final cup = object(
      const Rect.fromLTWH(100, 100, 100, 500),
      ObjectCategory.other,
    );
    final lost = object(
      const Rect.fromLTWH(100, 100, 100, 500),
      ObjectCategory.obstacle,
      misses: 1,
    );
    expect(
      ProximityPulse.pathOccupancy(scene([offPath, cup, lost]), frame),
      isNull,
    );
    expect(
      ProximityPulse.pathOccupancy(scene([inPath, offPath, cup, lost]), frame),
      closeTo(0.4, 1e-9),
    );
  });

  testWidgets('pulses immediately, repeats, and stops', (tester) async {
    final pulses = <bool>[];
    final pulse = ProximityPulse(onPulse: pulses.add);
    pulse.update(0.5);
    expect(pulses, [true]);
    await tester.pump(ProximityPulse.fastest);
    expect(pulses, [true, true]);
    pulse.update(0.1);
    await tester.pump(const Duration(seconds: 2));
    expect(pulses.length, 2);
    pulse.update(0.2);
    expect(pulses, [true, true, false]);
    pulse.stop();
    await tester.pump(const Duration(seconds: 2));
    expect(pulses.length, 3);
  });
}
