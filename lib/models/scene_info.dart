import 'tracked_object.dart';

/// Vị trí ngang của vật trong khung hình (chia 3 cột — CN6)
enum HPos { left, center, right }

/// Mức khoảng cách ước lượng từ % chiều cao box (CN7)
enum DistanceLevel { near, medium, far }

/// Nhóm vật thể — quyết định mức độ nguy hiểm (CN4)
enum ObjectCategory { groundHazard, vehicle, obstacle, animal, person, other }

/// Mức cảnh báo, sắp xếp tăng dần theo độ khẩn cấp
enum AlertLevel { info, caution, danger }

/// Hướng gợi ý cho người dùng
enum Guidance { none, goLeft, goRight, stop, slowDown }

extension HPosText on HPos {
  String get vi => switch (this) {
        HPos.left => 'bên trái',
        HPos.center => 'phía trước',
        HPos.right => 'bên phải',
      };
}

extension DistanceText on DistanceLevel {
  String get vi => switch (this) {
        DistanceLevel.near => 'rất gần',
        DistanceLevel.medium => 'cách khoảng 2 mét',
        DistanceLevel.far => 'ở xa',
      };
}

/// Thông tin 1 vật sau khi qua rules engine: vị trí, khoảng cách, loại, đang tới gần?
class ObjectInfo {
  final TrackedObject track;
  final HPos pos;
  final DistanceLevel distance;
  final ObjectCategory category;
  final bool approaching;

  const ObjectInfo({
    required this.track,
    required this.pos,
    required this.distance,
    required this.category,
    required this.approaching,
  });

  String get label => track.labelVi;

  /// Vật có đáng để cảnh báo không (bỏ qua cốc, sách, điện thoại...)
  bool get isRelevant => category != ObjectCategory.other;
}

/// 1 cảnh báo mà rules engine quyết định cần nói
class HazardAlert {
  final AlertLevel level;
  final String message;
  final Guidance guidance;

  /// Chủ thể của cảnh báo (VD: 'track:12') — Speech Manager dùng để dedupe + hysteresis
  final String subject;

  const HazardAlert({
    required this.level,
    required this.message,
    required this.guidance,
    required this.subject,
  });
}

/// Kết quả đánh giá 1 frame
class SceneAssessment {
  final List<ObjectInfo> objects;

  /// Trọng số vật cản của 3 cột [trái, giữa, phải] — 0 là trống
  final List<double> columnLoad;
  final HazardAlert? alert;

  const SceneAssessment({required this.objects, required this.columnLoad, this.alert});

  static const empty = SceneAssessment(objects: [], columnLoad: [0, 0, 0]);

  bool isColumnFree(HPos pos) => columnLoad[pos.index] < 1.0;
}
