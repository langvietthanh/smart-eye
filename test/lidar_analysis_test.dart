import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/models/scene_info.dart';
import 'package:smart_eye/services/lidar_analysis.dart';
import 'package:smart_eye/services/proximity_pulse.dart';

/// Axis-aligned box in world metres: x right, y up (floor at 0), z forward.
class Box {
  const Box(this.x0, this.y0, this.z0, this.x1, this.y1, this.z1);
  final double x0, y0, z0, x1, y1, z1;

  double? hit(List<double> o, List<double> d) {
    var tMin = 0.0, tMax = double.infinity;
    final lo = [x0, y0, z0], hi = [x1, y1, z1];
    for (var a = 0; a < 3; a++) {
      if (d[a].abs() < 1e-12) {
        if (o[a] < lo[a] || o[a] > hi[a]) return null;
        continue;
      }
      var t0 = (lo[a] - o[a]) / d[a], t1 = (hi[a] - o[a]) / d[a];
      if (t0 > t1) (t0, t1) = (t1, t0);
      tMin = max(tMin, t0);
      tMax = min(tMax, t1);
      if (tMin > tMax) return null;
    }
    return tMin > 0 ? tMin : null;
  }
}

/// A wall across the path at [z] (0.2 m thick, 3 m tall, 10 m wide).
Box wall(double z, {double x0 = -5, double x1 = 5}) =>
    Box(x0, 0, z, x1, 3, z + 0.2);

const w = 256, h = 192;
const focal = 193.0;

/// Ray-cast an ARKit-like depth frame: phone at [cameraHeight], tilted
/// [pitchDeg] below the horizon, rolled [rollDeg] about its view axis
/// (0 = landscape sensor upright, 90 = portrait hold).
LidarDepthFrame render({
  double pitchDeg = 15,
  double rollDeg = 90,
  double cameraHeight = 1.3,
  List<Box> boxes = const [],
  double range = 5,
  bool tracking = true,
  List<(double, double, double, double)> holes = const [],
}) {
  final p = pitchDeg * pi / 180, r = rollDeg * pi / 180;
  final look = [0.0, -sin(p), cos(p)];
  final right0 = [1.0, 0.0, 0.0];
  final up0 = [0.0, cos(p), sin(p)];
  final right = [
    for (var i = 0; i < 3; i++) cos(r) * right0[i] + sin(r) * up0[i],
  ];
  final up = [
    for (var i = 0; i < 3; i++) -sin(r) * right0[i] + cos(r) * up0[i],
  ];
  final origin = [0.0, cameraHeight, 0.0];
  final depth = Float32List(w * h);
  final conf = Uint8List(w * h);
  const cx = (w - 1) / 2, cy = (h - 1) / 2;
  for (var v = 0; v < h; v++) {
    for (var u = 0; u < w; u++) {
      final xr = (u - cx) / focal, yr = -(v - cy) / focal;
      final dir = [
        for (var i = 0; i < 3; i++) xr * right[i] + yr * up[i] + look[i],
      ];
      double? t = dir[1] < 0 ? -cameraHeight / dir[1] : null;
      if (t != null) {
        // Floor rectangles (x0, z0, x1, z1) that return nothing: a hole or drop.
        final x = t * dir[0], z = t * dir[2];
        for (final (x0, z0, x1, z1) in holes) {
          if (x >= x0 && x <= x1 && z >= z0 && z <= z1) t = null;
        }
      }
      for (final b in boxes) {
        final bt = b.hit(origin, dir);
        if (bt != null && (t == null || bt < t)) t = bt;
      }
      final i = v * w + u;
      if (t == null) continue;
      depth[i] = t; // dir has unit component along the view axis
      conf[i] = t <= range ? 2 : 0;
    }
  }
  return LidarDepthFrame(
    width: w,
    height: h,
    depth: depth,
    confidence: conf,
    fx: focal,
    fy: focal,
    cx: cx,
    cy: cy,
    upX: right[1],
    upY: up[1],
    upZ: -look[1],
    trackingAvailable: tracking,
  );
}

double distanceOf(LidarReading r) {
  expect(r, isA<LidarObstacle>());
  return (r as LidarObstacle).distance;
}

/// A 50 cm wide, 90 cm tall chair across the centre corridor at [z].
Box chair(double z) => Box(-0.25, 0, z, 0.25, 0.9, z + 0.4);

LidarObstacle obstacleOf(LidarReading r) {
  expect(r, isA<LidarObstacle>());
  return r as LidarObstacle;
}

