import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

// Packed RGB avoids allocating a record for every sampled pixel.
typedef _PixelReader = int Function(int x, int y);

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

  /// Chuyển CameraImage thành byte của tensor float32, int8 hoặc uint8.
  /// [outputBuffer] được tái sử dụng khi đủ lớn; kết quả chỉ chứa đúng số byte
  /// của tensor và giữ nguyên offset của buffer. Caller không được sửa buffer
  /// trong khi inference đang đọc nó. Trả null cho frame/metadata không hợp lệ.
  static Uint8List? cameraImageToModelBytes(
    CameraImage image, {
    required int size,
    required bool channelsFirst,
    required TensorType inputType,
    required double scale,
    required int zeroPoint,
    int rotationDegrees = 90,
    Uint8List? outputBuffer,
  }) {
    try {
      final bool isFloat32 = inputType == TensorType.float32;
      final bool isInt8 = inputType == TensorType.int8;
      if ((!isFloat32 && !isInt8 && inputType != TensorType.uint8) ||
          size <= 0 ||
          image.width <= 0 ||
          image.height <= 0 ||
          (!isFloat32 && (!scale.isFinite || scale < 0))) {
        return null;
      }
      final read = _readerFor(image);
      if (read == null) return null;
      final int srcW = image.width;
      final int srcH = image.height;
      final bool swap = rotationDegrees == 90 || rotationDegrees == 270;
      final int rotW = swap ? srcH : srcW;
      final int rotH = swap ? srcW : srcH;

      final int plane = size * size;
      final int byteLength = 3 * plane * (isFloat32 ? 4 : 1);
      if (outputBuffer != null && outputBuffer.lengthInBytes < byteLength) {
        return null;
      }
      final Uint8List output = outputBuffer == null
          ? Uint8List(byteLength)
          : outputBuffer.lengthInBytes == byteLength
          ? outputBuffer
          : Uint8List.sublistView(outputBuffer, 0, byteLength);
      final bool alignedFloat = isFloat32 && output.offsetInBytes % 4 == 0;
      final Float32List? fOut = alignedFloat
          ? Float32List.view(output.buffer, output.offsetInBytes, 3 * plane)
          : null;
      // ByteData also supports an unaligned slice supplied by the caller.
      final ByteData? unalignedFloat = isFloat32 && !alignedFloat
          ? ByteData.sublistView(output)
          : null;
      final List<int>? qOut = isFloat32
          ? null
          : isInt8
          ? Int8List.view(output.buffer, output.offsetInBytes, 3 * plane)
          : output;

      final double effectiveScale = scale == 0 ? (1.0 / 255.0) : scale;
      final double multiplier = 1.0 / (255.0 * effectiveScale);
      if (!isFloat32 && !multiplier.isFinite) return null;
      final int quantizedMin = isInt8 ? -128 : 0;
      final int quantizedMax = isInt8 ? 127 : 255;
      final int greenOffset = channelsFirst ? plane : 1;
      final int blueOffset = channelsFirst ? 2 * plane : 2;

      for (int y = 0; y < size; y++) {
        final int ry = y * rotH ~/ size;
        for (int x = 0; x < size; x++) {
          final int rx = x * rotW ~/ size;
          // Keep the public coordinate helper, but avoid its record in the hot loop.
          final int sx = switch (rotationDegrees) {
            90 => ry,
            180 => srcW - 1 - rx,
            270 => srcW - 1 - ry,
            _ => rx,
          };
          final int sy = switch (rotationDegrees) {
            90 => srcH - 1 - rx,
            180 => srcH - 1 - ry,
            270 => rx,
            _ => ry,
          };
          final int rgb = read(sx, sy);
          final int r = rgb >> 16;
          final int g = (rgb >> 8) & 255;
          final int b = rgb & 255;
          final int p = y * size + x;
          final int rIndex = channelsFirst ? p : p * 3;
          final int gIndex = rIndex + greenOffset;
          final int bIndex = rIndex + blueOffset;

          if (isFloat32) {
            if (fOut != null) {
              fOut[rIndex] = r / 255.0;
              fOut[gIndex] = g / 255.0;
              fOut[bIndex] = b / 255.0;
            } else {
              unalignedFloat!.setFloat32(rIndex * 4, r / 255.0, Endian.host);
              unalignedFloat.setFloat32(gIndex * 4, g / 255.0, Endian.host);
              unalignedFloat.setFloat32(bIndex * 4, b / 255.0, Endian.host);
            }
          } else {
            qOut![rIndex] = (r * multiplier + zeroPoint)
                .clamp(quantizedMin, quantizedMax)
                .round();
            qOut[gIndex] = (g * multiplier + zeroPoint)
                .clamp(quantizedMin, quantizedMax)
                .round();
            qOut[bIndex] = (b * multiplier + zeroPoint)
                .clamp(quantizedMin, quantizedMax)
                .round();
          }
        }
      }
      return output;
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
          thumb.setPixelRgb(x, y, rgb >> 16, (rgb >> 8) & 255, rgb & 255);
        }
      }
      return img.encodeJpg(thumb, quality: 70);
    } catch (e) {
      return null;
    }
  }

  /// Toạ độ (rx, ry) trên ảnh đã xoay chiều kim đồng hồ [rotationDegrees] → toạ độ trên ảnh gốc
  static ({int x, int y}) sourceCoord(
    int rx,
    int ry,
    int srcW,
    int srcH,
    int rotationDegrees,
  ) {
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
        return (bytes[i + 2] << 16) | (bytes[i + 1] << 8) | bytes[i];
      };
    }

    if (planes.length == 2) {
      // NV12: lớp Y + lớp CbCr xen kẽ (U, V, U, V...) ở nửa độ phân giải
      final yBytes = planes[0].bytes;
      final int yRow = planes[0].bytesPerRow;
      final int yPixel = planes[0].bytesPerPixel ?? 1;
      final uvBytes = planes[1].bytes;
      final int uvRow = planes[1].bytesPerRow;
      final int uvPixel = planes[1].bytesPerPixel ?? 2;
      return (x, y) {
        final int uv = (y >> 1) * uvRow + (x >> 1) * uvPixel;
        return _yuvToRgb(
          yBytes[y * yRow + x * yPixel],
          uvBytes[uv],
          uvBytes[uv + 1],
        );
      };
    }

    if (planes.length >= 3) {
      // YUV_420_888 (Android): U và V ở 2 lớp riêng, khoảng cách pixel theo bytesPerPixel
      final yBytes = planes[0].bytes;
      final int yRow = planes[0].bytesPerRow;
      final int yPixel = planes[0].bytesPerPixel ?? 1;
      final uBytes = planes[1].bytes;
      final vBytes = planes[2].bytes;
      final int uRow = planes[1].bytesPerRow;
      final int uPixel = planes[1].bytesPerPixel ?? 1;
      final int vRow = planes[2].bytesPerRow;
      final int vPixel = planes[2].bytesPerPixel ?? 1;
      return (x, y) {
        final int u = (y >> 1) * uRow + (x >> 1) * uPixel;
        final int v = (y >> 1) * vRow + (x >> 1) * vPixel;
        return _yuvToRgb(yBytes[y * yRow + x * yPixel], uBytes[u], vBytes[v]);
      };
    }
    return null;
  }

  static int _yuvToRgb(int yValue, int u, int v) {
    final int uValue = u - 128;
    final int vValue = v - 128;
    final int r = (yValue + 1.370705 * vValue).round().clamp(0, 255);
    final int g = (yValue - 0.337633 * uValue - 0.698001 * vValue)
        .round()
        .clamp(0, 255);
    final int b = (yValue + 1.732446 * uValue).round().clamp(0, 255);
    return (r << 16) | (g << 8) | b;
  }
}
