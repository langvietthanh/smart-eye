import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/services/detection/frame_data.dart';
import 'package:smart_eye/utils/image_utils.dart';

/// Frame YUV_420_888 (Android) 2×2 màu xám (U = V = 128 → R = G = B = Y):
///   (0,0)=10  (1,0)=20
///   (0,1)=30  (1,1)=40
FrameData grayYuv() => FrameData(width: 2, height: 2, planes: [
      PlaneData(Uint8List.fromList([10, 20, 30, 40]), 2, 1),
      PlaneData(Uint8List.fromList([128]), 1, 1),
      PlaneData(Uint8List.fromList([128]), 1, 1),
    ]);

/// Frame BGRA 2×2 của iOS, mỗi hàng có 4 byte đệm (bytesPerRow = 12 > 2 × 4):
///   (0,0)=đỏ  (1,0)=xanh lá
///   (0,1)=xanh dương  (1,1)=trắng
FrameData bgra() => FrameData(width: 2, height: 2, planes: [
      PlaneData(
          Uint8List.fromList([
            0, 0, 255, 255, /**/ 0, 255, 0, 255, /**/ 9, 9, 9, 9, // hàng 0 + đệm
            255, 0, 0, 255, /**/ 255, 255, 255, 255, /**/ 9, 9, 9, 9, // hàng 1 + đệm
          ]),
          12),
    ]);

/// Frame NV12 2×2 (iOS yuv420): lớp Y + lớp UV xen kẽ, bytesPerPixel = null như trên iOS
FrameData nv12Gray() => FrameData(width: 2, height: 2, planes: [
      PlaneData(Uint8List.fromList([10, 20, 30, 40]), 2),
      PlaneData(Uint8List.fromList([128, 128]), 2),
    ]);

/// Frame xám 4×4 giá trị Y = 10 × (vị trí + 1) — để thử cắt vùng
FrameData gray4x4() => FrameData(width: 4, height: 4, planes: [
      PlaneData(Uint8List.fromList(List.generate(16, (i) => 10 * (i + 1))), 4, 1),
      PlaneData(Uint8List.fromList([128, 128, 128, 128]), 2, 1),
      PlaneData(Uint8List.fromList([128, 128, 128, 128]), 2, 1),
    ]);

List<int> toBytes(Iterable<double> v) => v.map((e) => (e * 255).round()).toList();

Float32List tensor(FrameData f, {int size = 2, bool nchw = true, int rotation = 0, CropRect crop = CropRect.full}) =>
    ImageUtils.toInputTensor(f, size: size, channelsFirst: nchw, rotationDegrees: rotation, crop: crop)!;

void main() {
  group('Định dạng frame', () {
    test('NCHW: 3 mặt phẳng R, G, B liên tiếp', () {
      final out = tensor(grayYuv());
      expect(out.length, 12);
      expect(toBytes(out.sublist(0, 4)), [10, 20, 30, 40]); // R
      expect(toBytes(out.sublist(8, 12)), [10, 20, 30, 40]); // B
    });

    test('NHWC: mỗi pixel 3 kênh liền nhau', () {
      expect(toBytes(tensor(grayYuv(), nchw: false).sublist(0, 6)), [10, 10, 10, 20, 20, 20]);
    });

    test('BGRA (iOS): đúng thứ tự kênh, bỏ qua byte đệm cuối hàng', () {
      final out = tensor(bgra());
      expect(toBytes(out.sublist(0, 4)), [255, 0, 0, 255]); // R
      expect(toBytes(out.sublist(4, 8)), [0, 255, 0, 255]); // G
      expect(toBytes(out.sublist(8, 12)), [0, 0, 255, 255]); // B
    });

    test('NV12 (iOS yuv420): đọc lớp UV xen kẽ', () {
      expect(toBytes(tensor(nv12Gray()).sublist(0, 4)), [10, 20, 30, 40]);
    });

    test('frame không có lớp nào → null, không ném lỗi', () {
      expect(ImageUtils.toInputTensor(const FrameData(width: 2, height: 2, planes: []), size: 2, channelsFirst: true),
          isNull);
    });
  });

  group('Xoay', () {
    test('xoay 90° theo chiều kim đồng hồ (camera Android cầm dọc)', () {
      // Ảnh sau khi xoay:  30 10 / 40 20
      expect(toBytes(tensor(grayYuv(), rotation: 90).sublist(0, 4)), [30, 10, 40, 20]);
    });

    test('xoay 180° và 270°', () {
      expect(toBytes(tensor(grayYuv(), rotation: 180).sublist(0, 4)), [40, 30, 20, 10]);
      expect(toBytes(tensor(grayYuv(), rotation: 270).sublist(0, 4)), [20, 40, 10, 30]);
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
  });

  group('Cắt vùng (ROI)', () {
    test('cắt góc dưới phải 2×2 của ảnh 4×4', () {
      final out = tensor(gray4x4(), crop: const CropRect(0.5, 0.5, 0.5, 0.5));
      // Hàng 2: 110 120, hàng 3: 150 160
      expect(toBytes(out.sublist(0, 4)), [110, 120, 150, 160]);
    });

    test('vùng hành lang là hình vuông trên ảnh thật, nằm giữa theo chiều ngang', () {
      final c = CropRect.corridor(frameWidth: 480, frameHeight: 720);
      expect(c.width * 480, closeTo(c.height * 720, 0.001)); // vuông tính theo pixel
      expect(c.width * 480, closeTo(288, 0.001)); // 60% cạnh ngắn
      expect(c.left + c.width / 2, closeTo(0.5, 1e-9));
      expect(c.top, greaterThanOrEqualTo(0));
      expect(c.bottom, lessThanOrEqualTo(1));
    });
  });

  group('Chữ ký độ sáng (phát hiện cảnh đứng yên)', () {
    test('cùng ảnh → 0, ảnh khác → > 0', () {
      final a = ImageUtils.lumaSignature(gray4x4(), grid: 4)!;
      final b = ImageUtils.lumaSignature(gray4x4(), grid: 4)!;
      expect(ImageUtils.signatureDiff(a, b), 0);
      final c = ImageUtils.lumaSignature(grayYuv(), grid: 4)!;
      expect(ImageUtils.signatureDiff(a, c), greaterThan(0.1));
    });
  });

  test('JPEG thumbnail tạo được và đúng chữ ký JPEG', () {
    final jpg = ImageUtils.toJpeg(gray4x4(), maxSide: 8);
    expect(jpg, isNotNull);
    expect(jpg!.sublist(0, 2), [0xFF, 0xD8]);
  });
}
