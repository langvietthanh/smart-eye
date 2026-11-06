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
  const LidarObstacle(this.distance);

  /// Horizontal distance to the nearest substantial obstacle, metres.
  final double distance;
}

/// Not enough trustworthy depth to say anything.
class LidarUnknown extends LidarReading {
  const LidarUnknown();
}

/// Metric, class-agnostic obstacle detection: depth pixels become 3D points
/// in a gravity-aligned frame (independent of how the phone is tilted or
/// rotated), the floor is estimated and removed, and the nearest substantial
/// cluster inside a body-width "virtual corridor" ahead is reported.
class LidarAnalysis {
  /// Half the corridor width: shoulders plus margin. A 0.8 m door fits.
  static const halfWidth = 0.35;

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

  LidarReading analyze(LidarDepthFrame f) {
    final n = f.width * f.height;
    if (!f.trackingAvailable ||
        f.width < 8 ||
        f.height < 8 ||
        f.depth.length < n ||
        f.confidence.length < n) {
      return const LidarUnknown();
    }
    final upLength = sqrt(f.upX * f.upX + f.upY * f.upY + f.upZ * f.upZ);
    if (upLength < 1e-6) return const LidarUnknown();
    final ux = f.upX / upLength, uy = f.upY / upLength, uz = f.upZ / upLength;
    // Viewing direction (0,0,-1) projected onto the horizontal plane.
    final along = -uz;
    var fx0 = -along * ux, fy0 = -along * uy, fz0 = -1 - along * uz;
    final fLength = sqrt(fx0 * fx0 + fy0 * fy0 + fz0 * fz0);
    // Camera pointing straight up or down: no forward direction.
    if (fLength < 0.2) return const LidarUnknown();
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
    if (count < sampled * minValidFraction) return const LidarUnknown();

    _updateFloor(heights, count);
    final floor = _floor ?? defaultFloor;
    final low = floor + floorMargin;
    final hits = <double>[];
    for (var i = 0; i < count; i++) {
      final forward = forwards[i];
      final height = heights[i];
      if (forward >= minForward &&
          forward <= maxForward &&
          sides[i].abs() <= halfWidth &&
          height >= low &&
          height <= headroom) {
        hits.add(forward);
      }
    }
    final needed = (minPoints / (step * step)).ceil();
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

/// Metric warning levels with hysteresis, so standing near a threshold does
/// not flip the alert every frame. As with MiDaS, two consecutive
/// non-info readings (DepthWarning) are needed before warning.
class LidarWarning {
  static const cautionEnter = 2.0;
  static const cautionExit = 2.2;
  static const dangerEnter = 1.0;
  static const dangerExit = 1.2;

  AlertLevel _raw = AlertLevel.info;
  int _streak = 0;

  AlertLevel update(LidarReading reading) {
    // One unreadable frame neither raises nor clears the warning; a lasting
    // gap is announced by the sight monitor instead.
    if (reading is LidarUnknown) return AlertLevel.info;
    final d = reading is LidarObstacle ? reading.distance : double.infinity;
    _raw = d < dangerEnter || (_raw == AlertLevel.danger && d <= dangerExit)
        ? AlertLevel.danger
        : d < cautionEnter || (_raw != AlertLevel.info && d <= cautionExit)
        ? AlertLevel.caution
        : AlertLevel.info;
    _streak = _raw == AlertLevel.info ? 0 : _streak + 1;
    return _streak >= 2 ? _raw : AlertLevel.info;
  }

  void reset() {
    _raw = AlertLevel.info;
    _streak = 0;
  }
}
