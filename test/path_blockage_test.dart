import 'package:flutter_test/flutter_test.dart';
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

  test('YOLO sides and LiDAR centre combine', () {
    expect(run(p, sides, 0, 1500, depth: scan(null, 1.2, null)), [
      PathEvent.trapped,
    ]);
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
}
