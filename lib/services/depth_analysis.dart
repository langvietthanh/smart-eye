import 'dart:math';
import 'dart:typed_data';

import '../models/scene_info.dart';

/// Relative closeness of the left/centre/right path at chest height.
/// 1.0 means "as close as the floor just ahead of the user's feet"; 0 means
/// as far as the farthest part of the view. Not metres.
class DepthReading {
  const DepthReading(this.left, this.center, this.right, {this.step});
  final double left;
  final double center;
  final double right;

  /// A floor-level step ahead, if the floor profile shows one.
  final StepReading? step;
}

enum StepKind { up, down }

class StepReading {
  const StepReading(this.kind, this.row);
  final StepKind kind;

  /// Image row of the edge, 0 = top, 1 = bottom. Lower rows are closer to
  /// the feet; this is not a distance in metres.
  final double row;

  bool get near => row >= DepthAnalysis.stepNearRow;
}

/// Turns a relative inverse-depth map (MiDaS: larger = closer, unknown scale
/// and shift per frame) into class-agnostic obstacle closeness, so walls,
/// doors and boxes that the object detector cannot name are still noticed.
///
/// The floor near the bottom of the image is used as the per-frame reference:
/// with the phone held at chest height and tilted slightly down, an open path
/// is much farther than that floor patch, while an obstacle in front is about
/// as close. Thresholds are heuristics and need field calibration.
class DepthAnalysis {
  static const bandTop = 0.35;
  static const bandBottom = 0.70;
  static const floorTop = 0.88;
  static const caution = 0.75;
  static const danger = 0.90;

  // Step detection (see [detectStep]), as fractions of the image height.
  // Simulated geometry (phone at 1.3 m, tilted 20° down, 60° vertical FOV,
  // 18 cm step) gives an offset of ~0.046 at 3 m, ~0.068 at 2 m and ~0.085
  // at 1.5 m; a 10 cm step at 2 m (~0.037) is missed. Row ≥ 0.75 is roughly
  // 1.5 m at that tilt, nearer when tilted further down. Needs field data.
  static const profileTop = 0.30;
  static const floorFitRows = 0.12;
  static const edgeTolerance = 0.015;
  static const maxRiserRows = 0.10;
  static const planeRows = 0.06;
  static const minJump = 0.04;
  static const stepNearRow = 0.75;
  static const _window = 4;

  /// [depth] is row-major [width]×[height], already upright.
  static DepthReading? analyze(Float32List depth, int width, int height) {
    if (width < 6 || height < 10 || depth.length < width * height) return null;
    List<double> region(int x0, int x1, int y0, int y1) => [
      for (int y = y0; y < y1; y += 2)
        for (int x = x0; x < x1; x += 2) depth[y * width + x],
    ];

    final far = percentile(region(0, width, 0, height), 0.05);
    final floor = percentile(
      region(width ~/ 3, 2 * width ~/ 3, (height * floorTop).round(), height),
      0.5,
    );
    if (!far.isFinite || !floor.isFinite) return null;
    final range = floor - far;
    // Almost uniform depth: one surface (e.g. a wall) fills the whole view.
    final uniform = range <= floor.abs() * 0.1;
    final top = (height * bandTop).round();
    final bottom = (height * bandBottom).round();
    double closeness(int column) {
      if (uniform) return 1.0;
      // 75th percentile: an obstacle covering a quarter of the band counts.
      final value = percentile(
        region(column * width ~/ 3, (column + 1) * width ~/ 3, top, bottom),
        0.75,
      );
      return ((value - far) / range).clamp(0.0, 1.0);
    }

    return DepthReading(
      closeness(0),
      closeness(1),
      closeness(2),
      step: uniform ? null : detectStep(depth, width, height),
    );
  }

