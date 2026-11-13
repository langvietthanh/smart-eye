import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/services/walk_state.dart';

void main() {
  late WalkState walk;
  final t0 = DateTime(2026, 11, 13, 14, 0, 0);

  setUp(() {
    walk = WalkState();
  });

  test('a wall danger enters findWay', () {
    expect(walk.onDanger(wall: true, sideOpen: true), isTrue);
    expect(walk.phase, WalkPhase.findWay);
  });

  test('a blocked obstacle enters findWay', () {
    expect(walk.onDanger(wall: false, sideOpen: false), isTrue);
    expect(walk.phase, WalkPhase.findWay);
  });

  test('an obstacle with a free side stays straight', () {
    expect(walk.onDanger(wall: false, sideOpen: true), isFalse);
    expect(walk.phase, WalkPhase.straight);
  });

  test('a second danger in findWay is swallowed', () {
    walk.onDanger(wall: true, sideOpen: true);
    expect(walk.phase, WalkPhase.findWay);
    expect(walk.onDanger(wall: true, sideOpen: false), isFalse);
    expect(walk.phase, WalkPhase.findWay);
  });

  test('turning 30° prompts turn-on', () {
    walk.onDanger(wall: true, sideOpen: false);
    final cue = walk.tick(
      t0,
      aheadOpen: false,
      turning: true,
      turnedDegrees: 31,
    );
    expect(cue, WalkCue.turnOn);
  });

  test('turning frees after 0.3 s', () {
    walk.onDanger(wall: true, sideOpen: false);
    expect(
      walk.tick(t0, aheadOpen: true, turning: true, turnedDegrees: 0),
      isNull,
    );
    expect(
      walk.tick(
        t0.add(const Duration(milliseconds: 200)),
        aheadOpen: true,
        turning: true,
        turnedDegrees: 0,
      ),
      isNull,
    );
    expect(
      walk.tick(
        t0.add(const Duration(milliseconds: 300)),
        aheadOpen: true,
        turning: true,
        turnedDegrees: 0,
      ),
      WalkCue.goStraight,
    );
    expect(walk.phase, WalkPhase.straight);
  });

  test('standing still needs a second', () {
    walk.onDanger(wall: true, sideOpen: false);
    walk.tick(t0, aheadOpen: true, turning: false, turnedDegrees: 0);
    expect(
      walk.tick(
        t0.add(const Duration(milliseconds: 300)),
        aheadOpen: true,
        turning: false,
        turnedDegrees: 0,
      ),
      isNull,
    );
    expect(
      walk.tick(
        t0.add(const Duration(milliseconds: 1000)),
        aheadOpen: true,
        turning: false,
        turnedDegrees: 0,
      ),
      WalkCue.goStraight,
    );
    expect(walk.phase, WalkPhase.straight);
  });

  test('a flicker restarts the wait', () {
    walk.onDanger(wall: true, sideOpen: false);
    walk.tick(t0, aheadOpen: true, turning: true, turnedDegrees: 0);
    walk.tick(
      t0.add(const Duration(milliseconds: 200)),
      aheadOpen: false,
      turning: true,
      turnedDegrees: 0,
    );
    walk.tick(
      t0.add(const Duration(milliseconds: 250)),
      aheadOpen: true,
      turning: true,
      turnedDegrees: 0,
    );
    expect(
      walk.tick(
        t0.add(const Duration(milliseconds: 500)),
        aheadOpen: true,
        turning: true,
        turnedDegrees: 0,
      ),
      isNull,
    );
    expect(
      walk.tick(
        t0.add(const Duration(milliseconds: 550)),
        aheadOpen: true,
        turning: true,
        turnedDegrees: 0,
      ),
      WalkCue.goStraight,
    );
    expect(walk.phase, WalkPhase.straight);
  });

  test('straight ignores ticks', () {
    expect(
      walk.tick(t0, aheadOpen: true, turning: true, turnedDegrees: 45),
      isNull,
    );
  });

  test('reset returns to straight', () {
    walk.onDanger(wall: true, sideOpen: false);
    expect(walk.phase, WalkPhase.findWay);
    walk.reset();
    expect(walk.phase, WalkPhase.straight);
  });
}

