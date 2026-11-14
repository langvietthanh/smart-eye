import 'dart:math';
import 'dart:typed_data';

import '../models/scene_info.dart';

/// One ARKit scene-depth sample in sensor coordinates (not rotated).
class LidarDepthFrame {
  const LidarDepthFrame({
    required this.width,
    required this.height,
    required this.depth,
    required this.confidence,
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
    required this.upX,
    required this.upY,
    required this.upZ,
    this.trackingAvailable = true,
    this.thermalState = 0,
  });

  final int width;
  final int height;

  /// Metres along the camera's optical axis, row-major [width]×[height].
  final Float32List depth;

  /// ARConfidenceLevel per pixel: 0 low, 1 medium, 2 high.
  final Uint8List confidence;

  /// Intrinsics already scaled to [width]×[height].
  final double fx, fy, cx, cy;

  /// World "up" (against gravity) in ARKit camera coordinates:
  /// x right, y up, z towards the viewer (the camera looks along -z).
  final double upX, upY, upZ;

  /// False while ARKit tracking is not available: gravity is unreliable.
  final bool trackingAvailable;

  /// ProcessInfo.ThermalState raw value: 0 nominal … 3 critical.
  final int thermalState;
}

sealed class LidarReading {
  const LidarReading();
}

/// Fewer than [LidarAnalysis.minPoints] in the walking corridor within
/// [LidarAnalysis.maxForward]. Not a verified clear path beyond that.
class LidarClear extends LidarReading {
  const LidarClear();
}

class LidarObstacle extends LidarReading {
  const LidarObstacle(
    this.distance, {
    this.left = SideState.unknown,
    this.right = SideState.unknown,
    this.where,
    this.wall = false,
  });

  /// Horizontal distance to the nearest substantial obstacle, metres.
  final double distance;

  /// The 40 cm lanes beside the centre corridor, around this obstacle
  /// (only set on the centre reading of [LidarAnalysis.analyzeScan]).
  final SideState left, right;

  /// Centre reading only: a tall surface from near the floor to above the
  /// phone, across the whole corridor core, with both lanes blocked.
  final bool wall;

  /// Diagnostics only (centre reading): the obstacle's front
  /// [LidarAnalysis.frontDepth] of hits, sideways
  /// (+ = left of the corridor axis) and above the floor, in metres, and the
  /// phone's height above the estimated floor.
  final ({
    double sideMin,
    double sideMax,
    double heightMin,
    double heightMax,
    double phoneHeight,
  })?
  where;
}

/// Not enough trustworthy depth to say anything.
class LidarUnknown extends LidarReading {
  const LidarUnknown();
}

/// Readings for the corridors to the left, centre and right of the user.
class LidarScan {
  const LidarScan(this.left, this.center, this.right);

  final LidarReading left, center, right;

  LidarReading operator [](HPos pos) => switch (pos) {
    HPos.left => left,
    HPos.center => center,
    HPos.right => right,
  };

  static const unknown = LidarScan(
    LidarUnknown(),
    LidarUnknown(),
    LidarUnknown(),
  );
}

/// Metric, class-agnostic obstacle detection: depth pixels become 3D points
/// in a gravity-aligned frame (independent of how the phone is tilted or
/// rotated), the floor is estimated and removed, and the nearest substantial
/// cluster inside a body-width "virtual corridor" ahead is reported.
class LidarAnalysis {
  /// Half the corridor width: shoulders plus margin. A 0.8 m door fits.
  static const halfWidth = 0.35;

  /// Only hits this close to the axis make a centre obstacle: something
  /// reaching just into the outer 10 cm (a table edge) is passed by. Such
  /// hits still block the lanes (see [analyzeScan]) and the side corridors.
  static const coreHalfWidth = 0.25;

  /// Depth of the obstacle's front face used to describe it ([wallReach]).
  static const frontDepth = 0.3;

  /// A wall covers the core to at least this far each side of the axis.
  static const wallReach = 0.2;

  /// Outer edge of the side corridors, either side of the centre one: a body
  /// width past the shoulder, so desks across a ~1 m aisle do not count.
  static const sideOuter = 0.75;

  /// The centre corridor is split into strips this many across (10 cm each)
  /// to tell a wall the user walks along from one in the way.
  static const centreStrips = 7;

  /// Distance jump between neighbouring strips that marks a surface within
  /// about 20° of the walking direction.
  static const grazingStep = 0.25;

