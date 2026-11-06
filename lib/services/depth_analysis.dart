import 'dart:typed_data';

import '../models/scene_info.dart';

/// Relative closeness of the left/centre/right path at chest height.
/// 1.0 means "as close as the floor just ahead of the user's feet"; 0 means
/// as far as the farthest part of the view. Not metres.
class DepthReading {
  const DepthReading(this.left, this.center, this.right);
  final double left;
  final double center;
  final double right;
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

    return DepthReading(closeness(0), closeness(1), closeness(2));
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
