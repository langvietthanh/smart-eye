import 'dart:math';
import 'dart:ui';

import '../models/scene_info.dart';
import '../models/tracked_object.dart';
import '../utils/label_catalog.dart';

/// F2 — Rules engine (CN4) + Free-space 3 cột (CN6) + Khoảng cách theo % box (CN7).
///
/// Nguyên tắc an toàn:
/// - Mỗi frame chỉ chọn ĐÚNG 1 cảnh báo quan trọng nhất ("nói ít, đúng lúc").
/// - Khi vật rất gần ngay trước mặt → luôn nói "Dừng lại" trước, chỉ gợi ý hướng
///   khi phía đó thật sự trống (ưu tiên dừng lại hơn chỉ sai hướng).
class HazardEngine {
  // CN7 — ngưỡng % chiều cao box / khung, có vùng trễ (hysteresis) để không nhảy mức
  static const double nearEnter = 0.60;
  static const double nearExit = 0.52;
  static const double mediumEnter = 0.30;
  static const double mediumExit = 0.25;

  /// Box to thêm ≥ 25% trong ~1–2 giây → coi là đang tới gần
  static const double approachGrowth = 1.25;

  /// Vật chiếm ≥ 40% bề rộng cột giữa → coi là nằm trên lối đi
  static const double _pathOverlap = 0.4;

  SceneAssessment assess(List<TrackedObject> tracks, Size frame) {
    if (frame.width <= 0 || frame.height <= 0) return SceneAssessment.empty;

    final objects = tracks.map((t) => _describe(t, frame)).toList();
    final load = _columnLoad(objects, frame);
    final alert = _decide(objects, load, frame);
    return SceneAssessment(objects: objects, columnLoad: load, alert: alert);
  }

  // ---------------------------------------------------------------------------
  // Mô tả từng vật
  // ---------------------------------------------------------------------------

  ObjectInfo _describe(TrackedObject t, Size frame) {
    final ratio = t.box.height / frame.height;
    final distance = distanceWithHysteresis(t.distanceLevel, ratio);
    t.distanceLevel = distance;

    final category = categoryOf(t.labelEn);
    final canApproach = category == ObjectCategory.vehicle ||
        category == ObjectCategory.animal ||
        category == ObjectCategory.person;

    return ObjectInfo(
      track: t,
      pos: hPosOf(t.box, frame),
      distance: distance,
      category: category,
      approaching: canApproach && distance != DistanceLevel.far && t.growth >= approachGrowth,
    );
  }

  static HPos hPosOf(Rect box, Size frame) {
    final cx = box.center.dx / frame.width;
    if (cx < 1 / 3) return HPos.left;
    if (cx > 2 / 3) return HPos.right;
    return HPos.center;
  }

  static DistanceLevel distanceWithHysteresis(DistanceLevel? prev, double ratio) {
    final nearT = prev == DistanceLevel.near ? nearExit : nearEnter;
    final mediumT = (prev == DistanceLevel.near || prev == DistanceLevel.medium) ? mediumExit : mediumEnter;
    if (ratio >= nearT) return DistanceLevel.near;
    if (ratio >= mediumT) return DistanceLevel.medium;
    return DistanceLevel.far;
  }

  // ---------------------------------------------------------------------------
  // CN6 — Free-space: chia 3 cột, cộng trọng số vật cản gần/vừa
  // ---------------------------------------------------------------------------

  List<double> _columnLoad(List<ObjectInfo> objects, Size frame) {
    final load = [0.0, 0.0, 0.0];
    final colW = frame.width / 3;
    for (final o in objects) {
      if (!o.isRelevant || o.distance == DistanceLevel.far) continue;
      final weight = o.distance == DistanceLevel.near ? 2.0 : 1.0;
      for (int c = 0; c < 3; c++) {
        if (_overlapWidth(o.track.box, c * colW, (c + 1) * colW) >= 0.25 * colW) {
          load[c] += weight;
        }
      }
    }
    return load;
  }

  static double _overlapWidth(Rect box, double l, double r) =>
      max(0.0, min(box.right, r) - max(box.left, l));

  bool _inPath(ObjectInfo o, Size frame) {
    final colW = frame.width / 3;
    return o.pos == HPos.center || _overlapWidth(o.track.box, colW, 2 * colW) >= _pathOverlap * colW;
  }

  // ---------------------------------------------------------------------------
  // CN4 — Rules: chọn 1 cảnh báo quan trọng nhất
  // ---------------------------------------------------------------------------

