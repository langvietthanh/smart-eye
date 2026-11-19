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
    expect(walk.markFindWayPromptStarted(walk.revision), isTrue);
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
    expect(walk.markFindWayPromptStarted(walk.revision), isTrue);
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
    expect(walk.markFindWayPromptStarted(walk.revision), isTrue);
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
    expect(walk.markFindWayPromptStarted(walk.revision), isTrue);
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

  test('queued find-way prompt blocks turn cues until TTS starts it', () {
    walk.onDanger(wall: true, sideOpen: false, canBypass: false);
    final revision = walk.revision;

    // Rotation may already have accumulated while another warning is speaking.
    expect(
      walk.tick(t0, aheadOpen: false, turning: true, turnedDegrees: 45),
      isNull,
    );
    expect(walk.markFindWayPromptStarted(revision), isTrue);
    expect(
      walk.tick(t0, aheadOpen: false, turning: true, turnedDegrees: 45),
      WalkCue.turnOn,
    );
  });

  test(
    'each new obstacle after go-straight starts a fresh find-way episode',
    () {
      expect(
        walk.onDanger(wall: true, sideOpen: false, canBypass: false),
        DangerAction.findWay,
      );
      final firstRevision = walk.revision;
      expect(walk.markFindWayPromptStarted(firstRevision), isTrue);
      expect(
        walk.tick(t0, aheadOpen: true, turning: true, turnedDegrees: 0),
        isNull,
      );
      expect(
        walk.tick(
          t0.add(WalkState.turningSettle),
          aheadOpen: true,
          turning: true,
          turnedDegrees: 0,
        ),
        WalkCue.goStraight,
      );
      expect(walk.phase, WalkPhase.straight);
      expect(walk.markFindWayPromptStarted(firstRevision), isFalse);

      expect(
        walk.onDanger(wall: false, sideOpen: false, canBypass: false),
        DangerAction.findWay,
      );
      expect(walk.phase, WalkPhase.findWay);
      expect(walk.revision, greaterThan(firstRevision));
      expect(walk.markFindWayPromptStarted(firstRevision), isFalse);
      expect(
        walk.tick(
          t0.add(const Duration(seconds: 2)),
          aheadOpen: false,
          turning: true,
          turnedDegrees: 45,
        ),
        isNull,
      );
      expect(walk.markFindWayPromptStarted(walk.revision), isTrue);
      expect(
        walk.tick(
          t0.add(const Duration(seconds: 2)),
          aheadOpen: false,
          turning: true,
          turnedDegrees: 45,
        ),
        WalkCue.turnOn,
      );
    },
  );

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

  group('detector alerts enter obstacle flow', () {
    test('YOLO danger transitions to find-way without LiDAR', () {
      const alert = HazardAlert(
        level: AlertLevel.danger,
        message: 'Dừng lại! Có ghế ngay phía trước.',
        guidance: Guidance.stop,
        subject: 'track:1',
        pos: HPos.center,
        inPath: true,
      );
      expect(walk.onAlert(alert, canBypass: false), DangerAction.findWay);
      expect(walk.phase, WalkPhase.findWay);
    });

    test('YOLO danger starts LiDAR bypass even when box load is narrow', () {
      const alert = HazardAlert(
        level: AlertLevel.danger,
        message: 'Dừng lại! Có ghế ngay phía trước.',
        guidance: Guidance.stop,
        subject: 'track:1',
        pos: HPos.center,
      );
      expect(walk.onAlert(alert, canBypass: true), DangerAction.stop);
      expect(walk.phase, WalkPhase.collect);
    });

    test('side danger outside the walking corridor does not stop the user', () {
      const alert = HazardAlert(
        level: AlertLevel.danger,
        message: 'Dừng lại! Có ghế bên trái.',
        guidance: Guidance.stop,
        subject: 'track:1',
        pos: HPos.left,
      );
      expect(walk.onAlert(alert, canBypass: false), DangerAction.none);
      expect(walk.phase, WalkPhase.straight);
    });

    test('side-centred box whose edge overlaps path still triggers find-way', () {
      const alert = HazardAlert(
        level: AlertLevel.danger,
        message: 'Dừng lại! Có ghế ngay phía trước.',
        guidance: Guidance.stop,
        subject: 'track:1',
        pos: HPos.left,
        inPath: true,
      );
      expect(walk.onAlert(alert, canBypass: false), DangerAction.findWay);
      expect(walk.phase, WalkPhase.findWay);
    });
  });

  group('verified bypass', () {
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));
    LidarPose pose(double x, double z) => LidarPose(x: x, z: z, headX: 1, headZ: 0);

    // Synthetic observed floor in room coordinates. Include the area already
    // seen on approach beneath/behind the user, then transform into this scan.
    List<double> floor(LidarPose p, {bool returnBlocked = false}) {
      final cells = <double>[];
      for (var a = -5; a <= 30; a++) {
        for (var s = -14; s <= 14; s++) {
          final x = a / 10 + 0.05, across = s / 10 + 0.05;
          if (x >= 0.85 && x <= 1.45 && across.abs() <= 0.35) continue;
          if (returnBlocked && x > 1.4 && across.abs() < 0.4) continue;
          cells.addAll([x - p.x, across + p.z]);
        }
      }
      return cells;
    }

    LidarScan scan({
      double x = 0,
      double z = 0,
      LidarReading center = const LidarObstacle(
        0.9, right: SideState.clear, rightGap: 0.75, rightGapCenter: -0.75,
      ),
      bool observedFloor = true,
      bool returnBlocked = false,
      List<double> occupied = const [],
      bool tracking = true,
      bool cameraViewOnly = false,
    }) {
      final p = pose(x, z);
      final visibleFloor = <double>[];
      if (observedFloor) {
        final observed = floor(p, returnBlocked: returnBlocked);
        for (var i = 0; i + 1 < observed.length; i += 2) {
          if (cameraViewOnly && observed[i] < LidarAnalysis.minForward) continue;
          visibleFloor.addAll([observed[i], observed[i + 1]]);
        }
      }
      return LidarScan(
        const LidarUnknown(), center, const LidarUnknown(),
        pose: tracking ? p : null,
        freeCells: visibleFloor,
        cells: occupied,
      );
    }

    void collect() => walk.onDanger(wall: false, sideOpen: false, canBypass: true);
    WalkCue? feed(LidarScan s, {int from = 0, int count = 5}) {
      WalkCue? cue;
      for (var i = 0; i < count; i++) {
        cue = walk.onScan(at(from + i * 100), s);
      }
      return cue;
    }
    void passing({bool left = false}) {
      collect();
      expect(feed(scan(center: left
          ? const LidarObstacle(0.9, left: SideState.clear, leftGap: 0.75, leftGapCenter: 0.75)
          : const LidarObstacle(0.9, right: SideState.clear, rightGap: 0.75, rightGapCenter: -0.75))),
          left ? WalkCue.stepLeft : WalkCue.stepRight);
      final z = left ? -0.75 : 0.75;
      expect(walk.onScan(at(500), scan(z: z, center: const LidarClear())), isNull);
      expect(walk.onScan(at(600), scan(z: z, center: const LidarClear())), WalkCue.goStraight);
      expect(walk.phase, WalkPhase.passing);
    }

    test('a 25cm gap never authorizes a step', () {
      collect();
      expect(feed(scan(center: const LidarObstacle(0.9,
          right: SideState.clear, rightGap: 0.25, rightGapCenter: -0.5))), WalkCue.findWay);
    });

    test('gap without verified side state is not enough', () {
      collect();
      expect(feed(scan(center: const LidarObstacle(0.9,
          rightGap: 0.8, rightGapCenter: -0.75))), WalkCue.findWay);
    });

    test('wide gap without observed lateral floor cannot authorize motion', () {
      collect();
      expect(feed(scan(observedFloor: false)), WalkCue.findWay);
    });

    test('four of five measured body-width gaps authorize right', () {
      collect();
      expect(walk.onScan(at(0), scan(center: const LidarObstacle(0.9))), isNull);
      expect(feed(scan(), from: 100, count: 4), WalkCue.stepRight);
      expect(walk.phase, WalkPhase.sidestep);
      expect(walk.stepSide, HPos.right);
    });

    test('scans before the stop starts cannot vote for a side', () {
      collect();
      for (var i = 0; i < 5; i++) {
        expect(walk.onScan(at(i * 100), scan(), stopped: false), isNull);
      }
      expect(walk.phase, WalkPhase.collect);
      expect(feed(scan(), from: 500), WalkCue.stepRight);
    });

    test('latest gap must still be open after four earlier votes', () {
      collect();
      feed(scan(), count: 4);
      expect(walk.onScan(at(400), scan(center: const LidarObstacle(0.9,
          right: SideState.blocked))), WalkCue.findWay);
    });

    test('recent approach observations cover the near-camera blind area', () {
      walk.onScan(at(0), scan(x: -0.6, cameraViewOnly: true,
          center: const LidarObstacle(1.5, right: SideState.clear,
              rightGap: 0.75, rightGapCenter: -0.75)));
      collect();
      expect(feed(scan(cameraViewOnly: true,
          center: const LidarObstacle(0.9)), from: 100), WalkCue.stepRight);
    });

    test('expired floor behind the camera stops a slow sidestep', () {
      walk.onScan(at(0), scan(x: -0.6, cameraViewOnly: true,
          center: const LidarObstacle(1.5, right: SideState.clear,
              rightGap: 0.75, rightGapCenter: -0.75)));
      collect();
      feed(scan(cameraViewOnly: true, center: const LidarObstacle(0.9)), from: 100);
      feed(scan(z: 0.4, cameraViewOnly: true,
          center: const LidarClear()), from: 600, count: 25);
      expect(walk.onScan(at(3100), scan(z: 0.4, cameraViewOnly: true,
          center: const LidarClear())), WalkCue.findWay);
    });

    test('thin obstacle in lateral sweep vetoes an otherwise wide gap', () {
      collect();
      expect(feed(scan(occupied: [0.05, -0.45])), WalkCue.findWay);
    });

    test('no valid pose stops, instead of inferring room from disappearance', () {
      collect();
      expect(walk.onScan(at(0), scan(tracking: false)), WalkCue.findWay);
    });

    test('duplicate timestamps do not count towards five scans', () {
      collect();
      for (var i = 0; i < 10; i++) {
        expect(walk.onScan(at(0), scan()), isNull);
      }
      expect(walk.phase, WalkPhase.collect);
      expect(feed(scan(), from: 100, count: 4), WalkCue.stepRight);
    });

    test('clear center alone cannot finish a sidestep without displacement', () {
      collect();
      feed(scan());
      feed(scan(center: const LidarClear()), from: 500, count: 2);
      expect(walk.phase, WalkPhase.sidestep);
    });

    test('complete right bypass confirms return before final forward cue', () {
      passing();
      // Increment position with frequent scans, as a walking user would.
      expect(walk.onScan(at(700), scan(x: 0.6, z: 0.75, center: const LidarClear())), isNull);
      expect(walk.onScan(at(800), scan(x: 1.2, z: 0.75, center: const LidarClear())), isNull);
      expect(walk.onScan(at(900), scan(x: 1.8, z: 0.75, center: const LidarClear())), WalkCue.stepLeft);
      expect(walk.phase, WalkPhase.returning);
      expect(walk.onScan(at(1000), scan(x: 1.8, z: 0.3, center: const LidarClear())), isNull);
      expect(walk.onScan(at(1100), scan(x: 1.8, z: 0.05, center: const LidarClear())), isNull);
      expect(walk.onScan(at(1200), scan(x: 1.8, z: 0.05, center: const LidarClear())), WalkCue.goStraight);
      expect(walk.phase, WalkPhase.straight);
    });

    test('left bypass returns to the right', () {
      passing(left: true);
      walk.onScan(at(700), scan(x: 0.6, z: -0.75, center: const LidarClear()));
      walk.onScan(at(800), scan(x: 1.2, z: -0.75, center: const LidarClear()));
      expect(walk.onScan(at(900), scan(x: 1.8, z: -0.75, center: const LidarClear())), WalkCue.stepRight);
      expect(walk.phase, WalkPhase.returning);
    });

    test('standing beside object never triggers return after a second', () {
      passing();
      feed(scan(z: 0.75, center: const LidarClear()), from: 700, count: 15);
      expect(walk.phase, WalkPhase.passing);
    });

    test('return requires floor across original lane beyond the object', () {
      passing();
      walk.onScan(at(700), scan(x: 0.6, z: 0.75, center: const LidarClear()));
      walk.onScan(at(800), scan(x: 1.2, z: 0.75, center: const LidarClear()));
      expect(walk.onScan(at(900), scan(x: 1.8, z: 0.75,
          center: const LidarClear(), occupied: [0.05, 0.75])), isNull);
      expect(walk.phase, WalkPhase.passing);
    });

    test('observed far edge prevents returning alongside a long object', () {
      passing();
      const side = [0.4, 0.5, 0.8, 0.5];
      walk.onScan(at(700), scan(x: 0.6, z: 0.75, center: const LidarClear(), occupied: side));
      walk.onScan(at(800), scan(x: 1.2, z: 0.75, center: const LidarClear()));
      expect(walk.onScan(at(900), scan(x: 1.8, z: 0.75, center: const LidarClear())), isNull);
      expect(walk.onScan(at(1000), scan(x: 2.0, z: 0.75, center: const LidarClear())), WalkCue.stepLeft);
    });

    test('new front obstacle stops during passing', () {
      passing();
      expect(walk.onScan(at(700), scan(z: 0.75, center: const LidarObstacle(0.6))), WalkCue.stop);
      expect(walk.phase, WalkPhase.collect);
    });

    test('unknown scan cannot authorize any continuation', () {
      passing();
      expect(walk.onScan(at(700), scan(z: 0.75, center: const LidarUnknown())), WalkCue.findWay);
    });

    test('a stale stream stops an in-progress bypass', () {
      passing();
      expect(walk.tick(at(1200), aheadOpen: true, turning: false, turnedDegrees: 0), WalkCue.findWay);
    });

    test('late clear scans cannot complete an expired sidestep', () {
      collect();
      feed(scan());
      feed(scan(center: const LidarClear()), from: 500, count: 49);
      expect(walk.onScan(at(5400), scan(z: 0.75,
          center: const LidarClear())), WalkCue.findWay);
    });

    test('passing cannot wait indefinitely for an unverified return', () {
      passing();
      feed(scan(z: 0.75, center: const LidarClear()), from: 700, count: 199);
      expect(walk.onScan(at(20600), scan(z: 0.75,
          center: const LidarClear())), WalkCue.findWay);
    });

    test('room pose jump stops rather than pretending the object was passed', () {
      passing();
      expect(walk.onScan(at(700), scan(x: 2, z: 0.75, center: const LidarClear())), WalkCue.findWay);
    });

    test('phase revision changes on reset to invalidate queued motion', () {
      passing();
      final revision = walk.revision;
      walk.reset();
      expect(walk.revision, greaterThan(revision));
    });

    test('collect timeout stops and asks to find a way', () {
      collect();
      walk.tick(at(0), aheadOpen: false, turning: false, turnedDegrees: 0);
      expect(walk.tick(at(2100), aheadOpen: false, turning: false, turnedDegrees: 0), WalkCue.findWay);
    });
  });
}
