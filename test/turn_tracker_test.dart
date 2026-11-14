import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/services/turn_tracker.dart';

void main() {
  late TurnTracker tracker;
  final t0 = DateTime(2026, 11, 13, 12, 0, 0);

  setUp(() {
    tracker = TurnTracker();
    tracker.onGravity(0, 9.8, 0);
  });

  void feedGyro({
    double x = 0,
    double y = 0,
    double z = 0,
    int durationMs = 1000,
    int stepMs = 20,
  }) {
    for (var ms = 0; ms <= durationMs; ms += stepMs) {
      tracker.onGyro(t0.add(Duration(milliseconds: ms)), x, y, z);
    }
  }

  test('turning about vertical counts', () {
    // 0.5236 rad/s ≈ 30 deg/s
    feedGyro(y: 0.5236, durationMs: 1000);
    expect(tracker.degrees, closeTo(30.0, 1.0));
    expect(tracker.turningAt(t0.add(const Duration(milliseconds: 1000))), isTrue);
  });

  test('tilting is not turning', () {
    // 0.5236 rad/s around x axis (pitch tilt)
    feedGyro(x: 0.5236, durationMs: 1000);
    expect(tracker.degrees, lessThan(3.0));
    expect(tracker.turningAt(t0.add(const Duration(milliseconds: 1000))), isFalse);
  });

  test('slow turn is not turning', () {
    // 0.1745 rad/s ≈ 10 deg/s
    feedGyro(y: 0.1745, durationMs: 1000);
    expect(tracker.turningAt(t0.add(const Duration(milliseconds: 1000))), isFalse);
  });

  test('standing still never completes a step', () {
    feedGyro(durationMs: 10000);
    expect(tracker.degrees, 0.0);
  });

  test('reset clears', () {
    feedGyro(y: 0.5236, durationMs: 1000);
    expect(tracker.degrees, greaterThan(0));
    tracker.reset();
    expect(tracker.degrees, 0.0);
  });
}

