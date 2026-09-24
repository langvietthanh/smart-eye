import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

typedef _PixelReader = ({int r, int g, int b}) Function(int x, int y);

/// Các tiện ích xử lý ảnh: lấy mẫu trực tiếp frame camera → RGB đã xoay → tensor float32 / JPEG.
/// Hỗ trợ 3 định dạng frame:
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

  /// Chuyển CameraImage thành tensor float32 [0..1] kích thước [size]×[size].
  /// Layout theo model: [channelsFirst] = NCHW `[1, 3, S, S]`, ngược lại NHWC `[1, S, S, 3]`.
  /// [rotationDegrees]: góc xoay ảnh (0, 90, 180, 270) để ảnh đứng thẳng như người dùng nhìn.
  static Float32List? cameraImageToFloat32(
    CameraImage image, {
    required int size,
    required bool channelsFirst,
    int rotationDegrees = 90,
  }) {
    try {
      final read = _readerFor(image);
      if (read == null) return null;
      final int srcW = image.width;
      final int srcH = image.height;
      final bool swap = rotationDegrees == 90 || rotationDegrees == 270;
      final int rotW = swap ? srcH : srcW;
      final int rotH = swap ? srcW : srcH;

      final int plane = size * size;
      final Float32List out = Float32List(3 * plane);
      for (int y = 0; y < size; y++) {
        final int ry = (y * rotH ~/ size).clamp(0, rotH - 1);
        for (int x = 0; x < size; x++) {
          final int rx = (x * rotW ~/ size).clamp(0, rotW - 1);
          final src = sourceCoord(rx, ry, srcW, srcH, rotationDegrees);
          final rgb = read(src.x, src.y);
          final int p = y * size + x;
          if (channelsFirst) {
            out[p] = rgb.r / 255.0;
            out[plane + p] = rgb.g / 255.0;
            out[2 * plane + p] = rgb.b / 255.0;
          } else {
            out[p * 3] = rgb.r / 255.0;
            out[p * 3 + 1] = rgb.g / 255.0;
            out[p * 3 + 2] = rgb.b / 255.0;
          }
        }
      }
      return out;
    } catch (e) {
      return null;
    }
  }

  /// CN12 — Tạo ảnh thumbnail JPEG nhỏ (cạnh dài [maxSide] px) từ frame camera,
  /// đã xoay đúng chiều. Lấy mẫu trực tiếp từ frame nên rất nhẹ.
  static Uint8List? cameraImageToJpeg(
    CameraImage image, {
    int rotationDegrees = 90,
    int maxSide = 320,
  }) {
    try {
      final read = _readerFor(image);
      if (read == null) return null;
      final int srcW = image.width;
      final int srcH = image.height;
      final bool swap = rotationDegrees == 90 || rotationDegrees == 270;
      final int rotW = swap ? srcH : srcW;
      final int rotH = swap ? srcW : srcH;
      final double scale = maxSide / (rotW > rotH ? rotW : rotH);
      final int outW = (rotW * scale).round();
      final int outH = (rotH * scale).round();

      final thumb = img.Image(width: outW, height: outH);
      for (int y = 0; y < outH; y++) {
        final int ry = (y / scale).floor().clamp(0, rotH - 1);
        for (int x = 0; x < outW; x++) {
          final int rx = (x / scale).floor().clamp(0, rotW - 1);
          final src = sourceCoord(rx, ry, srcW, srcH, rotationDegrees);
          final rgb = read(src.x, src.y);
          thumb.setPixelRgb(x, y, rgb.r, rgb.g, rgb.b);
        }
      }
      return img.encodeJpg(thumb, quality: 70);
    } catch (e) {
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
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Chọn cách đọc 1 pixel RGB theo định dạng frame (nhận biết qua số lớp — plane)
  static _PixelReader? _readerFor(CameraImage image) {
    final planes = image.planes;

    if (planes.length == 1) {
      // BGRA8888: 4 byte/pixel theo thứ tự B, G, R, A; mỗi hàng có thể có byte đệm
      final bytes = planes[0].bytes;
      final int row = planes[0].bytesPerRow;
      return (x, y) {
        final int i = y * row + x * 4;
        return (r: bytes[i + 2], g: bytes[i + 1], b: bytes[i]);
      };
    }

    if (planes.length == 2) {
      // NV12: lớp Y + lớp CbCr xen kẽ (U, V, U, V...) ở nửa độ phân giải
      final yBytes = planes[0].bytes;
      final int yRow = planes[0].bytesPerRow;
      final uvBytes = planes[1].bytes;
      final int uvRow = planes[1].bytesPerRow;
      return (x, y) {
        final int uv = (y >> 1) * uvRow + (x >> 1) * 2;
        return _yuvToRgb(yBytes[y * yRow + x], uvBytes[uv], uvBytes[uv + 1]);
      };
    }

    if (planes.length >= 3) {
      // YUV_420_888 (Android): U và V ở 2 lớp riêng, khoảng cách pixel theo bytesPerPixel
      final yBytes = planes[0].bytes;
      final int yRow = planes[0].bytesPerRow;
      final uBytes = planes[1].bytes;
      final vBytes = planes[2].bytes;
      final int uvRow = planes[1].bytesPerRow;
      final int uvPixel = planes[1].bytesPerPixel ?? 1;
      return (x, y) {
        final int uv = (y >> 1) * uvRow + (x >> 1) * uvPixel;
        return _yuvToRgb(yBytes[y * yRow + x], uBytes[uv], vBytes[uv]);
      };
    }
    return null;
  }

  static ({int r, int g, int b}) _yuvToRgb(int yValue, int u, int v) {
    final int uValue = u - 128;
    final int vValue = v - 128;
    return (
      r: (yValue + 1.370705 * vValue).round().clamp(0, 255),
      g: (yValue - 0.337633 * uValue - 0.698001 * vValue).round().clamp(0, 255),
      b: (yValue + 1.732446 * uValue).round().clamp(0, 255),
    );
  }
}
