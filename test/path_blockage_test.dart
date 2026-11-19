import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/models/scene_info.dart';
import 'package:smart_eye/services/depth_analysis.dart';
import 'package:smart_eye/services/lidar_analysis.dart';
import 'package:smart_eye/services/path_blockage.dart';
import 'package:smart_eye/services/walk_state.dart';

final t0 = DateTime(2026, 1, 1);
DateTime at(int ms) => t0.add(Duration(milliseconds: ms));
const all = [1.0, 1.0, 1.0], sides = [1.0, 0.0, 1.0], none = [0.0, 0.0, 0.0];
const centerDanger = HazardAlert(
  level: AlertLevel.danger,
  message: 'Dừng lại! Có ghế ngay phía trước.',
  guidance: Guidance.stop,
  subject: 'track:1',
  pos: HPos.center,
);
const overlappingSideDanger = HazardAlert(
  level: AlertLevel.danger,
  message: 'Dừng lại! Có ghế ngay phía trước.',
  guidance: Guidance.stop,
  subject: 'track:2',
  pos: HPos.left,
  inPath: true,
);

LidarScan scan(double? l, double? c, double? r) {
  LidarReading m(double? d) =>
      d == null ? const LidarClear() : LidarObstacle(d);
  return LidarScan(m(l), m(c), m(r));
}

/// Feeds [load] every [step] ms from [from] to [to] (inclusive) and evaluates.
List<PathEvent> run(
  PathBlockage p,
  List<double> load,
  int from,
  int to, {
  LidarScan? depth,
  int step = 250,
}) {
  final events = <PathEvent>[];
  for (var ms = from; ms <= to; ms += step) {
    p.onDetections(at(ms), load);
    if (depth != null) p.onDepth(at(ms), depth);
    final e = p.evaluate(at(ms));
    if (e != null) events.add(e);
  }
  return events;
}

