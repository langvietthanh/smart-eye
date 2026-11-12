import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/services/depth_analysis.dart';
import 'package:smart_eye/services/lidar_analysis.dart';
import 'package:smart_eye/services/path_blockage.dart';

final t0 = DateTime(2026, 1, 1);
DateTime at(int ms) => t0.add(Duration(milliseconds: ms));
const all = [1.0, 1.0, 1.0], sides = [1.0, 0.0, 1.0], none = [0.0, 0.0, 0.0];
LidarScan scan(double? l, double? c, double? r) {
  LidarReading m(double? d) =>
      d == null ? const LidarClear() : LidarObstacle(d);
  return LidarScan(m(l), m(c), m(r));
}

/// Feeds [load] every 250 ms from [from] to [to] (inclusive) and evaluates.
List<PathEvent> run(
  PathBlockage p,
  List<double> load,
  int from,
  int to, {
  LidarScan? depth,
}) {
  final events = <PathEvent>[];
  for (var ms = from; ms <= to; ms += 250) {
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

  test('blocked under one second is not trapped', () {
    expect(run(p, all, 0, 750), isEmpty);
    expect(p.trapped, false);
  });

  test('blocked for over a second traps once', () {
    expect(run(p, all, 0, 1500), [PathEvent.trapped]);
    expect(run(p, all, 1750, 3000), isEmpty);
  });

  test('an open side with a blocked centre releases as opened', () {
    run(p, all, 0, 1500);
    expect(run(p, [0, 1, 1], 1750, 3000), [PathEvent.opened]);
    expect(p.trapped, false);
  });

  test('a briefly open side does not release', () {
    run(p, all, 0, 1500);
    final events = [
      ...run(p, [0, 1, 1], 1750, 2250),
      ...run(p, all, 2500, 3000),
    ];
    expect(events, isEmpty);
    expect(p.trapped, isTrue);
  });

  test('a LiDAR side between entry and exit distance does not open', () {
    expect(run(p, all, 0, 1500, depth: scan(1, 1, 1)), [PathEvent.trapped]);
    expect(run(p, [0, 1, 0], 1750, 3500, depth: scan(1.6, 1, 1.6)), isEmpty);
    expect(p.trapped, isTrue);
    expect(run(p, [0, 1, 0], 3750, 5250, depth: scan(2.3, 1, 1)), [
      PathEvent.opened,
    ]);
  });

  test('unknown depth never opens a side', () {
    expect(run(p, all, 0, 1500, depth: scan(1, 1, 1)), [PathEvent.trapped]);
    expect(run(p, [0, 1, 0], 1750, 4000, depth: LidarScan.unknown), isEmpty);
    expect(p.trapped, true);
  });

  test('a brief clear centre does not release', () {
    run(p, all, 0, 1500);
    final events = [...run(p, sides, 1750, 2250), ...run(p, all, 2500, 3000)];
    expect(events, isNot(contains(PathEvent.cleared)));
    expect(p.trapped, isTrue);
  });

  test('a clear centre for a second releases', () {
    run(p, all, 0, 1500);
    expect(run(p, sides, 1750, 3000), [PathEvent.cleared]);
    expect(p.trapped, false);
  });

  test('with LiDAR, metres decide: YOLO "near" sides do not trap', () {
    // Desks beside an aisle look "khá gần" to YOLO but are beyond 1.5 m.
    expect(run(p, sides, 0, 3000, depth: scan(null, 1.2, null)), isEmpty);
    expect(run(p, sides, 3250, 4750, depth: scan(1.0, 1.2, 0.8)), [
      PathEvent.trapped,
    ]);
  });

  test('a column LiDAR cannot read falls back to YOLO', () {
    final s = LidarScan(
      const LidarUnknown(),
      LidarObstacle(1.2),
      LidarObstacle(1),
    );
    expect(run(p, [1, 0, 0], 0, 1500, depth: s), [PathEvent.trapped]);
  });

  test('LiDAR beyond 1.5 m does not block', () {
    expect(run(p, sides, 0, 1500, depth: scan(null, 1.6, null)), isEmpty);
  });

  test('stale inputs are ignored', () {
    p.onDetections(at(0), all);
    p.onDepth(at(0), scan(1, 1, 1));
    expect(p.blocked(at(1100)), [false, false, false]);
    expect(p.blocked(at(400)), [true, true, true]);
  });

  test('unknown depth falls back to YOLO', () {
    expect(run(p, all, 0, 1500, depth: LidarScan.unknown), [PathEvent.trapped]);
  });

  test('unknown depth never releases a trap', () {
    expect(run(p, all, 0, 1500, depth: scan(1, 1, 1)), [PathEvent.trapped]);
    expect(run(p, sides, 1750, 4000, depth: LidarScan.unknown), isEmpty);
    expect(p.trapped, true);
  });

  test('without LiDAR a clear YOLO centre releases', () {
    run(p, all, 0, 1500);
    expect(run(p, sides, 1750, 3000), [PathEvent.cleared]);
  });

  test('reset is silent', () {
    run(p, all, 0, 1500);
    p.reset();
    expect(p.trapped, false);
    expect(run(p, none, 1750, 3000), isEmpty);
  });

  test('LiDAR centre between entry and caution exit does not release', () {
    expect(run(p, all, 0, 1500, depth: scan(1, 1, 1)), [PathEvent.trapped]);
    expect(run(p, sides, 1750, 3500, depth: scan(1, 1.6, 1)), isEmpty);
    expect(p.trapped, isTrue);
    expect(run(p, sides, 3750, 5250, depth: scan(1, 2.3, 1)), [
      PathEvent.cleared,
    ]);
    expect(p.trapped, isFalse);
  });

  test('interrupt during entry settle needs a fresh full second', () {
    expect(run(p, all, 0, 750), isEmpty);
    p.interrupt();
    expect(run(p, all, 1000, 1750), isEmpty);
    expect(p.trapped, isFalse);
    expect(run(p, all, 2000, 2000), [PathEvent.trapped]);
  });

  test('interrupt during exit settle needs a fresh full second', () {
    expect(run(p, all, 0, 1500), [PathEvent.trapped]);
    expect(run(p, sides, 1750, 2500), isEmpty);
    p.interrupt();
    expect(p.trapped, isTrue);
    expect(run(p, sides, 2750, 3500), isEmpty);
    expect(run(p, sides, 3750, 3750), [PathEvent.cleared]);
  });

  test('reset clears seen depth', () {
    expect(run(p, all, 0, 1500, depth: scan(1, 1, 1)), [PathEvent.trapped]);
    p.reset();
    expect(run(p, all, 1750, 3000), [PathEvent.trapped]);
    expect(run(p, sides, 3250, 4500), [PathEvent.cleared]);
  });

  group('watchAhead', () {
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

    test('MiDaS evidence is also needed to leave a trap', () {
      expect(mono(0, 1500, 0.95, sideLoad: 1), isEmpty); // YOLO centre free
      run(p, all, 1750, 3250);
      expect(p.trapped, isTrue);
      final events = <PathEvent>[];
      for (var ms = 3500; ms <= 5000; ms += 250) {
        p.onDetections(at(ms), sides);
        p.onMonoDepth(at(ms), const DepthReading(1, 0.9, 1));
        final e = p.evaluate(at(ms));
        if (e != null) events.add(e);
      }
      expect(events, isEmpty);
      expect(p.trapped, isTrue);
    });
  });
}
