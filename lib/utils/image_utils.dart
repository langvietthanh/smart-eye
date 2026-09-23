import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

/// Các tiện ích xử lý ảnh: lấy mẫu trực tiếp YUV420 → RGB đã xoay → tensor float32 / JPEG
class ImageUtils {
  /// Chuyển CameraImage (YUV_420_888) thành tensor float32 [0..1] kích thước [size]×[size].
  /// Layout theo model: [channelsFirst] = NCHW `[1, 3, S, S]`, ngược lại NHWC `[1, S, S, 3]`.
  /// [rotationDegrees]: góc xoay ảnh (0, 90, 180, 270) để ảnh đứng thẳng như người dùng nhìn.
  static Float32List? cameraImageToFloat32(
    CameraImage image, {
    required int size,
    required bool channelsFirst,
    int rotationDegrees = 90,
  }) {
    try {
      if (image.planes.length < 3) return null;
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
          final rgb = _yuvPixel(image, src.x, src.y);
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
  /// đã xoay đúng chiều. Lấy mẫu trực tiếp từ YUV nên rất nhẹ.
  static Uint8List? cameraImageToJpeg(
    CameraImage image, {
    int rotationDegrees = 90,
    int maxSide = 320,
  }) {
    try {
      if (image.planes.length < 3) return null;
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
          final rgb = _yuvPixel(image, src.x, src.y);
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

  static ({int r, int g, int b}) _yuvPixel(CameraImage image, int x, int y) {
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    final int uvIndex = (y ~/ 2) * uPlane.bytesPerRow + (x ~/ 2) * (uPlane.bytesPerPixel ?? 1);

    final int yValue = yPlane.bytes[y * yPlane.bytesPerRow + x] & 0xFF;
    final int uValue = (uPlane.bytes[uvIndex] & 0xFF) - 128;
    final int vValue = (vPlane.bytes[uvIndex] & 0xFF) - 128;

    return (
      r: (yValue + 1.370705 * vValue).round().clamp(0, 255),
      g: (yValue - 0.337633 * uValue - 0.698001 * vValue).round().clamp(0, 255),
      b: (yValue + 1.732446 * uValue).round().clamp(0, 255),
    );
  }
}
