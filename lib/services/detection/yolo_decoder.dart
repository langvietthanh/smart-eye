import 'dart:math';
import 'dart:typed_data';

import 'frame_data.dart';

/// 1 vật model tìm thấy — toạ độ chuẩn hoá [0..1] trên TOÀN khung ảnh đã xoay
class RawDetection {
  final int classId;
  final double score;
  final double left;
  final double top;
  final double right;
  final double bottom;

  const RawDetection(this.classId, this.score, this.left, this.top, this.right, this.bottom);

  double get width => right - left;
  double get height => bottom - top;
  double get area => width * height;

  @override
  String toString() => 'RawDetection($classId, ${score.toStringAsFixed(2)}, '
      '[${left.toStringAsFixed(2)}, ${top.toStringAsFixed(2)}, ${right.toStringAsFixed(2)}, ${bottom.toStringAsFixed(2)}])';
}

/// Kết quả giải mã + số liệu chẩn đoán
class DecodeResult {
  final List<RawDetection> detections;

  /// Điểm cao nhất trong các lớp được xét (kể cả dưới ngưỡng) — để hiển thị chẩn đoán
  final double maxScore;
  final int maxClassId;

  const DecodeResult(this.detections, this.maxScore, this.maxClassId);
}

/// Giải mã output YOLOv8/YOLO11 dạng `[1, 4 + số lớp, số anchor]` (hoặc chuyển vị `[1, anchor, 4 + lớp]`).
///
/// Tối ưu so với cách cũ:
/// - Đọc trực tiếp mảng Float32 (không qua ByteData từng phần tử)
/// - Chỉ xét [classIds] liên quan tới đi lại (~25/80 lớp) và duyệt theo hàng → ít phép tính, thân thiện bộ nhớ đệm
/// - NMS theo lớp + gộp box trùng giữa các lớp (VD "ô tô" và "xe tải" trên cùng 1 chiếc xe)
class YoloDecoder {
  static DecodeResult decode({
    required Float32List output,
    required List<int> shape,
    required List<int> classIds,
    required int inputSize,
    double confThreshold = 0.25,
    double iouThreshold = 0.45,
    double crossClassIou = 0.8,
    CropRect crop = CropRect.full,
    int maxDetections = 20,
  }) {
    final transposed = shape[1] > shape[2];
    final channels = transposed ? shape[2] : shape[1];
    final anchors = transposed ? shape[1] : shape[2];
    final numClasses = channels - 4;

    double at(int c, int i) => transposed ? output[i * channels + c] : output[c * anchors + i];

    // 1) Điểm cao nhất + lớp tương ứng cho từng anchor, chỉ trong các lớp được xét
    final best = Float32List(anchors);
    final bestCls = Int32List(anchors)..fillRange(0, anchors, -1);
    var maxScore = 0.0;
    var maxClass = -1;
    for (final c in classIds) {
      if (c < 0 || c >= numClasses) continue;
      if (transposed) {
        for (var i = 0; i < anchors; i++) {
          final v = output[i * channels + 4 + c];
          if (v > best[i]) {
            best[i] = v;
            bestCls[i] = c;
          }
        }
      } else {
        final row = (4 + c) * anchors;
        for (var i = 0; i < anchors; i++) {
          final v = output[row + i];
          if (v > best[i]) {
            best[i] = v;
            bestCls[i] = c;
          }
        }
      }
    }

    // 2) Lọc theo ngưỡng, đổi toạ độ về khung đầy đủ
    final candidates = <RawDetection>[];
    for (var i = 0; i < anchors; i++) {
      final s = best[i];
      if (s > maxScore) {
        maxScore = s;
        maxClass = bestCls[i];
      }
      if (s < confThreshold || bestCls[i] < 0) continue;

      var cx = at(0, i), cy = at(1, i), w = at(2, i), h = at(3, i);
      if (cx > 1.5 || w > 1.5) {
        // Toạ độ pixel [0..inputSize] → chuẩn hoá
        cx /= inputSize;
        cy /= inputSize;
        w /= inputSize;
        h /= inputSize;
      }
      final l = crop.left + (cx - w / 2).clamp(0.0, 1.0) * crop.width;
      final t = crop.top + (cy - h / 2).clamp(0.0, 1.0) * crop.height;
      final r = crop.left + (cx + w / 2).clamp(0.0, 1.0) * crop.width;
      final b = crop.top + (cy + h / 2).clamp(0.0, 1.0) * crop.height;
      if (r <= l || b <= t) continue;
      candidates.add(RawDetection(bestCls[i], s, l, t, r, b));
    }

    return DecodeResult(nms(candidates, iouThreshold, crossClassIou, maxDetections), maxScore, maxClass);
  }

  /// NMS: trong cùng lớp bỏ box chồng > [iou]; khác lớp bỏ box gần như trùng hẳn (> [crossClassIou])
  static List<RawDetection> nms(List<RawDetection> input, double iou, double crossClassIou, int maxDetections) {
    final sorted = [...input]..sort((a, b) => b.score.compareTo(a.score));
    final kept = <RawDetection>[];
    for (final d in sorted) {
      final suppressed = kept.any((k) {
        final v = iouOf(k, d);
        return k.classId == d.classId ? v > iou : v > crossClassIou;
      });
      if (suppressed) continue;
      kept.add(d);
      if (kept.length >= maxDetections) break;
    }
    return kept;
  }

  static double iouOf(RawDetection a, RawDetection b) {
    final w = min(a.right, b.right) - max(a.left, b.left);
    final h = min(a.bottom, b.bottom) - max(a.top, b.top);
    if (w <= 0 || h <= 0) return 0;
    final inter = w * h;
    return inter / (a.area + b.area - inter);
  }

  /// Box chạm mép vùng cắt (không phải mép khung) → vật bị cắt dở, kích thước sai → nên bỏ,
  /// khung đầy đủ sẽ thấy vật đó trọn vẹn.
  static bool touchesCropEdge(RawDetection d, CropRect crop, {double margin = 0.01}) {
    if (crop.isFull) return false;
    return (crop.left > 0 && d.left <= crop.left + margin) ||
        (crop.top > 0 && d.top <= crop.top + margin) ||
        (crop.right < 1 && d.right >= crop.right - margin) ||
        (crop.bottom < 1 && d.bottom >= crop.bottom - margin);
  }
}
