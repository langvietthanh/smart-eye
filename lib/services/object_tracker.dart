import 'dart:math';
import 'dart:ui';

import '../models/Recognition.dart';
import '../models/tracked_object.dart';
import '../models/scene_info.dart';
import '../utils/label_catalog.dart';
import 'visual_proximity.dart';

/// CN5 — Tracker IoU + centroid: gán ID cho vật qua các frame.
///
/// Hysteresis xuất hiện/biến mất:
/// - Thường xác nhận sau [minHits] frame; vật lớn chắn phía trước có thể xác nhận
///   sau 2 frame liên tiếp có confidence >= 0.4 để cảnh báo sớm.
/// - Vật chỉ bị xoá sau [maxMisses] frame mất liên tiếp → không báo lại khi AI chớp mất 1 frame
class ObjectTracker {
  static const int minHits = 3;
  static const int maxMisses = 5;
  static const double _iouMatch = 0.3;
  static const double _centroidMatch = 0.15; // theo tỉ lệ đường chéo khung
  static const double _smooth = 0.5; // hệ số EMA làm mượt box
  static const Duration maxObservationGap = Duration(milliseconds: 750);

  final List<TrackedObject> _tracks = [];
  int _nextId = 1;

  /// Cập nhật tracker với kết quả nhận diện của frame mới.
  /// Trả về các vật đã xác nhận (kể cả vừa mất 1–2 frame).
  List<TrackedObject> update(
    List<Recognition> detections,
    Size frame,
    DateTime now,
  ) {
    if (frame.width <= 0 || frame.height <= 0) return [];
    _tracks.removeWhere(
      (track) =>
          track.lastSeen != null &&
          now.difference(track.lastSeen!) > maxObservationGap,
    );
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
        final dist =
            (_tracks[t].box.center - detections[d].location.center).distance /
            diag;
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
      track.observedBox = det.location;
      track.score = det.score;
      track.confirmationConfidence = track.hits == 0
          ? det.score
          : min(track.confirmationConfidence, det.score);
      track.hits++;
      track.misses = 0;
      track.addHistory(now, VisualProximity.sizeRatio(det.location, frame));
    }

    for (int t = 0; t < _tracks.length; t++) {
      if (usedT.contains(t)) continue;
      _tracks[t].misses++;
      // Vật chưa xác nhận phải bắt đầu lại chuỗi frame liên tiếp khi bị mất.
      // Vật đã xác nhận vẫn giữ trạng thái qua các frame AI chớp mất.
      _tracks[t].hits = _tracks[t].confirmed ? minHits : 0;
      if (!_tracks[t].confirmed) _tracks[t].history.clear();
    }
    _tracks.removeWhere((t) => t.misses > maxMisses);

    for (int d = 0; d < detections.length; d++) {
      if (usedD.contains(d)) continue;
      final det = detections[d];
      _tracks.add(
        TrackedObject(
          id: _nextId++,
          classId: det.id,
          labelEn: det.labelEn,
          labelVi: det.label,
          box: det.location,
          score: det.score,
        )..addHistory(now, VisualProximity.sizeRatio(det.location, frame)),
      );
    }

    for (final track in _tracks) {
      final earlyWarning =
          track.hits >= 2 &&
          track.confirmationConfidence >= 0.4 &&
          categoryOf(track.labelEn) != ObjectCategory.other &&
          VisualProximity.inPath(track.observedBox, frame) &&
          VisualProximity.occupancy(track.observedBox, frame) >=
              VisualProximity.nearEnter;
      if (track.hits >= minHits || earlyWarning) track.confirmed = true;
    }
    return _tracks.where((t) => t.confirmed && t.misses <= 2).toList();
  }

  void reset() => _tracks.clear();
}

/// IoU (Intersection over Union) giữa 2 hình chữ nhật
double computeIoU(Rect a, Rect b) {
  final inter = a.intersect(b);
  if (inter.width <= 0 || inter.height <= 0) return 0.0;
  final interArea = inter.width * inter.height;
  final union = a.width * a.height + b.width * b.height - interArea;
  return union <= 0 ? 0.0 : interArea / union;
}