  /// Lanes beside the centre corridor, used to say a side is free: a
  /// portrait LiDAR sees sideways only ~0.5 × the distance ahead, so a lane
  /// out to 0.75 m is fully in view from ~1.5 m.
  static const laneOuter = 0.75;
  static const laneSplit = 0.55;
  static const lanePastObstacle = 1.0;
  static const laneMinDepth = 2.0;
  static const laneBin = 0.5;
  static const laneFloorPoints = 10;

  /// Sampled points that block a lane: far lower than the centre corridor's
  /// threshold, since a wrong "free" is worse than a missed one.
  static const laneObstaclePoints = 10;

  /// Lane floor must be this flat: a 10–14 cm step is neither floor nor
  /// obstacle, so its cells stay empty and the lane reads unknown.
  static const laneFloorBand = 0.06;

  /// Points this close to the floor are floor, not obstacles.
  static const floorMargin = 0.15;

  /// Corridor top relative to the phone (head height above a chest hold).
  static const headroom = 0.4;
  static const minForward = 0.2;
  static const maxForward = 4.0;

  /// Full-resolution points needed before something counts as an obstacle.
  static const minPoints = 150;

  /// Below this share of trustworthy pixels the reading is unknown
  /// (covered lens, blinding light). Open space far away is still partly
  /// valid because the floor ahead returns.
  static const minValidFraction = 0.15;

  /// Floor search window below the phone, metres.
  static const floorLowest = -1.7;
  static const floorHighest = -0.8;
  static const floorBin = 0.05;
  static const floorShare = 0.05;
  static const defaultFloor = -1.3;
  static const step = 2;

  double? _floor;

  /// Smoothed floor height relative to the phone (negative), if known.
  double? get floorHeight => _floor;

  void reset() => _floor = null;

  LidarReading analyze(LidarDepthFrame f) => analyzeScan(f).center;

