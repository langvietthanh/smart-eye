import 'dart:math';
import 'dart:ui';

import '../models/scene_info.dart';
import '../models/tracked_object.dart';
import '../utils/label_catalog.dart';
import 'lidar_analysis.dart';
import 'visual_proximity.dart';

/// Relative visual risk. Bounding boxes cannot measure metres or prove that an
/// undetected part of the scene is safe to walk through.
class HazardEngine {
  static const double nearEnter = VisualProximity.nearEnter;
  static const double nearExit = VisualProximity.nearExit;
  static const double mediumEnter = VisualProximity.mediumEnter;
  static const double mediumExit = VisualProximity.mediumExit;
  static const double approachGrowth = 1.18;
  static const double _predictionSeconds = 0.8;

  /// [targetTrackId] is the object the user is being guided to: it is not
  /// warned about unless it is a real danger (ground hazard, vehicle, or a
  /// person/animal approaching). Objects and column load are unaffected.
  /// [lidar]: a fresh LiDAR scan (iPhone Pro) that checks the warning level
  /// in metres, see [lidarCapped].
  SceneAssessment assess(
    List<TrackedObject> tracks,
    Size frame, {
    int? targetTrackId,
    LidarScan? lidar,
  }) {
    if (frame.width <= 0 || frame.height <= 0) return SceneAssessment.empty;
    final objects = tracks.map((track) => _describe(track, frame)).toList();
    return SceneAssessment(
      objects: objects,
      columnLoad: _columnLoad(objects, frame),
      alert: _decide(objects, frame, targetTrackId, lidar),
    );
  }

  /// Box size is not distance: a chair 2–3 m away can read "khá gần". With
  /// LiDAR the level is capped by the nearest obstacle it measures on the
  /// object's side or ahead: none within [LidarWarning.cautionExit] → no
  /// warning, none within [LidarWarning.dangerExit] → at most caution.
  /// Unchanged where LiDAR cannot vouch: no reading, ground hazards (below
  /// its floor band), vehicles and anything approaching (it may close in).
  static AlertLevel lidarCapped(
    AlertLevel level,
    ObjectInfo object,
    LidarScan? lidar,
  ) {
    if (lidar == null ||
        level == AlertLevel.info ||
        object.approaching ||
        object.category == ObjectCategory.groundHazard ||
        object.category == ObjectCategory.vehicle) {
      return level;
    }
    var nearest = double.infinity;
    for (final reading in {lidar[object.pos], lidar.center}) {
      if (reading is LidarUnknown) return level;
      if (reading is LidarObstacle) nearest = min(nearest, reading.distance);
    }
    if (nearest > LidarWarning.cautionExit) return AlertLevel.info;
    if (nearest > LidarWarning.dangerExit && level == AlertLevel.danger) {
      return AlertLevel.caution;
    }
    return level;
  }

  ObjectInfo _describe(TrackedObject track, Size frame) {
    final ratio = VisualProximity.occupancy(track.observedBox, frame);
    final distance = distanceWithHysteresis(track.distanceLevel, ratio);
    track.distanceLevel = distance;
    final category = categoryOf(track.labelEn);
    // Includes the user approaching a stationary obstacle. Growth in the image
    // does not identify which object is moving in the physical world.
    final approaching =
        track.misses == 0 &&
        category != ObjectCategory.other &&
        track.growth >= approachGrowth &&
        track.occupancyGrowthPerSecond >= 0.06;
    return ObjectInfo(
      track: track,
      pos: hPosOf(track.observedBox, frame),
      distance: distance,
      category: category,
      approaching: approaching,
      // Forecast crossing an image-occupancy threshold, not a collision time.
      closingQuickly:
          approaching &&
          distance != DistanceLevel.far &&
          ratio + track.occupancyGrowthPerSecond * _predictionSeconds >=
              nearEnter,
    );
  }

  static HPos hPosOf(Rect box, Size frame) {
    final cx = box.center.dx / frame.width;
    if (cx < 1 / 3) return HPos.left;
    if (cx > 2 / 3) return HPos.right;
    return HPos.center;
  }

  static DistanceLevel distanceWithHysteresis(
    DistanceLevel? prev,
    double ratio,
  ) => VisualProximity.level(prev, ratio);

  List<double> _columnLoad(List<ObjectInfo> objects, Size frame) {
    final load = [0.0, 0.0, 0.0];
    final colW = frame.width / 3;
    for (final object in objects) {
      if (!object.isRelevant ||
          object.track.misses != 0 ||
          !VisualProximity.reachesWalkingRegion(
            object.track.observedBox,
            frame,
          ) ||
          object.distance == DistanceLevel.far) {
        continue;
      }
      final weight = object.distance == DistanceLevel.near ? 2.0 : 1.0;
      for (int col = 0; col < 3; col++) {
        final box = object.track.observedBox;
        final overlap = max(
          0.0,
          min(box.right, (col + 1) * colW) - max(box.left, col * colW),
        );
        if (overlap >= 0.25 * colW) load[col] += weight;
      }
    }
    return load;
  }

