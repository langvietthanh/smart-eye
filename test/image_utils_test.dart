import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/utils/image_utils.dart';

/// Ảnh YUV 2×2 màu xám (U = V = 128 → R = G = B = Y):
///   (0,0)=10  (1,0)=20
///   (0,1)=30  (1,1)=40
CameraImage grayImage() {
  Map<String, dynamic> plane(List<int> bytes, int bytesPerRow, int w, int h) =>
      {'bytes': Uint8List.fromList(bytes), 'bytesPerRow': bytesPerRow, 'bytesPerPixel': 1, 'width': w, 'height': h};
  // ignore: deprecated_member_use
  return CameraImage.fromPlatformData({
    'format': 35, // YUV_420_888
    'width': 2,
    'height': 2,
    'planes': [
      plane([10, 20, 30, 40], 2, 2, 2),
      plane([128], 1, 1, 1),
      plane([128], 1, 1, 1),
    ],
  });
}

List<int> toBytes(Iterable<double> v) => v.map((e) => (e * 255).round()).toList();

void main() {
  test('NCHW: 3 mặt phẳng R, G, B liên tiếp', () {
    final out = ImageUtils.cameraImageToFloat32(grayImage(), size: 2, channelsFirst: true, rotationDegrees: 0)!;
    expect(out.length, 12);
    expect(toBytes(out.sublist(0, 4)), [10, 20, 30, 40]); // R
    expect(toBytes(out.sublist(8, 12)), [10, 20, 30, 40]); // B
  });

  test('NHWC: mỗi pixel 3 kênh liền nhau', () {
    final out = ImageUtils.cameraImageToFloat32(grayImage(), size: 2, channelsFirst: false, rotationDegrees: 0)!;
    expect(toBytes(out.sublist(0, 6)), [10, 10, 10, 20, 20, 20]);
  });

  test('xoay 90° theo chiều kim đồng hồ (camera Android cầm dọc)', () {
    final out = ImageUtils.cameraImageToFloat32(grayImage(), size: 2, channelsFirst: true, rotationDegrees: 90)!;
    // Ảnh sau khi xoay:  30 10 / 40 20
    expect(toBytes(out.sublist(0, 4)), [30, 10, 40, 20]);
  });

  test('xoay 180° và 270°', () {
    final r180 = ImageUtils.cameraImageToFloat32(grayImage(), size: 2, channelsFirst: true, rotationDegrees: 180)!;
    expect(toBytes(r180.sublist(0, 4)), [40, 30, 20, 10]);
    final r270 = ImageUtils.cameraImageToFloat32(grayImage(), size: 2, channelsFirst: true, rotationDegrees: 270)!;
    expect(toBytes(r270.sublist(0, 4)), [20, 40, 10, 30]);
  });
}
