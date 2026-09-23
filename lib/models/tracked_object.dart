import 'dart:ui';

import 'scene_info.dart';

/// 1 vật được theo dõi qua nhiều frame (CN5)
class TrackedObject {
  final int id;
  final int classId;
  final String labelEn;
  final String labelVi;

  Rect box;          // Box đã làm mượt (EMA) theo toạ độ màn hình
  double score;
  int hits = 1;      // Số frame liên tiếp khớp được
  int misses = 0;    // Số frame liên tiếp bị mất

  /// Mức khoảng cách hiện tại — rules engine cập nhật có hysteresis để không nhảy qua lại
  DistanceLevel? distanceLevel;

  /// Lịch sử (thời điểm, % chiều cao box) để biết vật đang tới gần hay không
  final List<({DateTime time, double ratio})> history = [];

  TrackedObject({
    required this.id,
    required this.classId,
    required this.labelEn,
    required this.labelVi,
    required this.box,
    required this.score,
  });

  void addHistory(DateTime time, double ratio) {
    history.add((time: time, ratio: ratio));
    // Giữ lại khoảng 2 giây gần nhất
    history.removeWhere((h) => time.difference(h.time) > const Duration(milliseconds: 2000));
  }

  /// Tỉ lệ tăng kích thước box trong cửa sổ lịch sử (1.0 = đứng yên, 1.3 = to thêm 30%)
  double get growth {
    if (history.length < 3) return 1.0;
    final span = history.last.time.difference(history.first.time);
    if (span < const Duration(milliseconds: 500)) return 1.0;
    // Trung bình 2 mẫu đầu / 2 mẫu cuối để giảm nhiễu
    final first = (history[0].ratio + history[1].ratio) / 2;
    final last = (history[history.length - 1].ratio + history[history.length - 2].ratio) / 2;
    return first <= 0 ? 1.0 : last / first;
  }
}
