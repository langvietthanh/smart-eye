import 'dart:ui';

import 'scene_info.dart';

/// 1 vật được theo dõi qua nhiều frame (CN5)
class TrackedObject {
  final int id;
  final int classId;
  final String labelEn;
  final String labelVi;

  Rect box; // Box đã làm mượt (EMA) theo toạ độ màn hình
  // Keep the latest observation for warning decisions: UI smoothing must not
  // delay escalation when an obstacle suddenly occupies more of the image.
  Rect observedBox;
  double score;
  int hits = 1; // Số frame liên tiếp khớp được
  /// Lowest confidence in the uninterrupted confirmation sequence.
  double confirmationConfidence;
  int misses = 0; // Số frame liên tiếp bị mất
  bool confirmed = false;
  DateTime? lastSeen;

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
  }) : observedBox = box,
       confirmationConfidence = score;

  void addHistory(DateTime time, double ratio) {
    lastSeen = time;
    history.add((time: time, ratio: ratio));
    // Bound time and sample count, even when capture timestamps repeat.
    history.removeWhere(
      (h) => time.difference(h.time) > const Duration(seconds: 1),
    );
    if (history.length > 12) history.removeRange(0, history.length - 12);
  }

  /// Tỉ lệ tăng kích thước box trong cửa sổ lịch sử (1.0 = đứng yên, 1.3 = to thêm 30%)
  double get growth {
    if (history.length < 3) return 1.0;
    final span = history.last.time.difference(history.first.time);
    if (span < const Duration(milliseconds: 200)) return 1.0;
    // Trung bình 2 mẫu đầu / 2 mẫu cuối để giảm nhiễu
    final first = (history[0].ratio + history[1].ratio) / 2;
    final last =
        (history[history.length - 1].ratio +
            history[history.length - 2].ratio) /
        2;
    return first <= 0 ? 1.0 : last / first;
  }

  /// Growth of image occupancy per second, not speed in metres/second or a
  /// time-to-collision estimate. Average pairs reduce one-frame box jitter.
  double get occupancyGrowthPerSecond {
    if (history.length < 3) return 0;
    final first = history.take(2).toList();
    final last = history.skip(history.length - 2).toList();
    final seconds =
        (last[0].time.difference(first[0].time).inMicroseconds +
            last[1].time.difference(first[1].time).inMicroseconds) /
        2000000;
    if (seconds < 0.1) return 0;
    return ((last[0].ratio + last[1].ratio) -
            (first[0].ratio + first[1].ratio)) /
        (2 * seconds);
  }
}
