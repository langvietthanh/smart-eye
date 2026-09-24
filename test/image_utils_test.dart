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

Map<String, dynamic> _plane(List<int> bytes, int bytesPerRow, {int? bytesPerPixel}) =>
    {'bytes': Uint8List.fromList(bytes), 'bytesPerRow': bytesPerRow, 'bytesPerPixel': bytesPerPixel};

/// Frame BGRA 2×2 của iOS, mỗi hàng có 4 byte đệm (bytesPerRow = 12 > 2 × 4):
///   (0,0)=đỏ  (1,0)=xanh lá
///   (0,1)=xanh dương  (1,1)=trắng
CameraImage bgraImage() {
  // ignore: deprecated_member_use
  return CameraImage.fromPlatformData({
    'format': 1111970369, // kCVPixelFormatType_32BGRA
    'width': 2,
    'height': 2,
    'planes': [
      _plane([
        0, 0, 255, 255, /**/ 0, 255, 0, 255, /**/ 9, 9, 9, 9, // hàng 0 + đệm
        255, 0, 0, 255, /**/ 255, 255, 255, 255, /**/ 9, 9, 9, 9, // hàng 1 + đệm
      ], 12),
    ],
  });
}

/// Frame NV12 2×2 (iOS yuv420): lớp Y + lớp UV xen kẽ, bytesPerPixel = null như trên iOS
CameraImage nv12GrayImage() {
  // ignore: deprecated_member_use
  return CameraImage.fromPlatformData({
    'format': 875704438, // kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    'width': 2,
    'height': 2,
    'planes': [
      _plane([10, 20, 30, 40], 2),
      _plane([128, 128], 2),
    ],
  });
}

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

  test('BGRA (iOS): đúng thứ tự kênh, bỏ qua byte đệm cuối hàng', () {
    final out = ImageUtils.cameraImageToFloat32(bgraImage(), size: 2, channelsFirst: true, rotationDegrees: 0)!;
    expect(toBytes(out.sublist(0, 4)), [255, 0, 0, 255]); // R
    expect(toBytes(out.sublist(4, 8)), [0, 255, 0, 255]); // G
    expect(toBytes(out.sublist(8, 12)), [0, 0, 255, 255]); // B
  });

  test('NV12 (iOS yuv420): đọc lớp UV xen kẽ', () {
    final out = ImageUtils.cameraImageToFloat32(nv12GrayImage(), size: 2, channelsFirst: true, rotationDegrees: 0)!;
    expect(toBytes(out.sublist(0, 4)), [10, 20, 30, 40]);
  });

  test('góc xoay frame: iOS luôn 0 (plugin đã xoay sẵn), Android bù theo hướng máy', () {
    int rot({required bool ios, int device = 0, bool front = false}) => ImageUtils.frameRotation(
        isIOS: ios, sensorOrientation: 90, deviceDegrees: device, frontCamera: front);
    expect(rot(ios: true), 0);
    expect(rot(ios: true, device: 90), 0);
    expect(rot(ios: false), 90); // Android cầm dọc
    expect(rot(ios: false, device: 90), 0); // Android landscapeLeft
    expect(rot(ios: false, device: 270), 180); // Android landscapeRight
    expect(rot(ios: false, front: true), 90);
  });

  test('xoay 180° và 270°', () {
    final r180 = ImageUtils.cameraImageToFloat32(grayImage(), size: 2, channelsFirst: true, rotationDegrees: 180)!;
    expect(toBytes(r180.sublist(0, 4)), [40, 30, 20, 10]);
    final r270 = ImageUtils.cameraImageToFloat32(grayImage(), size: 2, channelsFirst: true, rotationDegrees: 270)!;
    expect(toBytes(r270.sublist(0, 4)), [20, 40, 10, 30]);
  });
}