void main() {
  late PathBlockage p;
  setUp(() => p = PathBlockage());

  group('openAhead', () {
    test('empty detector columns without depth never authorize walking', () {
      p.onDetections(at(0), none);
      expect(p.openAhead(at(0)), isFalse);
      p.onDetections(at(1500), none);
      expect(p.openAhead(at(1500)), isFalse);
      expect(p.aheadOpenSettled(at(1500)), isFalse);
    });

    test('with LiDAR: custom beyond threshold', () {
      final now = at(1000);
      p.onDepth(now, scan(null, 1.4, null));
      expect(p.openAhead(now, beyond: 1.5), isFalse);

      p.onDepth(now, scan(null, 1.6, null));
      expect(p.openAhead(now, beyond: 1.5), isTrue);

      p.onDepth(now, scan(null, null, null));
      expect(p.openAhead(now, beyond: 1.5), isTrue);

      p.onDepth(now, LidarScan.unknown);
      expect(p.openAhead(now, beyond: 1.5), isFalse);
    });

    test('default keeps 2.2 m', () {
      final now = at(1000);
      p.onDepth(now, scan(null, 2.0, null));
      expect(p.openAhead(now), isFalse);

      p.onDepth(now, scan(null, 2.3, null));
      expect(p.openAhead(now), isTrue);
    });
  });

  group('blocked', () {
    test('narrow centre danger blocks despite zero load and clear LiDAR', () {
      p.onDetections(at(0), none, alert: centerDanger);
      p.onDepth(at(0), scan(null, null, null));
      expect(p.blocked(at(0)), [false, true, false]);
      expect(p.states(at(0))[HPos.center.index], SideState.blocked);
      expect(p.openAhead(at(0)), isFalse);
    });

    test('a side-centred box overlapping the corridor blocks straight ahead', () {
      p.onDetections(at(0), none, alert: overlappingSideDanger);
      p.onDepth(at(0), scan(null, null, null));
      expect(p.states(at(0))[HPos.center.index], SideState.blocked);
      expect(p.openAhead(at(0)), isFalse);
    });

    test('centre danger expires with the detector observation', () {
      p.onDetections(at(0), none, alert: centerDanger);
      p.onDepth(at(1000), scan(null, null, null));
      expect(p.openAhead(at(1000)), isFalse);
      expect(p.openAhead(at(1001)), isTrue);
    });

    test('a current observation replaces the previous danger', () {
      p.onDetections(at(0), none, alert: centerDanger);
      p.onDepth(at(0), scan(null, null, null));
      p.onDetections(at(100), none);
      expect(p.openAhead(at(100)), isTrue);
      p.reset();
      expect(p.states(at(100)), everyElement(SideState.unknown));
    });

    test('diagnostics distinguish unknown columns from measured open ones', () {
      p.onDetections(at(0), none);
      expect(p.states(at(0)), everyElement(SideState.unknown));
      p.onMonoDepth(at(0), const DepthReading(0.2, 0.2, 0.8));
      expect(p.states(at(0)), [
        SideState.clear, SideState.clear, SideState.unknown,
      ]);
      expect(p.states(at(1001)), everyElement(SideState.unknown));
    });

    test('LiDAR beyond 1.5 m does not block', () {
      p.onDepth(at(0), scan(null, 1.6, null));
      expect(p.blocked(at(0)), [false, false, false]);
    });

    test('stale inputs are ignored', () {
      p.onDetections(at(0), all);
      p.onDepth(at(0), scan(1, 1, 1));
      expect(p.blocked(at(1100)), [false, false, false]);
      expect(p.blocked(at(400)), [true, true, true]);
    });
  });

  group('watchAhead', () {
    test('fresh visual danger prevents finding an exit from clear MiDaS', () {
      final walk = WalkState();
      walk.onDanger(wall: false, sideOpen: false, canBypass: false);
      expect(walk.markFindWayPromptStarted(walk.revision, t0), isTrue);
      p.watchAhead();
      for (var ms = 0; ms <= 2000; ms += 250) {
        p.onDetections(at(ms), none, alert: centerDanger);
        p.onMonoDepth(at(ms), const DepthReading(0.2, 0.2, 0.2));
        expect(p.evaluate(at(ms)), isNull);
        expect(p.aheadOpenSettled(at(ms)), isFalse);
        expect(walk.tick(at(ms), aheadOpen: p.openAhead(at(ms)),
            turning: false, turnedDegrees: 0), isNull);
        expect(walk.phase, WalkPhase.findWay);
      }
      // Removing the warning still needs measured clearance for a second.
      for (var ms = 2250; ms <= 3000; ms += 250) {
        p.onDetections(at(ms), none);
        p.onMonoDepth(at(ms), const DepthReading(0.2, 0.2, 0.2));
        expect(walk.tick(at(ms), aheadOpen: p.openAhead(at(ms)),
            turning: false, turnedDegrees: 0), isNull);
      }
      p.onDetections(at(3250), none);
      p.onMonoDepth(at(3250), const DepthReading(0.2, 0.2, 0.2));
      expect(walk.tick(at(3250), aheadOpen: p.openAhead(at(3250)),
          turning: false, turnedDegrees: 0), WalkCue.goStraight);
    });

    List<PathEvent> mono(
      int from,
      int to,
      double centre, {
      double sideLoad = 0,
    }) {
      final events = <PathEvent>[];
      for (var ms = from; ms <= to; ms += 250) {
        p.onDetections(at(ms), [sideLoad, 0, sideLoad]);
        p.onMonoDepth(at(ms), DepthReading(0.2, centre, 0.2));
        final e = p.evaluate(at(ms));
        if (e != null) events.add(e);
      }
      return events;
    }

    test('silent without a warning first', () {
      expect(run(p, none, 0, 2000, depth: scan(null, null, null)), isEmpty);
    });

    test('after a warning, a LiDAR-clear centre for a second clears once', () {
      p.watchAhead();
      expect(run(p, none, 0, 750, depth: scan(null, null, null)), isEmpty);
      expect(run(p, none, 1000, 3000, depth: scan(null, null, null)), [
        PathEvent.cleared,
      ]);
    });

    test('LiDAR obstacle within caution exit keeps it silent', () {
      p.watchAhead();
      expect(run(p, none, 0, 3000, depth: scan(null, 2.0, null)), isEmpty);
    });

    test('YOLO alone never claims open ahead', () {
      p.watchAhead();
      expect(run(p, none, 0, 3000), isEmpty);
    });

    test('MiDaS far centre clears, near centre does not', () {
      p.watchAhead();
      expect(mono(0, 2000, 0.6), isEmpty);
      expect(mono(2250, 3500, 0.3), [PathEvent.cleared]);
    });

    test('stale MiDaS does not count', () {
      p.watchAhead();
      p.onMonoDepth(at(0), const DepthReading(0, 0, 0));
      p.onDetections(at(1500), none);
      expect(p.evaluate(at(1500)), isNull);
      p.onDetections(at(2600), none);
      expect(p.evaluate(at(2600)), isNull);
    });

    test('a new warning restarts the second', () {
      p.watchAhead();
      expect(run(p, none, 0, 750, depth: scan(null, null, null)), isEmpty);
      p.watchAhead();
      expect(run(p, none, 1000, 1750, depth: scan(null, null, null)), isEmpty);
      expect(run(p, none, 2000, 2000, depth: scan(null, null, null)), [
        PathEvent.cleared,
      ]);
    });
  });

  group('ahead open (say "Đi thẳng.")', () {
    /// Feeds inputs every 250 ms and returns the first time it settled.
    int? openAt(
      List<double> load, int from, int to, {
      LidarScan? depth,
      DepthReading? mono = const DepthReading(0.2, 0.2, 0.2),
    }) {
      for (var ms = from; ms <= to; ms += 250) {
        p.onDetections(at(ms), load);
        if (depth != null) {
          p.onDepth(at(ms), depth);
        } else if (mono != null) {
          p.onMonoDepth(at(ms), mono);
        }
        if (p.aheadOpenSettled(at(ms))) return ms;
      }
      return null;
    }

    test('far MiDaS with a free YOLO centre settles after a second', () {
      expect(openAt(sides, 0, 750), isNull);
      expect(openAt(sides, 1000, 1000), 1000);
    });

    test('YOLO alone never settles into go straight', () {
      expect(openAt(none, 0, 3000, mono: null), isNull);
    });

    test('a blocked centre restarts the second', () {
      expect(openAt(sides, 0, 500), isNull);
      expect(openAt(all, 750, 750), isNull);
      expect(openAt(sides, 1000, 1750), isNull);
      expect(openAt(sides, 2000, 2000), 2000);
    });

    test('with LiDAR the way ahead must measure clear or beyond 2.2 m', () {
      expect(openAt(none, 0, 3000, depth: scan(null, 1.6, null)), isNull);
      expect(openAt(none, 3250, 5000, depth: LidarScan.unknown), isNull);
      expect(openAt(none, 5250, 6250, depth: scan(null, 2.3, null)), 6250);
    });

    test('no fresh input is never open', () {
      p.onDetections(at(0), none);
      expect(p.aheadOpenSettled(at(0)), isFalse);
      expect(p.aheadOpenSettled(at(2500)), isFalse);
    });

    test('interrupt and reset restart the second', () {
      expect(openAt(none, 0, 750), isNull);
      p.interrupt();
      expect(openAt(none, 1000, 1750), isNull);
      p.reset();
      expect(openAt(none, 2000, 2750), isNull);
      expect(openAt(none, 3000, 3000), 3000);
    });
  });
}
