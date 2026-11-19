import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/models/scene_info.dart';
import 'package:smart_eye/models/tracked_object.dart';
import 'package:smart_eye/widgets/bounding_box_painter.dart';

void main() {
  testWidgets('moving detected objects paint without disposing labels twice', (
    tester,
  ) async {
    final track = TrackedObject(
      id: 1,
      classId: 0,
      labelEn: 'person',
      labelVi: 'người',
      box: const Rect.fromLTWH(10, 40, 20, 40),
      score: 0.9,
    );
    final scene = SceneAssessment(
      objects: [
        ObjectInfo(
          track: track,
          pos: HPos.center,
          distance: DistanceLevel.near,
          category: ObjectCategory.person,
          approaching: false,
        ),
      ],
      columnLoad: [0, 2, 0],
    );
    for (var frame = 0; frame < 3; frame++) {
      track.box = Rect.fromLTWH(10.0 + frame * 20, 40, 20, 40);
      await tester.pumpWidget(
        CustomPaint(
          painter: BoundingBoxPainter(
            scene,
            alertSubject: 'track:1',
            alertLevel: AlertLevel.danger,
          ),
          size: const Size(240, 320),
        ),
      );
      expect(tester.takeException(), isNull);
    }
  });

  test('mutable tracks still trigger repaint when their box moves', () {
    final track = TrackedObject(
      id: 1,
      classId: 0,
      labelEn: 'person',
      labelVi: 'người',
      box: const Rect.fromLTWH(10, 10, 20, 40),
      score: 0.9,
    );
    final scene = SceneAssessment(
      objects: [
        ObjectInfo(
          track: track,
          pos: HPos.left,
          distance: DistanceLevel.near,
          category: ObjectCategory.person,
          approaching: false,
        ),
      ],
      columnLoad: [0, 0, 0],
    );
    final before = BoundingBoxPainter(scene);
    track.score = 0.95;
    expect(BoundingBoxPainter(scene).shouldRepaint(before), isFalse);
    track.box = const Rect.fromLTWH(20, 10, 20, 40);
    expect(BoundingBoxPainter(scene).shouldRepaint(before), isTrue);
  });

  test('columns repaint only when their visible warning color changes', () {
    final before = BoundingBoxPainter(
      const SceneAssessment(objects: [], columnLoad: [0.2, 1.2, 2.1]),
    );
    final sameColors = BoundingBoxPainter(
      const SceneAssessment(objects: [], columnLoad: [0.8, 1.8, 3]),
    );
    final danger = BoundingBoxPainter(
      const SceneAssessment(objects: [], columnLoad: [0.8, 2, 3]),
    );
    expect(sameColors.shouldRepaint(before), isFalse);
    expect(danger.shouldRepaint(before), isTrue);
  });
}