  LidarScan analyzeScan(LidarDepthFrame f) {
    final n = f.width * f.height;
    if (!f.trackingAvailable ||
        f.width < 8 ||
        f.height < 8 ||
        f.depth.length < n ||
        f.confidence.length < n) {
      return LidarScan.unknown;
    }
    final upLength = sqrt(f.upX * f.upX + f.upY * f.upY + f.upZ * f.upZ);
    if (upLength < 1e-6) return LidarScan.unknown;
    final ux = f.upX / upLength, uy = f.upY / upLength, uz = f.upZ / upLength;
    // Viewing direction (0,0,-1) projected onto the horizontal plane.
    final along = -uz;
    var fx0 = -along * ux, fy0 = -along * uy, fz0 = -1 - along * uz;
    final fLength = sqrt(fx0 * fx0 + fy0 * fy0 + fz0 * fz0);
    // Camera pointing straight up or down: no forward direction.
    if (fLength < 0.2) return LidarScan.unknown;
    fx0 /= fLength;
    fy0 /= fLength;
    fz0 /= fLength;
    // side = up × forward
    final sx = uy * fz0 - uz * fy0;
    final sy = uz * fx0 - ux * fz0;
    final sz = ux * fy0 - uy * fx0;

    final heights = Float32List(n ~/ (step * step) + f.width + f.height);
    final forwards = Float32List(heights.length);
    final sides = Float32List(heights.length);
    var count = 0;
    var sampled = 0;
    for (var v = 0; v < f.height; v += step) {
      final yRay = -(v - f.cy) / f.fy;
      for (var u = 0; u < f.width; u += step) {
        sampled++;
        final i = v * f.width + u;
        final d = f.depth[i];
        if (f.confidence[i] == 0 || !(d > 0) || !d.isFinite) continue;
        final px = (u - f.cx) / f.fx * d;
        final py = yRay * d;
        final pz = -d;
        heights[count] = px * ux + py * uy + pz * uz;
        forwards[count] = px * fx0 + py * fy0 + pz * fz0;
        sides[count] = px * sx + py * sy + pz * sz;
        count++;
      }
    }
    if (count < sampled * minValidFraction) return LidarScan.unknown;

    _updateFloor(heights, count);
    final floor = _floor ?? defaultFloor;
    final low = floor + floorMargin;
    final left = <double>[], centre = <double>[], right = <double>[];
    final centreAt = <int>[];
    final centreSide = <double>[];
    var tooClose = 0;
    for (var i = 0; i < count; i++) {
      final forward = forwards[i];
      final height = heights[i];
      final side = sides[i];
      if (forward > maxForward || height < low || height > headroom) continue;
      if (forward < minForward) {
        if (side.abs() <= coreHalfWidth) tooClose++;
        continue;
      }
      if (side.abs() <= coreHalfWidth) {
        centre.add(forward);
        centreAt.add(i);
        centreSide.add(side);
      } else if (side > 0 && side <= sideOuter) {
        // up × forward in ARKit's right-handed camera frame points left.
        left.add(forward);
      } else if (side < 0 && side >= -sideOuter) {
        right.add(forward);
      }
    }
    final needed = (minPoints / (step * step)).ceil();
    var center = _frontal(centre, centreSide, needed);
    // Face against a wall every hit is nearer than minForward: that is not a
    // clear way ahead (it made the app say "Đi thẳng." into the wall).
    if (center is LidarClear && tooClose >= needed) center = const LidarUnknown();
    if (center is LidarObstacle) {
      SideState lane(double sign) {
        final d = center is LidarObstacle ? center.distance : 0.0;
        final end = max(d + lanePastObstacle, laneMinDepth);
        final bins = ((end - d) / laneBin).ceil();
        final floorCounts = List<int>.filled(bins * 2, 0);
        var obstacles = 0;
        for (var i = 0; i < count; i++) {
          final s = sign * sides[i];
          final forward = forwards[i];
          final height = heights[i];
          // An edge-grazer on the way there is in the path of a step aside;
          // the obstacle's own flank (its last 20 cm) is not.
          if (s > coreHalfWidth &&
              s <= halfWidth &&
              forward >= minForward &&
              forward < d - 0.2 &&
              height >= low &&
              height <= headroom) {
            obstacles++;
            continue;
          }
          // Anything seen on the way to the gap counts, not only beside the
          // obstacle; the floor is only checked where it is in view.
          if (s <= halfWidth ||
              s > laneOuter ||
              forward < minForward ||
              forward > end) {
            continue;
          }
          if (height >= low && height <= headroom) {
            obstacles++;
          } else if (forward >= d && (height - floor).abs() <= laneFloorBand) {
            final bin = min(((forward - d) / laneBin).floor(), bins - 1);
            floorCounts[bin * 2 + (s < laneSplit ? 0 : 1)]++;
          }
        }
        if (obstacles >= laneObstaclePoints) return SideState.blocked;
        // Nearest outer corner of the lane, on the floor, in camera space.
        final w = sign * laneOuter;
        final cx3 = fx0 * d + sx * w + ux * floor;
        final cy3 = fy0 * d + sy * w + uy * floor;
        final cz3 = fz0 * d + sz * w + uz * floor;
        if (cz3 >= 0) return SideState.unknown;
        final u = f.cx + f.fx * cx3 / -cz3;
        final v = f.cy - f.fy * cy3 / -cz3;
        if (u < 0 || u >= f.width || v < 0 || v >= f.height) {
          return SideState.unknown;
        }
        return floorCounts.every((c) => c >= laneFloorPoints)
            ? SideState.clear
            : SideState.unknown;
      }

      var sMin = double.infinity, sMax = -double.infinity;
      var hMin = double.infinity, hMax = -double.infinity;
      for (final i in centreAt) {
        if (forwards[i] > center.distance + frontDepth) continue;
        sMin = min(sMin, sides[i]);
        sMax = max(sMax, sides[i]);
        hMin = min(hMin, heights[i] - floor);
        hMax = max(hMax, heights[i] - floor);
      }
      // Positive `side` points left (see the corridor split above).
      final leftLane = lane(1), rightLane = lane(-1);
      center = LidarObstacle(
        center.distance,
        left: leftLane,
        right: rightLane,
        // Heights here are still above the floor; [headroom] is above the
        // phone, so the top check is relative to the phone again.
        wall:
            sMin <= -wallReach &&
            sMax >= wallReach &&
            hMin <= floorMargin + 0.3 &&
            hMax + floor >= headroom - 0.2 &&
            leftLane == SideState.blocked &&
            rightLane == SideState.blocked,
        where: (
          sideMin: sMin,
          sideMax: sMax,
          heightMin: hMin,
          heightMax: hMax,
          phoneHeight: -floor,
        ),
      );
    }
    return LidarScan(_nearest(left, needed), center, _nearest(right, needed));
  }

