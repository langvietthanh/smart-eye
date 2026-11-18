import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/models/scene_info.dart';
import 'package:smart_eye/services/depth_alert.dart';
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
      feed(5, obstacle(rightGap: 0.7));
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
      expect(feed(3, obstacle(rightGap: 0.7), from: 100), isNull);
      expect(walk.onScan(at(400), obstacle(rightGap: 0.7)), WalkCue.stepRight);
      expect(walk.phase, WalkPhase.sidestep);
      expect(walk.stepSide, HPos.right);
    });

    test('both sides prefer right', () {
      collect();
      expect(feed(5, obstacle(leftGap: 0.7, rightGap: 0.7)), WalkCue.stepRight);
    });

    test('a left gap steps left', () {
      collect();
      expect(feed(5, obstacle(leftGap: 0.7)), WalkCue.stepLeft);
      expect(walk.stepSide, HPos.left);
    });

    test('no gap finds a way', () {
      collect();
      expect(feed(5, obstacle()), WalkCue.findWay);
      expect(walk.phase, WalkPhase.findWay);
    });

    test('unknown centre frames do not count', () {
      collect();
      feed(4, obstacle(rightGap: 0.7));
      expect(feed(3, LidarScan.unknown, from: 400), isNull);
      expect(walk.phase, WalkPhase.collect);
      expect(walk.onScan(at(800), obstacle(rightGap: 0.7)), WalkCue.stepRight);
    });

    test('the obstacle leaving while collecting goes straight', () {
      collect();
      feed(2, obstacle(rightGap: 0.7));
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
      feed(5, obstacle(rightGap: 0.7));
      const clear = LidarScan(LidarClear(), LidarClear(), LidarClear());
      expect(walk.onScan(at(600), clear), isNull);
      expect(walk.onScan(at(700), clear), WalkCue.goStraight);
      expect(walk.phase, WalkPhase.passing);
    });

    test('an obstacle still close ahead keeps the sidestep going', () {
      collect();
      feed(5, obstacle(rightGap: 0.7));
      expect(feed(3, obstacle(rightGap: 0.7), from: 600), isNull);
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

    group('with an ARKit pose', () {
      // World heading +x; the user's right is world +z (left = up × forward).
      LidarPose pose(double x, double z) =>
          LidarPose(x: x, z: z, headX: 1, headZ: 0);
      // Bag in the room: x 1.0–1.4 ahead, z -0.25–0.25 across.
      const frontCells = [1.0, -0.2, 1.0, -0.1, 1.0, 0.0, 1.0, 0.1, 1.0, 0.2];
      LidarScan scan(
        LidarReading centre,
        LidarPose p, [
        List<double> c = const [],
      ]) => LidarScan(
        const LidarClear(),
        centre,
        const LidarClear(),
        cells: c,
        pose: p,
      );

      void stepRightWithPose() {
        collect();
        for (var i = 0; i < 5; i++) {
          walk.onScan(
            at(i * 100),
            scan(
              const LidarObstacle(1.0, rightGap: 0.7),
              pose(0, 0),
              frontCells,
            ),
          );
        }
        expect(walk.phase, WalkPhase.sidestep);
        walk.onScan(at(600), scan(const LidarClear(), pose(0, 0.55)));
        walk.onScan(at(700), scan(const LidarClear(), pose(0, 0.55)));
        expect(walk.phase, WalkPhase.passing);
      }

      test('steps back only once past the far edge seen on the side face', () {
        stepRightWithPose();
        // From z 0.55 the bag's side face (z 0.25) is 0.3 m to the left.
        const side = [0.4, 0.3, 0.5, 0.3, 0.6, 0.3, 0.7, 0.3, 0.8, 0.3];
        expect(
          walk.onScan(
            at(1000),
            scan(const LidarClear(), pose(0.6, 0.55), side),
          ),
          isNull,
        );
        expect(
          walk.onScan(at(1500), scan(const LidarClear(), pose(1.0, 0.55))),
          isNull,
        );
        // The old rule (side gone for a second) would step back here, beside the bag.
        expect(
          walk.onScan(at(2000), scan(const LidarClear(), pose(1.5, 0.55))),
          isNull,
        );
        expect(
          walk.onScan(at(2500), scan(const LidarClear(), pose(1.69, 0.55))),
          isNull,
        );
        expect(
          walk.onScan(at(3000), scan(const LidarClear(), pose(1.75, 0.55))),
          WalkCue.stepLeft,
        );
        // "Đi thẳng." only once ARKit puts the user back on the old line.
        expect(
          walk.onScan(at(3500), scan(const LidarClear(), pose(1.9, 0.3))),
          isNull,
        );
        expect(
          walk.onScan(at(4000), scan(const LidarClear(), pose(2.0, 0.05))),
          WalkCue.stepDone,
        );
        expect(walk.phase, WalkPhase.straight);
      });

      test('the sidestep ends once the body clears the edge (pose)', () {
        collect();
        for (var i = 0; i < 5; i++) {
          walk.onScan(
            at(i * 100),
            scan(
              const LidarObstacle(1.0, rightGap: 0.7),
              pose(0, 0),
              frontCells,
            ),
          );
        }
        // Bag edge 0.2 m right of the line, 70 cm gap: stand in its middle,
        // 0.35 m past the edge.
        expect(
          walk.onScan(at(600), scan(const LidarObstacle(1.0), pose(0, 0.5))),
          isNull,
        );
        expect(
          walk.onScan(at(700), scan(const LidarObstacle(1.0), pose(0, 0.56))),
          WalkCue.stepDone,
        );
        expect(walk.phase, WalkPhase.passing);
      });

      test('a gap reaching across the walking line counts whole', () {
        collect();
        // Chair 0.2–0.5 m left of the line: 45 cm read on the right side
        // plus the 20 cm between the line and the chair.
        const chair = [1.0, 0.2, 1.0, 0.3, 1.0, 0.4];
        WalkCue? cue;
        for (var i = 0; i < 5; i++) {
          cue = walk.onScan(
            at(i * 100),
            scan(const LidarObstacle(1.0, rightGap: 0.45), pose(0, 0), chair),
          );
        }
        expect(cue, WalkCue.stepRight);
      });

      test('without the side face it assumes the obstacle is 0.6 m deep', () {
        stepRightWithPose();
        expect(
          walk.onScan(at(1000), scan(const LidarClear(), pose(1.75, 0.55))),
          isNull,
        );
        expect(
          walk.onScan(at(1500), scan(const LidarClear(), pose(1.95, 0.55))),
          WalkCue.stepLeft,
        );
      });

      test('cells away from the obstacle do not move its far edge', () {
        stepRightWithPose();
        // A desk row 0.5 m further right (world z 1.05), reaching x 3.0.
        const desk = [1.0, -0.5, 2.0, -0.5, 2.4, -0.5];
        const side = [0.4, 0.3, 0.8, 0.3];
        walk.onScan(
          at(1000),
          scan(const LidarClear(), pose(0.6, 0.55), [...side, ...desk]),
        );
        expect(
          walk.onScan(at(1500), scan(const LidarClear(), pose(1.75, 0.55))),
          WalkCue.stepLeft,
        );
      });

      test('a frame without a pose decides nothing', () {
        stepRightWithPose();
        expect(
          walk.onScan(
            at(1000),
            const LidarScan(LidarClear(), LidarClear(), LidarClear()),
          ),
          isNull,
        );
        expect(
          walk.onScan(
            at(2500),
            const LidarScan(LidarClear(), LidarClear(), LidarClear()),
          ),
          isNull,
        );
        expect(walk.phase, WalkPhase.passing);
      });
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
      feed(5, obstacle(rightGap: 0.7));
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
      feed(5, obstacle(rightGap: 0.7));
      expect(
        walk.tick(at(5600), aheadOpen: false, turning: false, turnedDegrees: 0),
        WalkCue.findWay,
      );
    });
  });

  group('gap seen on the way up', () {
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));
    LidarScan ahead(double d, {double left = 0, double right = 0}) => LidarScan(
      const LidarClear(),
      LidarObstacle(d, leftGap: left, rightGap: right),
      const LidarClear(),
    );
    WalkCue? collectAt(int from, LidarScan scan) {
      walk.onDanger(wall: false, sideOpen: false, canBypass: true);
      WalkCue? last;
      for (var i = 0; i < 5; i++) {
        last = walk.onScan(at(from + i * 100), scan);
      }
      return last;
    }

    test('steps into the gap seen at 1.5 m though it reads 0 up close', () {
      walk.onScan(at(0), ahead(1.5, right: 0.7));
      walk.onScan(at(500), ahead(1.0, right: 0.3));
      expect(collectAt(1000, ahead(0.9)), WalkCue.stepRight);
    });

    test('a gap of 45–65 cm is squeezed through', () {
      walk.onScan(at(0), ahead(1.5, right: 0.53));
      expect(collectAt(500, ahead(0.9)), WalkCue.stepRight);
      expect(walk.squeezing, isTrue);
    });

    test('a gap narrower than shoulders: find a way', () {
      walk.onScan(at(0), ahead(1.5, right: 0.4));
      expect(collectAt(500, ahead(0.9)), WalkCue.findWay);
      expect(walk.squeezing, isFalse);
    });

    test('the wider gap is taken, without squeezing', () {
      walk.onScan(at(0), ahead(1.5, left: 0.7, right: 0.5));
      expect(collectAt(500, ahead(0.9)), WalkCue.stepLeft);
      expect(walk.squeezing, isFalse);
    });

    test('while squeezing only the gap sides are let by', () {
      LidarObstacle at(double from, double to) => LidarObstacle(
        0.8,
        where: (
          sideMin: from,
          sideMax: to,
          heightMin: 0.2,
          heightMax: 0.8,
          phoneHeight: 1.3,
        ),
      );
      expect(WalkState.edgeOnly(at(0.2, 0.4)), isTrue); // chair on the left
      expect(WalkState.edgeOnly(at(-0.5, -0.2)), isTrue); // desk on the right
      expect(WalkState.edgeOnly(at(-0.1, 0.3)), isFalse); // in the way
      expect(WalkState.edgeOnly(const LidarObstacle(0.8)), isFalse);
      expect(
        stepText(HPos.right, squeeze: true),
        'Khe hẹp. Bước ngang sang phải, nghiêng người lách qua.',
      );
      expect(stepText(HPos.left), 'Bước ngang sang trái.');
    });

    test('a gap seen more than 3 s ago is not used', () {
      walk.onScan(at(0), ahead(1.5, right: 0.7));
      expect(collectAt(3500, ahead(0.9)), WalkCue.findWay);
    });

    test('a cleared way or another obstacle forgets the gap', () {
      walk.onScan(at(0), ahead(1.5, right: 0.7));
      walk.onScan(
        at(100),
        const LidarScan(LidarClear(), LidarClear(), LidarClear()),
      );
      expect(collectAt(200, ahead(0.9)), WalkCue.findWay);
      walk.reset();
      walk.onScan(at(1000), ahead(1.5, left: 0.7));
      walk.onScan(at(1100), ahead(2.4)); // turned to something further
      expect(collectAt(1200, ahead(0.9)), WalkCue.findWay);
    });
  });

  group('finding a way stays ahead first', () {
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));
    LidarScan facing(double deg) {
      final r = deg * pi / 180;
      // ARKit heading: the camera looks along -z; turning right is +x.
      return LidarScan(
        const LidarClear(),
        const LidarUnknown(),
        const LidarClear(),
        pose: LidarPose(x: 0, z: 0, headX: sin(r), headZ: -cos(r)),
      );
    }

    WalkCue? tickOpen(int ms) =>
        walk.tick(at(ms), aheadOpen: true, turning: true, turnedDegrees: 0);

    setUp(() {
      walk.onScan(at(0), facing(0));
      walk.onDanger(wall: true, sideOpen: false, canBypass: false);
    });

    test('an open way within 100° is taken', () {
      walk.onScan(at(100), facing(80));
      tickOpen(100);
      expect(tickOpen(400), WalkCue.goStraight);
    });

    test('past 100° one way: try the other side before turning back', () {
      walk.onScan(at(100), facing(120));
      expect(tickOpen(100), WalkCue.turnBack);
      expect(tickOpen(500), isNull); // open behind, not taken yet
      walk.onScan(at(600), facing(-60));
      tickOpen(600);
      expect(tickOpen(900), WalkCue.goStraight);
    });

    test('nothing open within 100° either side: blocked, never sent back', () {
      walk.onScan(at(100), facing(120));
      expect(tickOpen(100), WalkCue.turnBack);
      // Open behind (170° round): not taken, not called "Đi thẳng.".
      walk.onScan(at(400), facing(170));
      expect(tickOpen(400), isNull);
      expect(tickOpen(800), isNull);
      walk.onScan(at(1000), facing(-110));
      expect(tickOpen(1000), WalkCue.blocked);
      expect(walk.phase, WalkPhase.straight);
    });

    test('without a pose the old rule holds', () {
      final w = WalkState();
      w.onDanger(wall: true, sideOpen: false, canBypass: false);
      w.tick(at(0), aheadOpen: true, turning: true, turnedDegrees: 0);
      expect(
        w.tick(at(300), aheadOpen: true, turning: true, turnedDegrees: 0),
        WalkCue.goStraight,
      );
    });
  });

  group('a way on is a body wide', () {
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));
    LidarScan facing(double deg, double width) {
      final r = deg * pi / 180;
      return LidarScan(
        const LidarClear(),
        const LidarClear(),
        const LidarClear(),
        pose: LidarPose(x: 0, z: 0, headX: sin(r), headZ: -cos(r)),
        aheadWidth: width,
      );
    }

    WalkCue? tickOpen(int ms) =>
        walk.tick(at(ms), aheadOpen: true, turning: true, turnedDegrees: 0);

    test('55 cm between two rows of desks is not taken, 1 m is', () {
      walk.onScan(at(0), facing(0, 0.3));
      walk.onDanger(wall: true, sideOpen: false, canBypass: false);
      walk.onScan(at(100), facing(60, 0.55));
      tickOpen(100);
      expect(tickOpen(400), isNull);
      walk.onScan(at(500), facing(80, 1.0));
      tickOpen(500);
      expect(tickOpen(800), WalkCue.goStraight);
    });
  });

  group('wall turn hint', () {
    LidarScan sides(LidarReading l, LidarReading r) =>
        LidarScan(l, const LidarObstacle(0.9, wall: true), r);

    test('towards the clearly deeper side', () {
      expect(
        WalkState.turnHint(sides(const LidarClear(), const LidarObstacle(1))),
        HPos.left,
      );
      expect(
        WalkState.turnHint(
          sides(const LidarObstacle(1), const LidarObstacle(1.6)),
        ),
        HPos.right,
      );
    });

    test('none when alike or unreadable', () {
      expect(
        WalkState.turnHint(
          sides(const LidarObstacle(1), const LidarObstacle(1.2)),
        ),
        isNull,
      );
      expect(
        WalkState.turnHint(sides(const LidarUnknown(), const LidarClear())),
        isNull,
      );
    });

    test('spoken lines', () {
      expect(
        wallTurnText(HPos.right),
        'Dừng lại! Tường phía trước. Quay sang phải.',
      );
      expect(
        wallTurnText(null),
        'Dừng lại! Tường phía trước. Xoay trái hoặc phải để tìm lối.',
      );
    });
  });
}
