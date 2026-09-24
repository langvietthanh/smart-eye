import 'dart:math';
import 'dart:ui';

import '../models/Recognition.dart';
import '../models/tracked_object.dart';

/// CN5 — Tracker IoU + centroid: gán ID cho vật qua các frame.
///
/// Hysteresis xuất hiện/biến mất:
/// - Vật chỉ được "xác nhận" sau [minHits] frame liên tiếp → lọc nhận diện nhảy lung tung
/// - Vật chỉ bị xoá sau [maxMisses] frame mất liên tiếp → không báo lại khi AI chớp mất 1 frame
class ObjectTracker {
  static const int minHits = 3;
  static const int maxMisses = 5;
  static const double _iouMatch = 0.3;
  static const double _centroidMatch = 0.15; // theo tỉ lệ đường chéo khung
  static const double _smooth = 0.5;         // hệ số EMA làm mượt box

  final List<TrackedObject> _tracks = [];
  int _nextId = 1;

  /// Cập nhật tracker với kết quả nhận diện của frame mới.
  /// [coverage]: vùng (toạ độ màn hình) lần quét này nhìn thấy — khi chỉ quét vùng hành lang,
  /// vật nằm ngoài vùng đó không bị tính là "mất" (lần quét không nhìn tới chỗ nó). null = toàn khung.
  /// Trả về các vật đã xác nhận (kể cả vừa mất 1–2 frame).
  List<TrackedObject> update(List<Recognition> detections, Size frame, DateTime now, {Rect? coverage}) {
    final diag = sqrt(frame.width * frame.width + frame.height * frame.height);

    // Tất cả cặp (track, detection) cùng lớp có thể ghép, xếp theo độ khớp giảm dần
    final pairs = <({int t, int d, double score})>[];
    for (int t = 0; t < _tracks.length; t++) {
      for (int d = 0; d < detections.length; d++) {
        if (_tracks[t].classId != detections[d].id) continue;
        final iou = computeIoU(_tracks[t].box, detections[d].location);
        if (iou >= _iouMatch) {
          pairs.add((t: t, d: d, score: 1 + iou));
          continue;
        }
        final dist = (_tracks[t].box.center - detections[d].location.center).distance / diag;
        if (dist <= _centroidMatch) pairs.add((t: t, d: d, score: 1 - dist));
      }
    }
    pairs.sort((a, b) => b.score.compareTo(a.score));

    final usedT = <int>{};
    final usedD = <int>{};
    for (final p in pairs) {
      if (usedT.contains(p.t) || usedD.contains(p.d)) continue;
      usedT.add(p.t);
      usedD.add(p.d);
      final track = _tracks[p.t];
      final det = detections[p.d];
      track.box = Rect.lerp(track.box, det.location, _smooth)!;
      track.score = det.score;
      track.hits++;
      track.misses = 0;
      track.addHistory(now, track.box.height / frame.height);
    }

    for (int t = 0; t < _tracks.length; t++) {
      if (usedT.contains(t)) continue;
      // Lần quét chỉ nhìn 1 vùng: vật không nằm TRỌN trong vùng đó thì lần này không tính (vật vắt qua mép
      // vùng bị cắt dở nên đã bị bỏ — không phải "mất") → không làm khung vật chớp tắt
      if (coverage != null && !_inside(_tracks[t].box, coverage)) continue;
      _tracks[t].misses++;
      _tracks[t].hits = min(_tracks[t].hits, minHits); // giữ trạng thái đã xác nhận
    }
    _tracks.removeWhere((t) => t.misses > maxMisses);

    for (int d = 0; d < detections.length; d++) {
      if (usedD.contains(d)) continue;
      final det = detections[d];
      _tracks.add(TrackedObject(
        id: _nextId++,
        classId: det.id,
        labelEn: det.labelEn,
        labelVi: det.label,
        box: det.location,
        score: det.score,
      )..addHistory(now, det.location.height / frame.height));
    }

    return _tracks.where((t) => t.hits >= minHits && t.misses <= 2).toList();
  }

  void reset() => _tracks.clear();

  static bool _inside(Rect box, Rect area) =>
      box.left >= area.left && box.top >= area.top && box.right <= area.right && box.bottom <= area.bottom;
}

/// IoU (Intersection over Union) giữa 2 hình chữ nhật
double computeIoU(Rect a, Rect b) {
  final inter = a.intersect(b);
  if (inter.width <= 0 || inter.height <= 0) return 0.0;
  final interArea = inter.width * inter.height;
  final union = a.width * a.height + b.width * b.height - interArea;
  return union <= 0 ? 0.0 : interArea / union;
}