  /// Nearest obstacle ahead, skipping a surface the user walks along rather
  /// than into: a side wall seen at a slant (narrow aisle, phone held at an
  /// angle) fills neighbouring 10 cm strips at steadily growing distances.
  /// A pole, a chair or a wall facing the user does not.
  LidarReading _frontal(List<double> forward, List<double> side, int needed) {
    final strips = List.generate(centreStrips, (_) => <double>[]);
    for (var i = 0; i < forward.length; i++) {
      final s = ((side[i] + halfWidth) / (2 * halfWidth) * centreStrips)
          .floor()
          .clamp(0, centreStrips - 1);
      strips[s].add(forward[i]);
    }
    final near = [
      for (final hits in strips)
        switch (_nearest(hits, needed)) {
          LidarObstacle(:final distance) => distance,
          _ => null,
        },
    ];
    // Two steps in a row, both farther, together by more than 2 strips' worth
    // (the first step can be short where the image edge cuts the wall).
    bool slope(int s, int dir) {
      final a = s + dir, b = s + 2 * dir;
      if (b < 0 || b >= centreStrips) return false;
      final d0 = near[s]!, d1 = near[a], d2 = near[b];
      return d1 != null &&
          d2 != null &&
          d1 > d0 &&
          d2 > d1 &&
          d2 - d0 > 2 * grazingStep;
    }

    double? best;
    for (var s = 0; s < centreStrips; s++) {
      final d = near[s];
      if (d == null || slope(s, 1) || slope(s, -1)) continue;
      if (best == null || d < best) best = d;
    }
    return best == null ? const LidarClear() : LidarObstacle(best);
  }

  /// Distance of the [needed]-th nearest hit, or clear if there are fewer.
  LidarReading _nearest(List<double> hits, int needed) {
    if (hits.length < needed) return const LidarClear();
    hits.sort();
    return LidarObstacle(hits[needed - 1]);
  }

  void _updateFloor(Float32List heights, int count) {
    final bins = ((floorHighest - floorLowest) / floorBin).round();
    final counts = List<int>.filled(bins, 0);
    final sums = List<double>.filled(bins, 0);
    for (var i = 0; i < count; i++) {
      final h = heights[i];
      if (h < floorLowest || h >= floorHighest) continue;
      final b = ((h - floorLowest) / floorBin).floor().clamp(0, bins - 1);
      counts[b]++;
      sums[b] += h;
    }
    final needed = count * floorShare;
    // Pairs of neighbouring bins, so a floor on a bin edge is not split.
    for (var b = 0; b < bins; b++) {
      var c = counts[b], s = sums[b];
      if (b + 1 < bins) {
        c += counts[b + 1];
        s += sums[b + 1];
      }
      if (c > 0 && c >= needed) {
        final floor = s / c;
        _floor = _floor == null ? floor : _floor! * 0.8 + floor * 0.2;
        return;
      }
    }
  }
}

/// Smooths the side-lane states: saying "free" wrongly is worse than staying
/// silent, so `clear` needs [clearFrames] readings in a row while `blocked`
/// and `unknown` take effect at once.
class SideStability {
  static const clearFrames = 3;

  final _left = _SideTrack(), _right = _SideTrack();

  ({SideState left, SideState right}) update(LidarReading reading) =>
      reading is LidarObstacle
      ? updateSides(reading.left, reading.right)
      : updateSides(SideState.unknown, SideState.unknown);

  /// Raw per-reading side states from any source (MiDaS without LiDAR).
  ({SideState left, SideState right}) updateSides(
    SideState left,
    SideState right,
  ) => (left: _left.update(left), right: _right.update(right));

  void reset() {
    _left.update(SideState.unknown);
    _right.update(SideState.unknown);
  }
}

class _SideTrack {
  SideState _state = SideState.unknown;
  int _clearStreak = 0;

  SideState update(SideState next) {
    if (next != SideState.clear) {
      _clearStreak = 0;
      return _state = next;
    }
    _clearStreak++;
    if (_clearStreak >= SideStability.clearFrames) _state = SideState.clear;
    return _state;
  }
}

/// Remembers a side lane verified [SideState.clear] while approaching an obstacle:
/// closer than ~1.5 m, the side lanes leave the camera's field of view and turn
/// [SideState.unknown]. The latch preserves the previously seen clear lane so
/// the app can still tell the user to step aside.
///
/// Forgets when:
/// - That side reads [SideState.blocked].
/// - The centre path clears ([LidarClear]).
/// - Distance jumps away by more than 0.5 m (another obstacle).
///
/// [LidarUnknown] does not forget.
class SideLatch {
  SideState _left = SideState.unknown;
  SideState _right = SideState.unknown;
  double _minDistance = double.infinity;

