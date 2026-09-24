import 'dart:typed_data';
import 'package:image/image.dart' as img;

import '../services/detection/frame_data.dart';

/// Nhận 1 mẫu RGB đã lấy từ frame — [index] là vị trí mẫu theo thứ tự hàng rồi cột
typedef _SampleSink = void Function(int index, int r, int g, int b);

/// Các tiện ích xử lý ảnh: lấy mẫu trực tiếp frame camera → RGB đã xoay (+ cắt vùng) →
/// tensor float32 / JPEG / chữ ký độ sáng. Hỗ trợ 3 định dạng frame:
/// - YUV_420_888 3 lớp (Android)
/// - BGRA8888 1 lớp (iOS — app xin định dạng này trên iOS)
/// - NV12 2 lớp: Y + CbCr xen kẽ (iOS khi xin yuv420 — dự phòng)
class ImageUtils {
  /// Góc cần xoay frame camera (theo chiều kim đồng hồ) để ảnh đưa vào AI đứng thẳng.
  /// - iOS: plugin camera đã xoay sẵn frame theo hướng máy (AVCaptureConnection.videoOrientation),
  ///   còn `sensorOrientation` luôn báo 90 → phải trả 0, nếu không ảnh bị xoay sai 90°.
  /// - Android: frame giữ nguyên hướng cảm biến → bù theo hướng máy (công thức mẫu Google ML Kit).
  /// [deviceDegrees]: 0 dọc, 90 landscapeLeft, 180 dọc ngược, 270 landscapeRight.
  static int frameRotation({
    required bool isIOS,
    required int sensorOrientation,
    required int deviceDegrees,
    required bool frontCamera,
  }) {
    if (isIOS) return 0;
    return frontCamera
        ? (sensorOrientation + deviceDegrees) % 360
        : (sensorOrientation - deviceDegrees + 360) % 360;
  }

  /// Kích thước (rộng, cao) của frame sau khi xoay
  static ({int width, int height}) rotatedSize(int width, int height, int rotationDegrees) =>
      rotationDegrees == 90 || rotationDegrees == 270
          ? (width: height, height: width)
          : (width: width, height: height);

  /// Chuyển frame thành tensor float32 [0..1] kích thước [size]×[size] từ vùng [crop] của ảnh đã xoay.
  /// Layout theo model: [channelsFirst] = NCHW `[1, 3, S, S]`, ngược lại NHWC `[1, S, S, 3]`.
  static Float32List? toInputTensor(
    FrameData frame, {
    required int size,
    required bool channelsFirst,
    int rotationDegrees = 0,
    CropRect crop = CropRect.full,
  }) {
    final plane = size * size;
    final out = Float32List(3 * plane);
    const k = 1 / 255.0;
    final ok = _sample(frame, rotationDegrees, crop, size, size, channelsFirst
        ? (i, r, g, b) {
            out[i] = r * k;
            out[plane + i] = g * k;
            out[2 * plane + i] = b * k;
          }
        : (i, r, g, b) {
            out[i * 3] = r * k;
            out[i * 3 + 1] = g * k;
            out[i * 3 + 2] = b * k;
          });
    return ok ? out : null;
  }

  /// "Chữ ký" độ sáng [grid]×[grid] của toàn khung — so 2 chữ ký để biết cảnh có thay đổi không
  static Uint8List? lumaSignature(FrameData frame, {int rotationDegrees = 0, int grid = 16}) {
    final sig = Uint8List(grid * grid);
    final ok = _sample(frame, rotationDegrees, CropRect.full, grid, grid,
        (i, r, g, b) => sig[i] = (r * 77 + g * 150 + b * 29) >> 8);
    return ok ? sig : null;
  }

  /// Mức thay đổi giữa 2 chữ ký độ sáng: 0 = giống hệt, 1 = khác hoàn toàn
  static double signatureDiff(Uint8List a, Uint8List b) {
    if (a.length != b.length || a.isEmpty) return 1;
    var sum = 0;
    for (var i = 0; i < a.length; i++) {
      sum += (a[i] - b[i]).abs();
    }
    return sum / (a.length * 255);
  }

