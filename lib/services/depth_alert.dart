import '../models/scene_info.dart';

/// Trả về câu cần đọc, hoặc null nếu không cần nói.
String? depthAlertText({
  required AlertLevel depthLevel,
  AlertLevel? detectorLevel, // mức cảnh báo YOLO hiện tại, null nếu không có
  double? metres,            // chỉ có khi dùng LiDAR
}) {
  if (depthLevel == AlertLevel.info) {
    return null;
  }
  if (detectorLevel != null && detectorLevel.index >= depthLevel.index) {
    return null;
  }
  if (depthLevel == AlertLevel.danger) {
    return 'Dừng lại! Có vật cản ngay phía trước.';
  }
  // depthLevel == AlertLevel.caution
  if (metres != null) {
    return 'Chậm lại. Vật cản phía trước, khoảng ${spokenMetres(metres)} mét.';
  }
  return 'Chậm lại. Có vật phía trước.';
}

/// Làm tròn 0,5 m với dấu phẩy thập phân tiếng Việt: "1,5".
String spokenMetres(double metres) {
  final half = (metres * 2).round() / 2;
  return half == half.roundToDouble()
      ? half.toStringAsFixed(0)
      : half.toStringAsFixed(1).replaceAll('.', ',');
}
