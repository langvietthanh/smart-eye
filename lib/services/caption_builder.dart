import '../models/scene_info.dart';
import '../models/trip.dart';
import '../utils/label_catalog.dart';

/// CN8 — Mô tả cảnh bằng câu khuôn (template), chạy on-device trong vài ms.
/// CN13 — Tóm tắt chuyến đi (recap) bằng template.
class CaptionBuilder {
  /// Số nhóm vật tối đa trong 1 câu mô tả — nhiều hơn sẽ thành "nói chuyện phiếm"
  static const int maxGroups = 2;

  /// "Phía trước có 2 người, gần nhất cách khoảng 2 mét. Bên phải có xe máy, ở xa. Bên trái trống."
  static String describeScene(SceneAssessment scene) {
    final objects = scene.objects.where((o) => o.isRelevant).toList();
    if (objects.isEmpty) return 'Phía trước không thấy vật cản nào.';

    // Gộp theo (vị trí, tên vật), giữ khoảng cách gần nhất trong nhóm
    final groups = <String, ({HPos pos, String label, int count, DistanceLevel nearest, int rank})>{};
    for (final o in objects) {
      final key = '${o.pos.index}|${o.label}';
      final g = groups[key];
      final rank = (o.isRelevant ? 10 : 0) + (2 - o.distance.index);
      groups[key] = g == null
          ? (pos: o.pos, label: o.label, count: 1, nearest: o.distance, rank: rank)
          : (
              pos: g.pos,
              label: g.label,
              count: g.count + 1,
              nearest: o.distance.index < g.nearest.index ? o.distance : g.nearest,
              rank: rank > g.rank ? rank : g.rank,
            );
    }

    // Quan trọng trước (vật cản liên quan, gần), rồi theo thứ tự: trước → trái → phải
    const posOrder = {HPos.center: 0, HPos.left: 1, HPos.right: 2};
    final sorted = groups.values.toList()
      ..sort((a, b) {
        final r = b.rank.compareTo(a.rank);
        return r != 0 ? r : posOrder[a.pos]!.compareTo(posOrder[b.pos]!);
      });
    final shown = sorted.take(maxGroups).toList()
      ..sort((a, b) => posOrder[a.pos]!.compareTo(posOrder[b.pos]!));

    // Người khiếm thị cần biết ĐI HƯỚNG NÀO trước, vật gì sau
    final parts = <String>[freeSpaceSentence(scene)];
    for (final g in shown) {
      final what = g.count > 1 ? '${g.count} ${g.label}' : g.label;
      final dist = g.count > 1 ? 'gần nhất ${g.nearest.vi}' : g.nearest.vi;
      parts.add('${capitalize(g.pos.vi)} có $what, $dist.');
    }
    return parts.join(' ');
  }

  /// Câu tóm tắt lối đi dựa trên free-space 3 cột
  static String freeSpaceSentence(SceneAssessment scene) {
    final left = scene.isColumnFree(HPos.left);
    final right = scene.isColumnFree(HPos.right);
    if (scene.isColumnFree(HPos.center)) {
      if (left && right) return 'Lối đi phía trước thông thoáng.';
      if (left) return 'Phía trước trống, bên phải có vật cản.';
      if (right) return 'Phía trước trống, bên trái có vật cản.';
      return 'Phía trước trống, hai bên có vật cản.';
    }
    if (left && right) return 'Phía trước bị chắn, hai bên trái phải đều trống.';
    if (left) return 'Phía trước bị chắn, bên trái trống.';
    if (right) return 'Phía trước bị chắn, bên phải trống.';
    return 'Phía trước và hai bên đều có vật cản, nên đứng lại.';
  }

  // ---------------------------------------------------------------------------
  // CN13 — Recap
  // ---------------------------------------------------------------------------

  /// "Chuyến đi lúc 7 giờ 30 sáng ngày 23 tháng 9: đi khoảng 1,2 ki lô mét trong 45 phút,
  ///  gặp 3 cảnh báo nguy hiểm và 5 lần nhắc chú ý."
  static String recap(TripSummary trip) {
    final start = trip.startTime;
    final buf = StringBuffer('Chuyến đi lúc ${spokenTime(start)} ngày ${start.day} tháng ${start.month}: ');

    final activity = <String>[];
    if (trip.distanceMeters >= 20) activity.add('đi khoảng ${spokenDistance(trip.distanceMeters)}');
    activity.add('trong ${spokenDuration(trip.duration)}');
    buf.write(activity.join(' '));

    final counts = <String>[];
    if (trip.dangerCount > 0) counts.add('${trip.dangerCount} cảnh báo nguy hiểm');
    if (trip.cautionCount > 0) counts.add('${trip.cautionCount} lần nhắc chú ý');
    buf.write(counts.isEmpty ? ', không gặp cảnh báo nào.' : ', gặp ${counts.join(' và ')}.');

    if (trip.memoryCount > 0) buf.write(' Đã lưu ${trip.memoryCount} ảnh ghi nhớ.');
    return buf.toString();
  }

  static String spokenTime(DateTime t) {
    final h = t.hour;
    final period = h < 11 ? 'sáng' : h < 14 ? 'trưa' : h < 18 ? 'chiều' : 'tối';
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return t.minute == 0 ? '$h12 giờ $period' : '$h12 giờ ${t.minute} $period';
  }

  static String spokenDistance(double meters) {
    if (meters < 1000) return '${(meters / 10).round() * 10} mét';
    final km = (meters / 100).round() / 10;
    return '${km.toString().replaceAll('.', ',').replaceAll(RegExp(r',0$'), '')} ki lô mét';
  }

  static String spokenDuration(Duration d) {
    if (d.inMinutes < 1) return '${d.inSeconds} giây';
    if (d.inHours < 1) return '${d.inMinutes} phút';
    final m = d.inMinutes % 60;
    return m == 0 ? '${d.inHours} giờ' : '${d.inHours} giờ $m phút';
  }
}