  /// CN12 — Tạo ảnh thumbnail JPEG nhỏ (cạnh dài [maxSide] px), đã xoay đúng chiều.
  static Uint8List? toJpeg(FrameData frame, {int rotationDegrees = 0, int maxSide = 320}) {
    try {
      final rot = rotatedSize(frame.width, frame.height, rotationDegrees);
      final scale = maxSide / (rot.width > rot.height ? rot.width : rot.height);
      final outW = (rot.width * scale).round();
      final outH = (rot.height * scale).round();
      final thumb = img.Image(width: outW, height: outH);
      final ok = _sample(frame, rotationDegrees, CropRect.full, outW, outH,
          (i, r, g, b) => thumb.setPixelRgb(i % outW, i ~/ outW, r, g, b));
      return ok ? img.encodeJpg(thumb, quality: 70) : null;
    } catch (_) {
      return null;
    }
  }

  /// Toạ độ (rx, ry) trên ảnh đã xoay chiều kim đồng hồ [rotationDegrees] → toạ độ trên ảnh gốc
  static ({int x, int y}) sourceCoord(int rx, int ry, int srcW, int srcH, int rotationDegrees) {
    return switch (rotationDegrees) {
      90 => (x: ry, y: srcH - 1 - rx),
      180 => (x: srcW - 1 - rx, y: srcH - 1 - ry),
      270 => (x: srcW - 1 - ry, y: rx),
      _ => (x: rx, y: ry),
    };
  }

  // ---------------------------------------------------------------------------
  // Lõi lấy mẫu — không cấp phát bộ nhớ theo từng pixel
  // ---------------------------------------------------------------------------

  /// Lấy mẫu lưới [outW]×[outH] (láng giềng gần nhất) trên vùng [crop] của ảnh đã xoay,
  /// đổi sang RGB và đẩy vào [sink]. Trả về false nếu định dạng frame không hỗ trợ.
  static bool _sample(
    FrameData f,
    int rotation,
    CropRect crop,
    int outW,
    int outH,
    _SampleSink sink,
  ) {
    final planes = f.planes;
    if (planes.isEmpty) return false;
    final format = switch (planes.length) { 1 => 0, 2 => 1, _ => 2 }; // 0 BGRA, 1 NV12, 2 YUV 3 lớp
    final srcW = f.width;
    final srcH = f.height;
    final rot = rotatedSize(srcW, srcH, rotation);

    final p0 = planes[0].bytes;
    final row0 = planes[0].bytesPerRow;
    final p1 = format > 0 ? planes[1].bytes : p0;
    final row1 = format > 0 ? planes[1].bytesPerRow : 0;
    final p2 = format == 2 ? planes[2].bytes : p0;
    final px1 = format == 2 ? (planes[1].bytesPerPixel ?? 1) : 2;

    // Toạ độ trên ảnh đã xoay cho từng cột / hàng đầu ra — tính 1 lần
    final colRx = Int32List(outW);
    for (var x = 0; x < outW; x++) {
      colRx[x] = ((crop.left + (x + 0.5) * crop.width / outW) * rot.width).floor().clamp(0, rot.width - 1);
    }

    var index = 0;
    for (var y = 0; y < outH; y++) {
      final ry = ((crop.top + (y + 0.5) * crop.height / outH) * rot.height).floor().clamp(0, rot.height - 1);
      for (var x = 0; x < outW; x++) {
        final rx = colRx[x];
        int sx, sy;
        switch (rotation) {
          case 90:
            sx = ry;
            sy = srcH - 1 - rx;
          case 180:
            sx = srcW - 1 - rx;
            sy = srcH - 1 - ry;
          case 270:
            sx = srcW - 1 - ry;
            sy = rx;
          default:
            sx = rx;
            sy = ry;
        }

        int r, g, b;
        if (format == 0) {
          final i = sy * row0 + sx * 4; // B, G, R, A
          b = p0[i];
          g = p0[i + 1];
          r = p0[i + 2];
        } else {
          final yv = p0[sy * row0 + sx];
          int u, v;
          if (format == 1) {
            final k = (sy >> 1) * row1 + (sx >> 1) * 2; // U, V xen kẽ
            u = p1[k] - 128;
            v = p1[k + 1] - 128;
          } else {
            final k = (sy >> 1) * row1 + (sx >> 1) * px1;
            u = p1[k] - 128;
            v = p2[k] - 128;
          }
          r = (yv + 1.370705 * v).round().clamp(0, 255);
          g = (yv - 0.337633 * u - 0.698001 * v).round().clamp(0, 255);
          b = (yv + 1.732446 * u).round().clamp(0, 255);
        }
        sink(index++, r, g, b);
      }
    }
    return true;
  }
}