  ({SideState left, SideState right}) update(
    LidarReading centre,
    ({SideState left, SideState right}) sides,
  ) {
    switch (centre) {
      case LidarClear():
        _left = SideState.unknown;
        _right = SideState.unknown;
        _minDistance = double.infinity;
      case LidarObstacle(:final distance):
        if (distance > _minDistance + 0.5) {
          _left = SideState.unknown;
          _right = SideState.unknown;
          _minDistance = distance;
        } else {
          _minDistance = min(_minDistance, distance);
        }
      case LidarUnknown():
        break;
    }

    _left = switch (sides.left) {
      SideState.clear => SideState.clear,
      SideState.blocked => SideState.unknown,
      SideState.unknown => _left,
    };
    final resolvedLeft =
        sides.left == SideState.unknown && _left == SideState.clear
            ? SideState.clear
            : sides.left;

    _right = switch (sides.right) {
      SideState.clear => SideState.clear,
      SideState.blocked => SideState.unknown,
      SideState.unknown => _right,
    };
    final resolvedRight =
        sides.right == SideState.unknown && _right == SideState.clear
            ? SideState.clear
            : sides.right;

    return (left: resolvedLeft, right: resolvedRight);
  }

  void reset() {
    _left = SideState.unknown;
    _right = SideState.unknown;
    _minDistance = double.infinity;
  }
}

/// Latches the "facing a wall" verdict: at far distances (1–4 m) the LiDAR
/// sees the floor and ceiling around the obstacle to classify it as a wall.
/// Up close (under ~0.8 m), the ceiling and floor leave the frame so [wall]
/// turns false even though the user is still walking straight into that wall.
///
/// The latch resets when the corridor clears, or when distance jumps away
/// by more than 0.5 m (user turned away or looked at another obstacle).
/// [LidarUnknown] preserves the latch (pressing against a wall reads unknown).
class WallLatch {
  bool _on = false;
  double _at = double.infinity;

  bool update(LidarReading centre) {
    switch (centre) {
      case LidarObstacle(:final wall, :final distance):
        if (wall) {
          _on = true;
          _at = distance;
        } else if (_on) {
          if (distance > _at + 0.5) {
            _on = false;
          } else {
            _at = min(_at, distance);
          }
        }
      case LidarClear():
        _on = false;
      case LidarUnknown():
        break;
    }
    return _on;
  }

  void reset() {
    _on = false;
    _at = double.infinity;
  }
}

/// Metric warning levels with hysteresis, so standing near a threshold does
/// not flip the alert every frame. As with MiDaS, two consecutive
/// non-info readings (DepthWarning) are needed before warning.
class LidarWarning {
  static const cautionEnter = 2.0;
  static const cautionExit = 2.2;
  static const dangerEnter = 1.0;
  static const dangerExit = 1.2;

  static const wallDangerEnter = 0.5;
  static const wallDangerExit = 0.6;

  /// From here out to [cautionExit], caution needs the obstacle getting
  /// closer (the user walking towards it): standing still 1.5–2 m away is
  /// not warned. The warning starts that far out only because the side
  /// lanes ("Đi chéo phải/trái") are fully in view from ~1.5 m.
  static const cautionAlways = 1.5;
  static const approachMetres = 0.15;
  static const approachWindow = Duration(seconds: 1);

  AlertLevel _raw = AlertLevel.info;
  int _streak = 0;
  final _recent = <({DateTime at, double d})>[];

  AlertLevel update(LidarReading reading, DateTime now, {bool wall = false}) {
    // One unreadable frame neither raises nor clears the warning; a lasting
    // gap is announced by the sight monitor instead.
    if (reading is LidarUnknown) return AlertLevel.info;
    final d = reading is LidarObstacle ? reading.distance : double.infinity;
    if (wall) {
      _raw = d < wallDangerEnter || (_raw == AlertLevel.danger && d <= wallDangerExit)
          ? AlertLevel.danger
          : AlertLevel.info;
    } else {
      _recent.removeWhere((r) => now.difference(r.at) > approachWindow);
      final approaching = _recent.any((r) => r.d - d >= approachMetres);
      // Clear counts as the far end of the range: something stepping into
      // the corridor is approaching.
      _recent.add((at: now, d: min(d, LidarAnalysis.maxForward)));
      _raw = d < dangerEnter || (_raw == AlertLevel.danger && d <= dangerExit)
          ? AlertLevel.danger
          : d < cautionEnter || (_raw != AlertLevel.info && d <= cautionExit)
          ? AlertLevel.caution
          : AlertLevel.info;
      if (_raw == AlertLevel.caution && d >= cautionAlways && !approaching) {
        _raw = AlertLevel.info;
      }
    }
    _streak = _raw == AlertLevel.info ? 0 : _streak + 1;
    return _streak >= 2 ? _raw : AlertLevel.info;
  }

  void reset() {
    _raw = AlertLevel.info;
    _streak = 0;
    _recent.clear();
  }
}
