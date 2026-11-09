import 'tracked_object.dart';

/// Vị trí ngang của vật trong khung hình (chia 3 cột — CN6)
enum HPos { left, center, right }

/// Mức chiếm ảnh tương đối; không phải khoảng cách vật lý đã đo.
enum DistanceLevel { near, medium, far }

/// Nhóm vật thể — quyết định mức độ nguy hiểm (CN4)
enum ObjectCategory { groundHazard, vehicle, obstacle, animal, person, other }

/// Mức cảnh báo, sắp xếp tăng dần theo độ khẩn cấp
enum AlertLevel { info, caution, danger }

/// Làn bên cạnh vật cản phía trước, đo bằng LiDAR. `clear` chỉ khi đã thấy
/// mặt sàn của cả làn; không thấy gì là `unknown`, không phải trống.
enum SideState { clear, blocked, unknown }

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
    DistanceLevel.medium => 'khá gần',
    DistanceLevel.far => 'còn xa',
  };
}

/// Thông tin 1 vật sau khi qua rules engine: vị trí, khoảng cách, loại, đang tới gần?
class ObjectInfo {
  final TrackedObject track;
  final HPos pos;
  final DistanceLevel distance;
  final ObjectCategory category;
  final bool approaching;
  final bool closingQuickly;

  const ObjectInfo({
    required this.track,
    required this.pos,
    required this.distance,
    required this.category,
    required this.approaching,
    this.closingQuickly = false,
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

  /// Trọng số vật đã nhận diện trong 3 cột. 0 không chứng minh lối đi an toàn.
  final List<double> columnLoad;
  final HazardAlert? alert;

  const SceneAssessment({
    required this.objects,
    required this.columnLoad,
    this.alert,
  });

  static const empty = SceneAssessment(objects: [], columnLoad: [0, 0, 0]);

  bool isColumnFree(HPos pos) => columnLoad[pos.index] < 1.0;
}
