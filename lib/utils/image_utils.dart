import 'dart:typed_data';
import 'package:camera/camera.dart';

/// Các tiện ích xử lý ảnh: YUV420 → RGB → Resize → Normalize float32
class ImageUtils {
  /// Hằng số kích thước input của YOLOv8
  static const int inputSize = 640;

  /// Chuyển CameraImage (YUV_420_888) thành Float32List shape [1, 640, 640, 3].
  /// [rotationDegrees]: góc xoay ảnh (0, 90, 180, 270). Mặc định là 90° để khớp với Android Portrait camera.
  static Float32List? cameraImageToFloat32(
    CameraImage image, {
    int rotationDegrees = 90,
  }) {
    try {
      final rgbBytes = _convertYUV420ToRGB(image);
      if (rgbBytes == null) return null;

      return _resizeAndNormalize(
        rgbBytes,
        srcWidth: image.width,
        srcHeight: image.height,
        rotationDegrees: rotationDegrees,
      );
    } catch (e) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  static Uint8List? _convertYUV420ToRGB(CameraImage image) {
    if (image.planes.length < 3) return null;

    final int width = image.width;
    final int height = image.height;

    final Plane yPlane = image.planes[0];
    final Plane uPlane = image.planes[1];
    final Plane vPlane = image.planes[2];

    final Uint8List yBytes = yPlane.bytes;
    final Uint8List uBytes = uPlane.bytes;
    final Uint8List vBytes = vPlane.bytes;

    final int yRowStride = yPlane.bytesPerRow;
    final int uvRowStride = uPlane.bytesPerRow;
    final int uvPixelStride = uPlane.bytesPerPixel ?? 1;

    final Uint8List rgb = Uint8List(width * height * 3);
    int rgbIndex = 0;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int yIndex = y * yRowStride + x;
        final int yValue = yBytes[yIndex] & 0xFF;

        final int uvRow = y ~/ 2;
        final int uvCol = x ~/ 2;
        final int uvIndex = uvRow * uvRowStride + uvCol * uvPixelStride;

        final int uValue = (uBytes[uvIndex] & 0xFF) - 128;
        final int vValue = (vBytes[uvIndex] & 0xFF) - 128;

        int r = (yValue + 1.370705 * vValue).round();
        int g = (yValue - 0.337633 * uValue - 0.698001 * vValue).round();
        int b = (yValue + 1.732446 * uValue).round();

        rgb[rgbIndex++] = r.clamp(0, 255);
        rgb[rgbIndex++] = g.clamp(0, 255);
        rgb[rgbIndex++] = b.clamp(0, 255);
      }
    }
    return rgb;
  }

  static Float32List _resizeAndNormalize(
    Uint8List rgbBytes, {
    required int srcWidth,
    required int srcHeight,
    int rotationDegrees = 90,
  }) {
    final Float32List output = Float32List(1 * inputSize * inputSize * 3);
    int outIdx = 0;

    for (int y = 0; y < inputSize; y++) {
      for (int x = 0; x < inputSize; x++) {
        int srcX;
        int srcY;

        if (rotationDegrees == 90) {
          // Xoay 90 độ theo chiều kim đồng hồ
          srcX = (y * srcWidth / inputSize).floor().clamp(0, srcWidth - 1);
          srcY = (srcHeight - 1 - (x * srcHeight / inputSize).floor()).clamp(0, srcHeight - 1);
        } else if (rotationDegrees == 270) {
          // Xoay 270 độ
          srcX = (srcWidth - 1 - (y * srcWidth / inputSize).floor()).clamp(0, srcWidth - 1);
          srcY = (x * srcHeight / inputSize).floor().clamp(0, srcHeight - 1);
        } else if (rotationDegrees == 180) {
          // Xoay 180 độ
          srcX = (srcWidth - 1 - (x * srcWidth / inputSize).floor()).clamp(0, srcWidth - 1);
          srcY = (srcHeight - 1 - (y * srcHeight / inputSize).floor()).clamp(0, srcHeight - 1);
        } else {
          // 0 độ (không xoay)
          srcX = (x * srcWidth / inputSize).floor().clamp(0, srcWidth - 1);
          srcY = (y * srcHeight / inputSize).floor().clamp(0, srcHeight - 1);
        }

        final int srcIdx = (srcY * srcWidth + srcX) * 3;

        output[outIdx++] = rgbBytes[srcIdx] / 255.0;       // R
        output[outIdx++] = rgbBytes[srcIdx + 1] / 255.0;   // G
        output[outIdx++] = rgbBytes[srcIdx + 2] / 255.0;   // B
      }
    }
    return output;
  }
}
