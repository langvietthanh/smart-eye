import '../models/scene_info.dart';
import 'depth_analysis.dart';

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
    head = _dangerHead;
  } else if (metres != null) {
    head = 'Chậm lại. Vật cản cách ${spokenMetres(metres)} mét.';
  } else {
    head = 'Chậm lại. Có vật phía trước.';
  }
  return _join(head, sideClause(left, right));
}

/// Hướng lách qua vật cản phía trước; null khi không chắc chắn điều gì.
/// Làn trống chỉ rộng 40 cm nên lệnh là "đi chéo", không phải quay hẳn.
String? sideClause(SideState left, SideState right) {
  const c = SideState.clear, b = SideState.blocked;
  // Hai bên trống: ưu tiên bên phải.
  if (right == c) return 'Đi chéo sang phải.';
  if (left == c) return 'Đi chéo sang trái.';
  if (left == b && right == b) return bothSidesBlocked;
  return null;
}

/// Một bên khi không có LiDAR: MiDaS (độ gần tương đối, không phải mét) và
/// tải cột YOLO. Chỉ "trống" khi cả hai cùng thấy trống; vật YOLO không có lớp
/// (thùng, tường) thì chỉ MiDaS thấy, nên ngưỡng trống thấp hơn hẳn ngưỡng báo.
SideState monoSide(double closeness, double columnLoad) {
  if (columnLoad >= 1.0 || closeness >= DepthAnalysis.caution) {
    return SideState.blocked;
  }
  return columnLoad == 0 && closeness < DepthAnalysis.clearBelow
      ? SideState.clear
      : SideState.unknown;
}

const _dangerHead = 'Dừng lại! Vật cản ngay trước mặt.';

/// Ends every obstacle alert that already says what the trap line says.
const bothSidesBlocked = 'Hai bên có vật cản.';

/// The trap line is the same sentence as a danger depth alert with both sides
/// blocked.
const trapAlertText = '$_dangerHead $bothSidesBlocked';

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