  static bool _isSkippedTarget(ObjectInfo object, int? targetTrackId) {
    if (targetTrackId == null || object.track.id != targetTrackId) return false;
    switch (object.category) {
      case ObjectCategory.groundHazard:
      case ObjectCategory.vehicle:
        return false;
      case ObjectCategory.person:
      case ObjectCategory.animal:
        return !object.approaching;
      case ObjectCategory.obstacle:
      case ObjectCategory.other:
        return true;
    }
  }

  HazardAlert? _decide(
    List<ObjectInfo> objects,
    Size frame,
    int? targetTrackId,
    LidarScan? lidar,
  ) {
    ({ObjectInfo object, AlertLevel level, bool inPath})? best;
    for (final object in objects) {
      if (_isSkippedTarget(object, targetTrackId)) continue;
      // Keep briefly occluded tracks for display, but never dispatch a new
      // warning from a box absent in the current observation.
      if (!object.isRelevant || object.track.misses != 0) continue;
      final inPath = VisualProximity.inPath(object.track.observedBox, frame);
      final level = lidarCapped(_levelOf(object, inPath), object, lidar);
      if (level == AlertLevel.info) continue;
      if (best == null ||
          _rank(object, level, inPath) >
              _rank(best.object, best.level, best.inPath)) {
        best = (object: object, level: level, inPath: inPath);
      }
    }
    if (best == null) return null;
    return HazardAlert(
      level: best.level,
      guidance: best.level == AlertLevel.danger
          ? Guidance.stop
          : Guidance.slowDown,
      subject: 'track:${best.object.track.id}',
      pos: best.object.pos,
      message: _message(best.object, best.level, best.inPath),
    );
  }

  AlertLevel _levelOf(ObjectInfo object, bool inPath) {
    final near = object.distance == DistanceLevel.near;
    final medium = object.distance == DistanceLevel.medium;
    if (object.category == ObjectCategory.other) return AlertLevel.info;
    if (object.category == ObjectCategory.groundHazard) {
      if (!inPath) return near ? AlertLevel.caution : AlertLevel.info;
      // Mép vỉa hè gặp liên tục → chỉ nhắc chú ý khi đã tới gần, không hô "Dừng lại".
      if (mildGroundHazards.contains(object.track.labelEn)) {
        return object.distance == DistanceLevel.far
            ? AlertLevel.info
            : AlertLevel.caution;
      }
      // Far away there is time: warn once it reaches medium distance.
      return object.distance == DistanceLevel.far
          ? AlertLevel.info
          : AlertLevel.danger;
    }
    if (inPath) {
      if (near || object.closingQuickly) return AlertLevel.danger;
      // A far object grows in the image just because the user walks up to
      // it; only a vehicle is fast enough to warn about while still far.
      if (medium ||
          (object.approaching && object.category == ObjectCategory.vehicle)) {
        return AlertLevel.caution;
      }
    } else if (object.category == ObjectCategory.vehicle &&
        (near || object.approaching)) {
      return AlertLevel.caution;
    }
    return AlertLevel.info;
  }

  static const _categoryRank = {
    ObjectCategory.groundHazard: 5,
    ObjectCategory.vehicle: 4,
    ObjectCategory.obstacle: 3,
    ObjectCategory.animal: 2,
    ObjectCategory.person: 1,
    ObjectCategory.other: 0,
  };

  int _rank(ObjectInfo object, AlertLevel level, bool inPath) =>
      level.index * 1000 +
      (inPath ? 100 : 0) +
      _categoryRank[object.category]! * 10 +
      (2 - object.distance.index);

  String _message(ObjectInfo object, AlertLevel level, bool inPath) {
    final where = inPath
        ? switch (object.pos) {
            HPos.center => 'ngay phía trước',
            HPos.left => 'bên trái',
            HPos.right => 'bên phải',
          }
        : object.pos.vi;
    final canMove =
        object.category == ObjectCategory.vehicle ||
        object.category == ObjectCategory.person ||
        object.category == ObjectCategory.animal;
    final isApproaching = object.approaching && canMove;

    if (level == AlertLevel.danger) {
      return 'Dừng lại! Có ${object.label} $where.';
    }
    if (isApproaching) {
      return 'Chậm lại. ${capitalize(object.label)} $where đang tới gần.';
    }
    return 'Chậm lại. Có ${object.label} $where.';
  }
}