void sideLaneTests() {
  test('free floor beside a chair is clear on both sides', () {
    final r = obstacleOf(LidarAnalysis().analyze(render(boxes: [chair(1.8)])));
    expect(r.distance, closeTo(1.8, 0.1));
    expect(r.left, SideState.clear);
    expect(r.right, SideState.clear);
  });

  test('box in the right lane blocks right only', () {
    final r = obstacleOf(
      LidarAnalysis().analyze(
        render(boxes: [chair(1.8), const Box(0.4, 0, 1.9, 0.7, 0.8, 2.3)]),
      ),
    );
    expect(r.right, SideState.blocked);
    expect(r.left, SideState.clear);
  });

  test('a full-width wall blocks both lanes', () {
    final r = obstacleOf(LidarAnalysis().analyze(render(boxes: [wall(1.8)])));
    expect(r.left, SideState.blocked);
    expect(r.right, SideState.blocked);
  });

  test('lanes outside the view are unknown when the obstacle is close', () {
    final r = obstacleOf(LidarAnalysis().analyze(render(boxes: [chair(0.9)])));
    expect(r.left, SideState.unknown);
    expect(r.right, SideState.unknown);
  });

  test('a hole in the left lane floor makes it unknown, never clear', () {
    final r = obstacleOf(
      LidarAnalysis().analyze(
        // Covers a whole 0.5 m stretch of the left lane, like a drop.
        render(boxes: [chair(1.8)], holes: [(-0.8, 2.2, -0.36, 3.0)]),
      ),
    );
    expect(r.left, SideState.unknown);
    expect(r.right, SideState.clear);
  });

  test('platform in a side lane blocks it', () {
    final r = obstacleOf(
      LidarAnalysis().analyze(
        render(boxes: [chair(1.8), const Box(-3, 0, 1.6, -0.36, 0.2, 4)]),
      ),
    );
    expect(r.left, SideState.blocked);
  });

  test('an obstacle in the lane before the centre obstacle blocks it', () {
    final r = obstacleOf(
      LidarAnalysis().analyze(
        render(boxes: [chair(2.0), const Box(-0.7, 0, 1.0, -0.4, 0.8, 1.3)]),
      ),
    );
    expect(r.left, SideState.blocked);
  });

  test('a small box far in the lane blocks it', () {
    final r = obstacleOf(
      LidarAnalysis().analyze(
        // A 20 cm bag lying ~3.5 m ahead in the right lane.
        render(boxes: [chair(2.8), const Box(0.45, 0, 3.4, 0.65, 0.22, 3.6)]),
      ),
    );
    expect(r.right, SideState.blocked);
  });

  test('a low 12 cm step in a side lane is never clear', () {
    final r = obstacleOf(
      LidarAnalysis().analyze(
        render(boxes: [chair(1.8), const Box(-3, 0, 1.6, -0.36, 0.12, 4)]),
      ),
    );
    expect(r.left, isNot(SideState.clear));
  });

  test('side lanes do not depend on hold', () {
    for (final f in [
      render(pitchDeg: 25, boxes: [chair(1.8)]),
      render(cameraHeight: 1.0, boxes: [chair(1.8)]),
    ]) {
      final r = obstacleOf(LidarAnalysis().analyze(f));
      expect((r.left, r.right), (SideState.clear, SideState.clear));
    }
  });
}

void sideStabilityTests() {
  const both = LidarObstacle(
    1.5,
    left: SideState.clear,
    right: SideState.clear,
  );
  const rightBlocked = LidarObstacle(
    1.5,
    left: SideState.clear,
    right: SideState.blocked,
  );
  const unknown = (left: SideState.unknown, right: SideState.unknown);

  test('clear needs three frames in a row', () {
    final s = SideStability();
    expect(s.update(both), unknown);
    expect(s.update(both).left, SideState.unknown);
    expect(s.update(both), (left: SideState.clear, right: SideState.clear));
  });

  test('blocked takes effect at once', () {
    final s = SideStability();
    for (var i = 0; i < 3; i++) {
      s.update(both);
    }
    expect(s.update(rightBlocked), (
      left: SideState.clear,
      right: SideState.blocked,
    ));
  });

  test('a broken clear streak starts over', () {
    final s = SideStability();
    s.update(both);
    s.update(both);
    s.update(rightBlocked);
    expect(s.update(both).right, SideState.blocked);
    expect(s.update(both).right, SideState.blocked);
    expect(s.update(both).right, SideState.clear);
  });

  test('clear or unknown readings and reset drop both sides', () {
    final s = SideStability();
    for (var i = 0; i < 3; i++) {
      s.update(both);
    }
    expect(s.update(const LidarClear()), unknown);
    for (var i = 0; i < 3; i++) {
      s.update(both);
    }
    expect(s.update(const LidarUnknown()).left, SideState.unknown);
    for (var i = 0; i < 3; i++) {
      s.update(both);
    }
    s.reset();
    expect(s.update(both).left, SideState.unknown);
  });
}

