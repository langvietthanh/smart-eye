import 'dart:math';
import 'dart:ui';

import '../models/scene_info.dart';

/// Relative image occupancy, never a measurement in metres. Thresholds are
/// conservative warning heuristics and need validation for each camera/device.
class VisualProximity {
  static const nearEnter = 0.45;
  static const nearExit = 0.39;
  static const mediumEnter = 0.20;
  static const mediumExit = 0.16;

  /// Size-only history avoids inventing approach when an unchanged box moves
  /// across the lower-image gate used by the proximity heuristic.
  static double sizeRatio(Rect box, Size frame) {
    if (frame.width <= 0 || frame.height <= 0) return 0;
    return max(
      (box.height / frame.height).clamp(0.0, 1.0),
      (box.width / frame.width).clamp(0.0, 1.0) * 0.8,
    );
  }

  static bool reachesWalkingRegion(Rect box, Size frame) =>
      frame.width > 0 && frame.height > 0 && box.bottom >= frame.height * 0.55;

  static double occupancy(Rect box, Size frame) {
    if (frame.width <= 0 || frame.height <= 0) return 0;
    final height = (box.height / frame.height).clamp(0.0, 1.0);
    // Low, wide objects near the bottom of the image (e.g. a table edge) must
    // not be treated as distant solely because their boxes are short.
    final groundWidth = box.bottom >= frame.height * 0.75
        ? (box.width / frame.width).clamp(0.0, 1.0) * 0.8
        : 0.0;
    return max(height, groundWidth);
  }

  static bool inPath(Rect box, Size frame) {
    if (!reachesWalkingRegion(box, frame)) return false;
    final col = frame.width / 3;
    final overlap = max(0.0, min(box.right, 2 * col) - max(box.left, col));
    return (box.center.dx >= col && box.center.dx <= 2 * col) ||
        overlap >= col * 0.4;
  }

  static DistanceLevel level(DistanceLevel? previous, double occupancy) {
    final near = previous == DistanceLevel.near ? nearExit : nearEnter;
    final medium =
        previous == DistanceLevel.near || previous == DistanceLevel.medium
        ? mediumExit
        : mediumEnter;
    if (occupancy >= near) return DistanceLevel.near;
    if (occupancy >= medium) return DistanceLevel.medium;
    return DistanceLevel.far;
  }
}