  /// Inverse depth of a plane is linear in the image row, and MiDaS's unknown
  /// scale/shift keeps it linear. Walking up the centre-column profile from
  /// the floor at the user's feet:
  /// 1. fit the floor line and follow it until the profile leaves it;
  /// 2. skip a short vertical face (a riser: depth stops receding);
  /// 3. if what follows is again a horizontal plane (similar slope), it is a
  ///    step: offset *closer* than the floor line = step up, *farther* =
  ///    step down / edge.
  /// A long vertical face is a wall or obstacle, left to the obstacle check;
  /// a wall far behind a platform does not hide the step.
  static StepReading? detectStep(Float32List depth, int width, int height) {
    final top = (height * profileTop).round();
    final x0 = (width * 0.4).round();
    final x1 = (width * 0.6).round();
    final n = height - top;
    final floorRows = (height * floorFitRows).round();
    final segment = (height * planeRows).round();
    if (x1 <= x0 ||
        floorRows < 3 ||
        segment < 3 ||
        n < floorRows + segment + 2 * _window ||
        depth.length < width * height) {
      return null;
    }
    // q[u]: median of the centre strip; u = 0 is the bottom row, going up.
    final q = Float64List(n);
    for (int u = 0; u < n; u++) {
      final row = (height - 1 - u) * width;
      final v = percentile([for (int x = x0; x < x1; x++) depth[row + x]], 0.5);
      if (!v.isFinite) return null;
      q[u] = v;
    }
    ({double slope, double intercept}) fit(int a, int b) {
      double k = 0, t = 0, tt = 0, p = 0, tp = 0;
      for (int u = a; u < b; u++) {
        k++;
        t += u;
        tt += u * u;
        p += q[u];
        tp += u * q[u];
      }
      final denominator = k * tt - t * t;
      final slope = denominator == 0 ? 0.0 : (k * tp - t * p) / denominator;
      return (slope: slope, intercept: (p - slope * t) / k);
    }

    double offsetAt(({double slope, double intercept}) line, int u) =>
        q[u] - (line.intercept + line.slope * u);

    var floor = fit(0, floorRows);
    if (floor.slope >= 0) return null; // The floor must recede going up.
    final tolerance = edgeTolerance * -floor.slope * height;
    int? edge;
    for (int u = floorRows, out = 0; u < n; u++) {
      if (offsetAt(floor, u).abs() > tolerance) {
        if (++out >= 3) {
          edge = u - 2;
          break;
        }
      } else {
        out = 0;
      }
    }
    if (edge == null) return null; // One flat floor as far as can be seen.
    floor = fit(0, edge);
    if (floor.slope >= 0) return null;

    // A vertical face stops receding (inverse depth even rises slightly).
    var u = edge;
    while (u + _window < n) {
      final from = max(u - _window, 0);
      final local = (q[u + _window] - q[from]) / (u + _window - from);
      if (local <= 0.4 * floor.slope) break;
      u++;
    }
    if (u - edge >= maxRiserRows * height || u + _window >= n) return null;
    if (n - u < segment) return null;
    final plane = fit(u, u + segment);
    final ratio = plane.slope / floor.slope;
    if (ratio < 0.5 || ratio > 2) return null;
    double offset = 0;
    for (int i = u; i < u + segment; i++) {
      offset += offsetAt(floor, i);
    }
    offset /= segment * -floor.slope * height;
    final row = (height - 1 - edge) / height;
    if (offset >= minJump) return StepReading(StepKind.up, row);
    if (offset <= -minJump) return StepReading(StepKind.down, row);
    return null;
  }

  /// Sorts [values] in place.
  static double percentile(List<double> values, double p) {
    if (values.isEmpty) return double.nan;
    values.sort();
    return values[((values.length - 1) * p).round()];
  }
}

/// Requires two consecutive non-info readings before warning, to ride out
/// single-frame depth noise.
class DepthWarning {
  int _streak = 0;

  AlertLevel update(double closeness) {
    final level = closeness >= DepthAnalysis.danger
        ? AlertLevel.danger
        : closeness >= DepthAnalysis.caution
        ? AlertLevel.caution
        : AlertLevel.info;
    _streak = level == AlertLevel.info ? 0 : _streak + 1;
    return _streak >= 2 ? level : AlertLevel.info;
  }

  void reset() => _streak = 0;
}

/// Same two-reading confirmation for steps; the kind must also agree.
class StepWarning {
  StepKind? _kind;
  int _streak = 0;

  /// Danger for any step down or a near step up, caution for a farther step
  /// up; null until two consecutive readings agree on the kind.
  ({StepKind kind, AlertLevel level})? update(StepReading? step) {
    if (step == null) {
      reset();
      return null;
    }
    _streak = step.kind == _kind ? _streak + 1 : 1;
    _kind = step.kind;
    if (_streak < 2) return null;
    final danger = step.kind == StepKind.down || step.near;
    return (
      kind: step.kind,
      level: danger ? AlertLevel.danger : AlertLevel.caution,
    );
  }

  void reset() {
    _kind = null;
    _streak = 0;
  }
}