void main() {
  group('warning', warningTests);
  group('side lanes', sideLaneTests);
  group('side stability', sideStabilityTests);

  test('wall at 1.5 m reads 1.5 m at any tilt and hold', () {
    for (final pitch in [0.0, 15.0, 35.0]) {
      for (final roll in [0.0, 90.0]) {
        final r = LidarAnalysis().analyze(
          render(pitchDeg: pitch, rollDeg: roll, boxes: [wall(1.5)]),
        );
        expect(
          distanceOf(r),
          closeTo(1.5, 0.05),
          reason: 'pitch $pitch roll $roll',
        );
      }
    }
  });

  test('floor alone is a clear path and the floor is found', () {
    final a = LidarAnalysis();
    expect(a.analyze(render()), isA<LidarClear>());
    expect(a.floorHeight, closeTo(-1.3, 0.05));
  });

  test('floor is found when the phone is held lower', () {
    final a = LidarAnalysis();
    expect(a.analyze(render(cameraHeight: 1.0)), isA<LidarClear>());
    expect(a.floorHeight, closeTo(-1.0, 0.05));
  });

  test('a 0.8 m doorway does not warn about its frame', () {
    final r = LidarAnalysis().analyze(
      render(
        boxes: [
          wall(1.0, x0: -5, x1: -0.4),
          wall(1.0, x0: 0.4, x1: 5),
          wall(3.0),
        ],
      ),
    );
    expect(distanceOf(r), closeTo(3.0, 0.1));
  });

  test('a low box near the feet is an obstacle', () {
    final r = LidarAnalysis().analyze(
      render(pitchDeg: 25, boxes: [const Box(-0.25, 0, 0.9, 0.25, 0.4, 1.2)]),
    );
    expect(distanceOf(r), closeTo(0.9, 0.08));
  });

  test('a few noisy close pixels are ignored', () {
    final f = render();
    for (var v = 90; v < 100; v++) {
      for (var u = 120; u < 130; u++) {
        f.depth[v * w + u] = 0.5;
      }
    }
    expect(LidarAnalysis().analyze(f), isA<LidarClear>());
  });

  test('mostly untrusted depth is unknown, not clear', () {
    final f = render(boxes: [wall(1.5)]);
    for (var i = 0; i < f.confidence.length * 0.9; i++) {
      f.confidence[i] = 0;
    }
    expect(LidarAnalysis().analyze(f), isA<LidarUnknown>());
  });

  test('lost tracking is unknown', () {
    expect(
      LidarAnalysis().analyze(render(boxes: [wall(1.5)], tracking: false)),
      isA<LidarUnknown>(),
    );
  });

  test('floor estimate survives a wall hiding the floor', () {
    final a = LidarAnalysis();
    a.analyze(render(cameraHeight: 1.0));
    final r = a.analyze(
      render(pitchDeg: 0, cameraHeight: 1.0, boxes: [wall(0.4)]),
    );
    expect(distanceOf(r), closeTo(0.4, 0.05));
    expect(a.floorHeight, closeTo(-1.0, 0.05));
  });
}

