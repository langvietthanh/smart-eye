import 'dart:math';
import 'dart:ui';

import '../models/scene_info.dart';
import 'lidar_analysis.dart';

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

  /// Normalised row; a box must reach below it to be in the way.
  static const walkingRegionTop = 0.55;

  static bool reachesWalkingRegion(Rect box, Size frame) =>
      frame.width > 0 &&
      frame.height > 0 &&
      box.bottom >= frame.height * walkingRegionTop;

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

/// The walking corridor in the image, drawn like car reversing guides: the
/// floor strip [LidarAnalysis.halfWidth] each side of the camera axis (the
/// same 70 cm as LiDAR), narrowing towards the horizon. Coordinates are
/// normalised to the frame (0..1, row 0 at the top).
class PathCorridor {
  const PathCorridor(this.horizonY, this.perMetre);

  /// Row where the guides meet.
  final double horizonY;

  /// Half-width (share of frame width) per metre of real half-width, per
  /// unit of row below [horizonY].
  final double perMetre;

  /// Assumed phone height above the floor (chest hold), metres.
  static const phoneHeight = 1.3;
  static const typicalPitch = 15.0;

  /// Main cameras are 4:3 with ~62° across the long side.
  static const _longHalfFov = 31.0, _shortHalfFov = 24.2;

  static final typical = PathCorridor.forPitch(null, portrait: true);

  /// [pitchDeg]: camera axis below the horizon (accelerometer), null when
  /// unknown. Flat floor and pinhole camera: a floor point [a] metres off
  /// the axis is `a / phoneHeight · cos(pitch)` rows-widths from the centre
  /// per row below the horizon.
  factory PathCorridor.forPitch(double? pitchDeg, {required bool portrait}) {
    final t = (pitchDeg ?? typicalPitch).clamp(-30.0, 70.0) * pi / 180;
    final halfFov = (portrait ? _longHalfFov : _shortHalfFov) * pi / 180;
    final rowsPerColumn = portrait ? 4 / 3 : 3 / 4;
    return PathCorridor(
      0.5 - 0.5 * tan(t) / tan(halfFov),
      cos(t) * rowsPerColumn / phoneHeight,
    );
  }

  /// Normalised x span of a strip [halfMetres] each side of the axis at row
  /// [y].
  (double, double) span(double y, double halfMetres) {
    final half = max(0.0, y - horizonY) * perMetre * halfMetres;
    return (0.5 - half, 0.5 + half);
  }

  /// Spans at the box's bottom row, where a standing object meets the floor.
  (double, double) _at(Rect box, Size frame, double halfMetres) =>
      span(box.bottom / frame.height, halfMetres);

  /// In the walking region and into the corridor core: an object only
  /// grazing the outer edge (a table corner) is not in the way.
  bool contains(Rect box, Size frame) {
    if (!VisualProximity.reachesWalkingRegion(box, frame)) return false;
    final (l, r) = _at(box, frame, LidarAnalysis.coreHalfWidth);
    return box.left / frame.width < r && box.right / frame.width > l;
  }

  /// Box centre left of, inside or right of the core at its bottom row.
  HPos posOf(Rect box, Size frame) {
    final (l, r) = _at(box, frame, LidarAnalysis.coreHalfWidth);
    final cx = box.center.dx / frame.width;
    return cx < l
        ? HPos.left
        : cx > r
        ? HPos.right
        : HPos.center;
  }

  /// Share of the frame width the box covers left and right of the outer
  /// corridor at its bottom row.
  (double, double) sides(Rect box, Size frame) {
    final (l, r) = _at(box, frame, LidarAnalysis.halfWidth);
    final left = box.left / frame.width, right = box.right / frame.width;
    return (max(0.0, min(right, l) - left), max(0.0, right - max(left, r)));
  }

  @override
  bool operator ==(Object other) =>
      other is PathCorridor &&
      other.horizonY == horizonY &&
      other.perMetre == perMetre;

  @override
  int get hashCode => Object.hash(horizonY, perMetre);
}