  HazardAlert? _decide(List<ObjectInfo> objects, List<double> load, Size frame) {
    ({ObjectInfo obj, AlertLevel level, bool inPath})? best;

    for (final o in objects) {
      if (!o.isRelevant) continue;
      final inPath = _inPath(o, frame);
      final level = _levelOf(o, inPath);
      if (level == AlertLevel.info) continue;
      if (best == null || _rank(o, level) > _rank(best.obj, best.level)) {
        best = (obj: o, level: level, inPath: inPath);
      }
    }
    if (best == null) return null;

    final side = best.inPath ? _freeSide(best.obj, load, frame) : Guidance.none;
    final guidance = best.level == AlertLevel.danger && best.inPath ? Guidance.stop : side;
    return HazardAlert(
      level: best.level,
      guidance: guidance,
      subject: 'track:${best.obj.track.id}',
      message: _message(best.obj, best.level, best.inPath, side),
    );
  }

  AlertLevel _levelOf(ObjectInfo o, bool inPath) {
    final near = o.distance == DistanceLevel.near;
    final medium = o.distance == DistanceLevel.medium;
    switch (o.category) {
      case ObjectCategory.groundHazard:
        // Hố ga / bậc thang: gậy có thể dò được nhưng rủi ro cao → báo sớm
        if (!inPath) return near ? AlertLevel.caution : AlertLevel.info;
        return o.distance == DistanceLevel.far ? AlertLevel.caution : AlertLevel.danger;
      case ObjectCategory.vehicle:
        if (o.approaching) return inPath ? AlertLevel.danger : AlertLevel.caution;
        if (inPath) return near ? AlertLevel.danger : (medium ? AlertLevel.caution : AlertLevel.info);
        return near ? AlertLevel.caution : AlertLevel.info;
      case ObjectCategory.obstacle:
      case ObjectCategory.animal:
        if (!inPath) return AlertLevel.info;
        return near ? AlertLevel.danger : (medium ? AlertLevel.caution : AlertLevel.info);
      case ObjectCategory.person:
        // Người đi cùng chiều ở 2 mét là chuyện bình thường → chỉ báo khi rất gần hoặc đang lao tới
        if (!inPath) return AlertLevel.info;
        if (near) return AlertLevel.danger;
        return o.approaching ? AlertLevel.caution : AlertLevel.info;
      case ObjectCategory.other:
        return AlertLevel.info;
    }
  }

  static const _categoryRank = {
    ObjectCategory.groundHazard: 5,
    ObjectCategory.vehicle: 4,
    ObjectCategory.obstacle: 3,
    ObjectCategory.animal: 2,
    ObjectCategory.person: 1,
    ObjectCategory.other: 0,
  };

  int _rank(ObjectInfo o, AlertLevel level) =>
      level.index * 100 + _categoryRank[o.category]! * 10 + (2 - o.distance.index);

  /// Phía nên né sang (trái/phải), hoặc [Guidance.slowDown] nếu cả 2 bên đều bị chắn
  Guidance _freeSide(ObjectInfo o, List<double> load, Size frame) {
    final leftFree = load[HPos.left.index] < 1.0;
    final rightFree = load[HPos.right.index] < 1.0;
    if (leftFree && rightFree) {
      // Né về phía xa tâm vật hơn
      return o.track.box.center.dx > frame.width / 2 ? Guidance.goLeft : Guidance.goRight;
    }
    if (leftFree) return Guidance.goLeft;
    if (rightFree) return Guidance.goRight;
    return Guidance.slowDown;
  }

  /// [side]: phía trống để né (chỉ có nghĩa khi vật nằm trên lối đi)
  String _message(ObjectInfo o, AlertLevel level, bool inPath, Guidance side) {
    final where = inPath ? 'phía trước' : o.pos.vi;
    final label = o.label;

    if (level == AlertLevel.danger) {
      final head = o.category == ObjectCategory.groundHazard
          ? 'Dừng lại! Có $label $where!'
          : o.approaching
              ? 'Dừng lại! ${capitalize(label)} đang tới gần $where!'
              : 'Dừng lại! ${capitalize(label)} $where, rất gần.';
      // Chỉ nêu thông tin phía trống, không ra lệnh rẽ khi đang nguy hiểm
      return switch (side) {
        Guidance.goLeft => '$head Bên trái trống.',
        Guidance.goRight => '$head Bên phải trống.',
        _ => head,
      };
    }

    final head = o.approaching
        ? 'Cẩn thận, $label đang tới gần $where'
        : 'Cẩn thận, $label $where, ${o.distance.vi}';
    return switch (side) {
      Guidance.goLeft => '$head. Đi chếch sang trái.',
      Guidance.goRight => '$head. Đi chếch sang phải.',
      Guidance.slowDown => '$head. Đi chậm lại.',
      _ => '$head.',
    };
  }
}
