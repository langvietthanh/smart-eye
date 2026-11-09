import '../models/scene_info.dart';

/// Trả về câu cần đọc, hoặc null nếu không cần nói.
/// [left]/[right] chỉ có khi dùng LiDAR; câu về hai bên được nối vào cuối.
String? depthAlertText({
  required AlertLevel depthLevel,
  AlertLevel? detectorLevel, // mức cảnh báo YOLO hiện tại, null nếu không có
  double? metres, // chỉ có khi dùng LiDAR
  SideState left = SideState.unknown,
  SideState right = SideState.unknown,
}) {
  if (depthLevel == AlertLevel.info) {
    return null;
  }
  if (detectorLevel != null && detectorLevel.index >= depthLevel.index) {
    return null;
  }
  final String head;
  if (depthLevel == AlertLevel.danger) {
    head = 'Dừng lại! Vật cản ngay trước mặt.';
  } else if (metres != null) {
    head = 'Chậm lại. Vật cản cách ${spokenMetres(metres)} mét.';
  } else {
    head = 'Chậm lại. Có vật phía trước.';
  }
  return _join(head, sideClause(left, right));
}

/// Hai bên của vật cản phía trước; null khi không chắc chắn điều gì.
/// Chỉ mô tả, không ra lệnh rẽ.
String? sideClause(SideState left, SideState right) {
  const c = SideState.clear, b = SideState.blocked;
  if (left == c && right == c) return 'Hai bên trống.';
  if (left == c) return 'Bên trái trống.';
  if (right == c) return 'Bên phải trống.';
  if (left == b && right == b) return 'Hai bên có vật cản.';
  return null;
}

/// Nối câu hai bên vào cảnh báo của YOLO, chỉ khi vật nằm ở giữa: với vật
/// bên trái/phải, câu "bên ... trống" dễ mâu thuẫn với chính cảnh báo.
String withSideClause(
  String message, {
  required HPos? pos,
  required SideState left,
  required SideState right,
}) => pos == HPos.center ? _join(message, sideClause(left, right)) : message;

/// Side lanes older than this (from LiDAR capture) are never spoken.
const int sideMaxAgeMs = 500;

/// The side states that may be spoken now: none while trapped (the trap line
/// already says every side is blocked), before any LiDAR reading, or once the
/// reading captured at [capturedAtMs] is older than [sideMaxAgeMs].
({SideState left, SideState right}) speakableSides(
  ({SideState left, SideState right}) sides, {
  required int capturedAtMs,
  required int nowMs,
  required bool trapped,
}) => !trapped && capturedAtMs >= 0 && nowMs - capturedAtMs <= sideMaxAgeMs
    ? sides
    : (left: SideState.unknown, right: SideState.unknown);

String _join(String head, String? tail) => tail == null ? head : '$head $tail';

/// Làm tròn 0,5 m với dấu phẩy thập phân tiếng Việt: "1,5".
String spokenMetres(double metres) {
  final half = (metres * 2).round() / 2;
  return half == half.roundToDouble()
      ? half.toStringAsFixed(0)
      : half.toStringAsFixed(1).replaceAll('.', ',');
}
