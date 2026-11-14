import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/models/scene_info.dart';
import 'package:smart_eye/services/lidar_analysis.dart';
import 'package:smart_eye/services/wall_guide.dart';

final t0 = DateTime(2026);
DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

LidarScan scan(
  LidarReading centre, {
  LidarReading left = const LidarObstacle(1.2),
  LidarReading right = const LidarObstacle(1.2),
}) => LidarScan(left, centre, right);

const wall = LidarObstacle(1.4, wall: true);
const chair = LidarObstacle(1.0);

/// Feeds [s] every 100 ms from [from] to [to] (inclusive); events in order.
List<WallEvent> run(
  WallGuide g,
  LidarScan s,
  int from,
  int to, {
  bool warned = true,
}) => [
  for (var ms = from; ms <= to; ms += 100)
    ?g.update(at(ms), s, warned: warned)?.event,
];

void main() {
  late WallGuide g;
  setUp(() => g = WallGuide());

  test('free → wall only once LiDAR warns about it', () {
    expect(run(g, scan(wall), 0, 500, warned: false), isEmpty);
    expect(g.active, isFalse);
    expect(run(g, scan(wall), 600, 600), [WallEvent.entered]);
    expect(g.active, isTrue);
  });

  test('a non-wall obstacle is the obstacle state, not this one', () {
    expect(run(g, scan(chair), 0, 2000), isEmpty);
    expect(g.active, isFalse);
  });

  test('facing the wall: reminded every 5 s, not every reading', () {
    run(g, scan(wall), 0, 0);
    expect(run(g, scan(wall), 100, 4900), isEmpty);
    expect(run(g, scan(wall), 5000, 5000), [WallEvent.remind]);
  });

  test('turned to an open way for 1 s → found, back to free walking', () {
    run(g, scan(wall), 0, 0);
    expect(run(g, scan(const LidarClear()), 100, 1000), isEmpty);
    expect(run(g, scan(const LidarClear()), 1100, 1100), [WallEvent.found]);
    expect(g.active, isFalse);
  });

  test('a glimpse of open space does not end it', () {
    run(g, scan(wall), 0, 0);
    expect(run(g, scan(const LidarClear()), 100, 500), isEmpty);
    expect(run(g, scan(wall), 600, 700), isEmpty);
    expect(run(g, scan(const LidarClear()), 800, 1700), isEmpty);
    expect(g.active, isTrue);
  });

  test('turned to something else close: left quietly for obstacle alerts', () {
    run(g, scan(wall), 0, 0);
    expect(run(g, scan(chair), 100, 1100), [WallEvent.left]);
    expect(g.active, isFalse);
  });

  test('an obstacle beyond 2.2 m counts as open', () {
    run(g, scan(wall), 0, 0);
    expect(run(g, scan(const LidarObstacle(3.0)), 100, 1100), [
      WallEvent.found,
    ]);
  });

  test('unknown depth neither enters nor ends it', () {
    expect(run(g, scan(const LidarUnknown()), 0, 500), isEmpty);
    run(g, scan(wall), 600, 600);
    run(g, scan(const LidarClear()), 700, 1500);
    expect(run(g, scan(const LidarUnknown()), 1600, 1700), isEmpty);
    expect(run(g, scan(const LidarClear()), 1800, 2700), isEmpty);
    expect(run(g, scan(const LidarClear()), 2800, 2800), [WallEvent.found]);
  });

  test('turn towards the clearly deeper side corridor', () {
    expect(WallGuide.turnOf(scan(wall, left: const LidarClear())), HPos.left);
    expect(
      WallGuide.turnOf(
        scan(
          wall,
          left: const LidarObstacle(1.0),
          right: const LidarObstacle(2),
        ),
      ),
      HPos.right,
    );
    expect(WallGuide.turnOf(scan(wall)), isNull);
    expect(
      WallGuide.turnOf(
        scan(wall, left: const LidarClear(), right: const LidarClear()),
      ),
      isNull,
    );
    expect(WallGuide.turnOf(scan(wall, left: const LidarUnknown())), isNull);
  });

  test('spoken lines', () {
    expect(
      wallCueText((event: WallEvent.entered, turn: HPos.right)),
      'Tường phía trước. Quay sang phải.',
    );
    expect(
      wallCueText((event: WallEvent.remind, turn: null)),
      'Vẫn là tường. Xoay trái hoặc phải để tìm lối.',
    );
    expect(
      wallCueText((event: WallEvent.found, turn: null)),
      'Đã có lối. Đi thẳng.',
    );
    expect(
      wallCueText((event: WallEvent.found, turn: null), guiding: true),
      'Đã có lối.',
    );
  });
}
