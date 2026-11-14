import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/models/scene_info.dart';
import 'package:smart_eye/services/lidar_analysis.dart';
import 'package:smart_eye/services/walk_state.dart';

void main() {
  late WalkState walk;
  final t0 = DateTime(2026, 11, 13, 14, 0, 0);

  setUp(() {
    walk = WalkState();
  });

  test('a wall danger enters findWay', () {
    expect(
      walk.onDanger(wall: true, sideOpen: true, canBypass: false),
      DangerAction.findWay,
    );
    expect(walk.phase, WalkPhase.findWay);
  });

  test('a blocked obstacle enters findWay', () {
    expect(
      walk.onDanger(wall: false, sideOpen: false, canBypass: false),
      DangerAction.findWay,
    );
    expect(walk.phase, WalkPhase.findWay);
  });

  test('an obstacle with a free side stays straight', () {
    expect(
      walk.onDanger(wall: false, sideOpen: true, canBypass: false),
      DangerAction.none,
    );
    expect(walk.phase, WalkPhase.straight);
  });

  test('a second danger in findWay is swallowed', () {
    walk.onDanger(wall: true, sideOpen: true, canBypass: false);
    expect(walk.phase, WalkPhase.findWay);
    expect(
      walk.onDanger(wall: true, sideOpen: false, canBypass: false),
      DangerAction.none,
    );
    expect(walk.phase, WalkPhase.findWay);
  });

  test('turning 30° prompts turn-on', () {
    walk.onDanger(wall: true, sideOpen: false, canBypass: false);
    final cue = walk.tick(
      t0,
      aheadOpen: false,
      turning: true,
      turnedDegrees: 31,
    );
    expect(cue, WalkCue.turnOn);
  });

  test('turning frees after 0.3 s', () {
    walk.onDanger(wall: true, sideOpen: false, canBypass: false);
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
    walk.onDanger(wall: true, sideOpen: false, canBypass: false);
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
    walk.onDanger(wall: true, sideOpen: false, canBypass: false);
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
    walk.onDanger(wall: true, sideOpen: false, canBypass: false);
    expect(walk.phase, WalkPhase.findWay);
    walk.reset();
    expect(walk.phase, WalkPhase.straight);
  });

  group('bypass', () {
    LidarScan obstacle({
      double leftGap = 0.1,
      double rightGap = 0.1,
      LidarReading left = const LidarClear(),
      LidarReading right = const LidarClear(),
    }) => LidarScan(
      left,
      LidarObstacle(1.0, leftGap: leftGap, rightGap: rightGap),
      right,
    );
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));
    void collect() =>
        walk.onDanger(wall: false, sideOpen: false, canBypass: true);
    WalkCue? feed(int n, LidarScan scan, {int from = 0}) {
      WalkCue? last;
      for (var i = 0; i < n; i++) {
        last = walk.onScan(at(from + i * 100), scan);
      }
      return last;
    }

    void stepRightThenPass() {
      collect();
      feed(5, obstacle(rightGap: 0.3));
      walk.onScan(
        at(600),
        const LidarScan(LidarClear(), LidarClear(), LidarClear()),
      );
      walk.onScan(
        at(700),
        const LidarScan(LidarClear(), LidarClear(), LidarClear()),
      );
      expect(walk.phase, WalkPhase.passing);
    }

    test('a plain obstacle with LiDAR stops and collects', () {
      expect(
        walk.onDanger(wall: false, sideOpen: false, canBypass: true),
        DangerAction.stop,
      );
      expect(walk.phase, WalkPhase.collect);
    });

    test('a wall still finds a way', () {
      expect(
        walk.onDanger(wall: true, sideOpen: true, canBypass: true),
        DangerAction.findWay,
      );
    });

    test('four of five frames with a right gap step right', () {
      collect();
      expect(feed(1, obstacle(rightGap: 0.1)), isNull);
      expect(feed(3, obstacle(rightGap: 0.3), from: 100), isNull);
      expect(walk.onScan(at(400), obstacle(rightGap: 0.3)), WalkCue.stepRight);
      expect(walk.phase, WalkPhase.sidestep);
      expect(walk.stepSide, HPos.right);
    });

    test('both sides prefer right', () {
      collect();
      expect(feed(5, obstacle(leftGap: 0.3, rightGap: 0.3)), WalkCue.stepRight);
    });

    test('a left gap steps left', () {
      collect();
      expect(feed(5, obstacle(leftGap: 0.3)), WalkCue.stepLeft);
      expect(walk.stepSide, HPos.left);
    });

    test('no gap finds a way', () {
      collect();
      expect(feed(5, obstacle()), WalkCue.findWay);
      expect(walk.phase, WalkPhase.findWay);
    });

    test('unknown centre frames do not count', () {
      collect();
      feed(4, obstacle(rightGap: 0.3));
      expect(feed(3, LidarScan.unknown, from: 400), isNull);
      expect(walk.phase, WalkPhase.collect);
      expect(walk.onScan(at(800), obstacle(rightGap: 0.3)), WalkCue.stepRight);
    });

    test('the obstacle leaving while collecting goes straight', () {
      collect();
      feed(2, obstacle(rightGap: 0.3));
      expect(
        walk.onScan(
          at(300),
          const LidarScan(LidarClear(), LidarClear(), LidarClear()),
        ),
        WalkCue.goStraight,
      );
      expect(walk.phase, WalkPhase.straight);
    });

    test('centre clear two frames ends the sidestep', () {
      collect();
      feed(5, obstacle(rightGap: 0.3));
      const clear = LidarScan(LidarClear(), LidarClear(), LidarClear());
      expect(walk.onScan(at(600), clear), isNull);
      expect(walk.onScan(at(700), clear), WalkCue.goStraight);
      expect(walk.phase, WalkPhase.passing);
    });

    test('an obstacle still close ahead keeps the sidestep going', () {
      collect();
      feed(5, obstacle(rightGap: 0.3));
      expect(feed(3, obstacle(rightGap: 0.3), from: 600), isNull);
      expect(walk.phase, WalkPhase.sidestep);
    });

    test('old side gone for a second steps back', () {
      stepRightThenPass();
      const seen = LidarScan(LidarObstacle(0.8), LidarClear(), LidarClear());
      const gone = LidarScan(LidarClear(), LidarClear(), LidarClear());
      expect(walk.onScan(at(1000), seen), isNull);
      expect(walk.onScan(at(1100), gone), isNull);
      expect(walk.onScan(at(1600), gone), isNull);
      expect(walk.onScan(at(2100), gone), WalkCue.stepLeft);
      expect(walk.phase, WalkPhase.straight);
      expect(walk.stepSide, isNull);
    });

    test('old side seen again says go straight and restarts the second', () {
      stepRightThenPass();
      const seen = LidarScan(LidarObstacle(0.8), LidarClear(), LidarClear());
      const gone = LidarScan(LidarClear(), LidarClear(), LidarClear());
      walk.onScan(at(1000), gone);
      expect(walk.onScan(at(1500), seen), WalkCue.goStraight);
      expect(walk.onScan(at(1600), gone), isNull);
      expect(walk.onScan(at(2500), gone), isNull);
      expect(walk.onScan(at(2600), gone), WalkCue.stepLeft);
    });

    test('a new danger while passing collects again', () {
      stepRightThenPass();
      expect(
        walk.onDanger(wall: false, sideOpen: false, canBypass: true),
        DangerAction.stop,
      );
      expect(walk.phase, WalkPhase.collect);
    });

    test('danger while collecting or stepping is silent', () {
      collect();
      expect(
        walk.onDanger(wall: false, sideOpen: false, canBypass: true),
        DangerAction.none,
      );
      feed(5, obstacle(rightGap: 0.3));
      expect(
        walk.onDanger(wall: false, sideOpen: false, canBypass: true),
        DangerAction.none,
      );
    });

    test('collect timeout finds a way', () {
      collect();
      walk.tick(at(0), aheadOpen: false, turning: false, turnedDegrees: 0);
      expect(
        walk.tick(at(2100), aheadOpen: false, turning: false, turnedDegrees: 0),
        WalkCue.findWay,
      );
      expect(walk.phase, WalkPhase.findWay);
    });

    test('sidestep timeout finds a way', () {
      collect();
      feed(5, obstacle(rightGap: 0.3));
      expect(
        walk.tick(at(5600), aheadOpen: false, turning: false, turnedDegrees: 0),
        WalkCue.findWay,
      );
    });
  });
}
