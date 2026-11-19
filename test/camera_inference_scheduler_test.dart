import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/services/camera_inference_scheduler.dart';

void main() {
  late CameraInferenceScheduler schedule;

  setUp(() => schedule = CameraInferenceScheduler());

  CameraInference? take(
    int at, {
    bool busy = false,
    bool depth = true,
    bool sourcePaced = false,
  }) => schedule.take(
    at,
    busy: busy,
    depthAvailable: depth,
    detectionPacedBySource: sourcePaced,
  );

  test('detection gets the first frame and depth gets the next idle slot', () {
    expect(take(0), CameraInference.detection);
    expect(take(20, busy: true), isNull);
    expect(take(50), CameraInference.depth);
  });

  test('busy frames are dropped without consuming a pending model deadline', () {
    expect(take(0, busy: true), isNull);
    expect(take(100, busy: true), isNull);
    expect(take(110), CameraInference.detection);
    expect(take(200, busy: true), isNull);
    expect(take(210), CameraInference.depth);
  });

  test('minimum model intervals hold when both workers finish quickly', () {
    expect(take(0), CameraInference.detection);
    expect(take(1), CameraInference.depth);
    expect(take(149), isNull);
    expect(take(150), CameraInference.detection);
    expect(take(299), isNull);
    expect(take(300), CameraInference.detection);
    expect(take(301), CameraInference.depth);
  });

  test('slow inference selects the oldest overdue model without starvation', () {
    expect(take(0), CameraInference.detection);
    expect(take(400), CameraInference.depth);
    expect(take(800), CameraInference.detection);
    expect(take(1200), CameraInference.depth);
    expect(take(1600), CameraInference.detection);
  });

  test('unavailable depth never occupies or delays detection slots', () {
    expect(take(0, depth: false), CameraInference.detection);
    expect(take(149, depth: false), isNull);
    expect(take(150, depth: false), CameraInference.detection);
    expect(take(500, depth: false), CameraInference.detection);
    expect(take(501), CameraInference.depth);
  });

  test('native-paced detection is not throttled again by arrival time', () {
    expect(take(0, depth: false, sourcePaced: true), CameraInference.detection);
    expect(take(149, depth: false, sourcePaced: true), CameraInference.detection);
    expect(take(200, busy: true, depth: false, sourcePaced: true), isNull);
    expect(take(299, depth: false, sourcePaced: true), CameraInference.detection);
  });
}