void warningTests() {
  // One LiDAR reading every 100 ms.
  var clock = DateTime(2026);
  AlertLevel feed(LidarWarning w, List<double?> metres) {
    var level = AlertLevel.info;
    for (final m in metres) {
      clock = clock.add(const Duration(milliseconds: 100));
      level = w.update(
        m == null ? const LidarClear() : LidarObstacle(m),
        clock,
      );
    }
    return level;
  }

  test('caution needs two readings under 2 m', () {
    final w = LidarWarning();
    expect(feed(w, [2.1]), AlertLevel.info);
    expect(feed(w, [1.9]), AlertLevel.info);
    expect(feed(w, [1.9]), AlertLevel.caution);
  });

  test('hysteresis holds levels until the exit distance', () {
    final w = LidarWarning();
    expect(feed(w, [2.4, 1.9, 1.9, 2.1, 2.15]), AlertLevel.caution);
    expect(feed(w, [2.3]), AlertLevel.info);
    expect(feed(w, [0.9, 0.9, 1.1]), AlertLevel.danger);
    expect(feed(w, [1.3, 1.3]), AlertLevel.caution);
    expect(feed(w, [null]), AlertLevel.info);
  });

  test('a single unknown frame does not break the streak', () {
    final w = LidarWarning();
    feed(w, [1.4]);
    expect(w.update(const LidarUnknown(), clock), AlertLevel.info);
    expect(feed(w, [1.4]), AlertLevel.caution);
  });

  test('standing still 1.5–2 m away is not warned', () {
    final w = LidarWarning();
    expect(feed(w, List.filled(30, 1.8)), AlertLevel.info);
    expect(feed(w, List.filled(30, 1.5)), AlertLevel.info);
  });

  test('walking towards it warns from 2 m', () {
    final w = LidarWarning();
    expect(feed(w, [2.6, 2.4, 2.2, 2.0, 1.9, 1.8]), AlertLevel.caution);
  });

  test('stopping after the warning goes quiet within the window', () {
    final w = LidarWarning();
    expect(feed(w, [2.4, 2.2, 1.9, 1.8]), AlertLevel.caution);
    expect(feed(w, List.filled(12, 1.8)), AlertLevel.info);
  });

  test('something stepping into the corridor is approaching', () {
    final w = LidarWarning();
    expect(feed(w, [null, 1.9, 1.9]), AlertLevel.caution);
  });

  test('under 1.5 m caution holds standing still', () {
    final w = LidarWarning();
    expect(feed(w, List.filled(30, 1.4)), AlertLevel.caution);
  });

  test('pulse proximity from metres', () {
    expect(ProximityPulse.fromDistance(null), isNull);
    expect(ProximityPulse.fromDistance(3), isNull);
    expect(ProximityPulse.fromDistance(2.5), 0);
    expect(ProximityPulse.fromDistance(1.75), closeTo(0.5, 1e-9));
    expect(ProximityPulse.fromDistance(1.0), 1);
    expect(ProximityPulse.fromDistance(0.3), 1);
  });

  Box sideWall(double x) =>
      Box(x < 0 ? x - 0.2 : x, 0, 0, x < 0 ? x : x + 0.2, 3, 10);

  test('corner: front and both sides are blocked', () {
    final s = LidarAnalysis().analyzeScan(
      render(boxes: [wall(1.2), sideWall(-0.7), sideWall(0.7)]),
    );
    for (final r in [s.left, s.center, s.right]) {
      expect(r, isA<LidarObstacle>());
      expect((r as LidarObstacle).distance, lessThanOrEqualTo(1.5));
    }
  });

  test('a wall on the left only blocks the left corridor', () {
    final s = LidarAnalysis().analyzeScan(render(boxes: [sideWall(-0.7)]));
    expect(s.left, isA<LidarObstacle>());
    expect(s.center, isA<LidarClear>());
    expect(s.right, isA<LidarClear>());
    expect(s[HPos.left], same(s.left));
  });

  test('a wall on the right only blocks the right corridor', () {
    final s = LidarAnalysis().analyzeScan(render(boxes: [sideWall(0.7)]));
    expect(s.right, isA<LidarObstacle>());
    expect(s.center, isA<LidarClear>());
    expect(s.left, isA<LidarClear>());
    expect(s[HPos.right], same(s.right));
  });

  test('a side wall beyond the side corridor leaves that side clear', () {
    for (final x in [-1.3, 1.3]) {
      final s = LidarAnalysis().analyzeScan(render(boxes: [sideWall(x)]));
      expect(
        [s.left, s.center, s.right],
        everyElement(isA<LidarClear>()),
        reason: 'wall at lateral $x m',
      );
    }
  });

  test('a 1.2 m hallway blocks both sides but not the centre', () {
    final s = LidarAnalysis().analyzeScan(
      render(boxes: [sideWall(-0.6), sideWall(0.6)]),
    );
    expect(s.left, isA<LidarObstacle>());
    expect(s.right, isA<LidarObstacle>());
    expect(s.center, isA<LidarClear>());
  });

  test('analyze is the centre of analyzeScan', () {
    final f = render(boxes: [wall(1.5)]);
    final a = LidarAnalysis().analyze(f) as LidarObstacle;
    final b = LidarAnalysis().analyzeScan(f).center as LidarObstacle;
    expect(a.distance, b.distance);
  });

  test('untrusted depth makes every direction unknown', () {
    final f = render(tracking: false);
    final s = LidarAnalysis().analyzeScan(f);
    expect([s.left, s.center, s.right], everyElement(isA<LidarUnknown>()));
  });
}
