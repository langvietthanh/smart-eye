import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:smart_eye/utils/image_utils.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// Ảnh YUV 2×2 màu xám (U = V = 128 → R = G = B = Y):
///   (0,0)=10  (1,0)=20
///   (0,1)=30  (1,1)=40
CameraImage grayImage() {
  Map<String, dynamic> plane(List<int> bytes, int bytesPerRow, int w, int h) =>
      {
        'bytes': Uint8List.fromList(bytes),
        'bytesPerRow': bytesPerRow,
        'bytesPerPixel': 1,
        'width': w,
        'height': h,
      };
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

List<int> toBytes(Iterable<double> v) =>
    v.map((e) => (e * 255).round()).toList();

Map<String, dynamic> _plane(
  List<int> bytes,
  int bytesPerRow, {
  int? bytesPerPixel,
}) => {
  'bytes': Uint8List.fromList(bytes),
  'bytesPerRow': bytesPerRow,
  'bytesPerPixel': bytesPerPixel,
};

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
        255,
        0,
        0,
        255,
        /**/ 255,
        255,
        255,
        255,
        /**/ 9,
        9,
        9,
        9, // hàng 1 + đệm
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

Float32List getFloat32(
  CameraImage image,
  int size,
  bool channelsFirst,
  int rotation,
) {
  final bytes = ImageUtils.cameraImageToModelBytes(
    image,
    size: size,
    channelsFirst: channelsFirst,
    inputType: TensorType.float32,
    scale: 0.0,
    zeroPoint: 0,
    rotationDegrees: rotation,
  )!;
  return Float32List.view(
    bytes.buffer,
    bytes.offsetInBytes,
    bytes.lengthInBytes ~/ 4,
  );
}

Uint8List? getQuantized(
  CameraImage image, {
  TensorType type = TensorType.uint8,
  double scale = 1 / 255,
  int zeroPoint = 0,
  bool channelsFirst = false,
  Uint8List? outputBuffer,
}) => ImageUtils.cameraImageToModelBytes(
  image,
  size: 2,
  channelsFirst: channelsFirst,
  inputType: type,
  scale: scale,
  zeroPoint: zeroPoint,
  rotationDegrees: 0,
  outputBuffer: outputBuffer,
);

void main() {
  test('NCHW: 3 mặt phẳng R, G, B liên tiếp', () {
    final out = getFloat32(grayImage(), 2, true, 0);
    expect(out.length, 12);
    expect(toBytes(out.sublist(0, 4)), [10, 20, 30, 40]); // R
    expect(toBytes(out.sublist(8, 12)), [10, 20, 30, 40]); // B
  });

  test('NHWC: mỗi pixel 3 kênh liền nhau', () {
    final out = getFloat32(grayImage(), 2, false, 0);
    expect(toBytes(out.sublist(0, 6)), [10, 10, 10, 20, 20, 20]);
  });

  test('xoay 90° theo chiều kim đồng hồ (camera Android cầm dọc)', () {
    final out = getFloat32(grayImage(), 2, true, 90);
    // Ảnh sau khi xoay:  30 10 / 40 20
    expect(toBytes(out.sublist(0, 4)), [30, 10, 40, 20]);
  });

  test('BGRA (iOS): đúng thứ tự kênh, bỏ qua byte đệm cuối hàng', () {
    final out = getFloat32(bgraImage(), 2, true, 0);
    expect(toBytes(out.sublist(0, 4)), [255, 0, 0, 255]); // R
    expect(toBytes(out.sublist(4, 8)), [0, 255, 0, 255]); // G
    expect(toBytes(out.sublist(8, 12)), [0, 0, 255, 255]); // B
  });

  test('NV12 (iOS yuv420): đọc lớp UV xen kẽ', () {
    final out = getFloat32(nv12GrayImage(), 2, true, 0);
    expect(toBytes(out.sublist(0, 4)), [10, 20, 30, 40]);
  });

  test('góc xoay frame: iOS luôn 0 (plugin đã xoay sẵn), Android bù theo hướng máy', () {
    int rot({required bool ios, int device = 0, bool front = false}) =>
        ImageUtils.frameRotation(
          isIOS: ios,
          sensorOrientation: 90,
          deviceDegrees: device,
          frontCamera: front,
        );
    expect(rot(ios: true), 0);
    expect(rot(ios: true, device: 90), 0);
    expect(rot(ios: false), 90); // Android cầm dọc
    expect(rot(ios: false, device: 90), 0); // Android landscapeLeft
    expect(rot(ios: false, device: 270), 180); // Android landscapeRight
    expect(rot(ios: false, front: true), 90);
  });

  test('xoay 180° và 270°', () {
    final r180 = getFloat32(grayImage(), 2, true, 180);
    expect(toBytes(r180.sublist(0, 4)), [40, 30, 20, 10]);
    final r270 = getFloat32(grayImage(), 2, true, 270);
    expect(toBytes(r270.sublist(0, 4)), [20, 40, 10, 30]);
  });

  test('rotation resizes a non-square frame in its rotated dimensions', () {
    // ignore: deprecated_member_use
    final image = CameraImage.fromPlatformData({
      'format': 35,
      'width': 4,
      'height': 2,
      'planes': [
        _plane([10, 20, 30, 40, 50, 60, 70, 80], 4),
        _plane([128, 128], 2),
        _plane([128, 128], 2),
      ],
    });
    expect(toBytes(getFloat32(image, 2, true, 90).take(4)), [50, 10, 70, 30]);
    expect(toBytes(getFloat32(image, 2, true, 270).take(4)), [40, 80, 20, 60]);
  });

  test('JPEG keeps the RGB colors and clockwise rotation of padded BGRA', () {
    final bytes = ImageUtils.cameraImageToJpeg(
      bgraImage(),
      rotationDegrees: 90,
      maxSide: 32,
    )!;
    final jpeg = img.decodeJpg(bytes)!;
    expect([jpeg.width, jpeg.height], [32, 32]);
    final blue = jpeg.getPixel(8, 8);
    final red = jpeg.getPixel(24, 8);
    expect(blue.b, greaterThan(235));
    expect(blue.r, lessThan(20));
    expect(blue.g, lessThan(20));
    expect(red.r, greaterThan(235));
    expect(red.g, lessThan(20));
    expect(red.b, lessThan(20));
  });

  test('uint8 preserves colors above 127 instead of selecting int8', () {
    expect(getQuantized(bgraImage()), [
      255,
      0,
      0,
      0,
      255,
      0,
      0,
      0,
      255,
      255,
      255,
      255,
    ]);
    expect(getQuantized(bgraImage(), channelsFirst: true), [
      255,
      0,
      0,
      255,
      0,
      255,
      0,
      255,
      0,
      0,
      255,
      255,
    ]);
  });

  test('int8 uses signed values and preserves the raw tensor bytes', () {
    final out = getQuantized(
      bgraImage(),
      type: TensorType.int8,
      zeroPoint: -128,
    )!;
    expect(Int8List.view(out.buffer, out.offsetInBytes, out.length), [
      127,
      -128,
      -128,
      -128,
      127,
      -128,
      -128,
      -128,
      127,
      127,
      127,
      127,
    ]);
    expect(out.take(3), [127, 128, 128]);
  });

  test('quantization clamps both ends for uint8 and int8', () {
    expect(getQuantized(bgraImage(), scale: 1 / 510, zeroPoint: -10), [
      255,
      0,
      0,
      0,
      255,
      0,
      0,
      0,
      255,
      255,
      255,
      255,
    ]);
    final out = getQuantized(
      bgraImage(),
      type: TensorType.int8,
      scale: 1 / 510,
      zeroPoint: -200,
    )!;
    expect(Int8List.view(out.buffer, out.offsetInBytes, out.length), [
      127,
      -128,
      -128,
      -128,
      127,
      -128,
      -128,
      -128,
      127,
      127,
      127,
      127,
    ]);
  });

  test('quantization rounds using the supplied scale and zero point', () {
    expect(getQuantized(grayImage(), scale: 2 / 255, zeroPoint: 3), [
      8,
      8,
      8,
      13,
      13,
      13,
      18,
      18,
      18,
      23,
      23,
      23,
    ]);
    expect(getQuantized(grayImage(), scale: 0), getQuantized(grayImage()));
  });

  test(
    'quantized output reuses an offset view without touching other bytes',
    () {
      for (final type in [TensorType.uint8, TensorType.int8]) {
        final storage = Uint8List(20)..fillRange(0, 20, 77);
        final buffer = Uint8List.sublistView(storage, 3, 15);
        final out = getQuantized(
          grayImage(),
          type: type,
          outputBuffer: buffer,
        )!;
        expect(identical(out, buffer), isTrue);
        expect(out.offsetInBytes, 3);
        expect(out.lengthInBytes, 12);
        expect(out, [10, 10, 10, 20, 20, 20, 30, 30, 30, 40, 40, 40]);
        expect(storage.take(3), [77, 77, 77]);
        expect(storage.skip(15), [77, 77, 77, 77, 77]);
        getQuantized(bgraImage(), type: type, outputBuffer: buffer);
        expect(out[0], type == TensorType.uint8 ? 255 : 127);
      }
    },
  );

  test(
    'float32 output respects aligned and unaligned views and exact length',
    () {
      for (final offset in [4, 3]) {
        final storage = Uint8List(60)..fillRange(0, 60, 77);
        final out = ImageUtils.cameraImageToModelBytes(
          bgraImage(),
          size: 2,
          channelsFirst: false,
          inputType: TensorType.float32,
          scale: 0,
          zeroPoint: 0,
          rotationDegrees: 0,
          outputBuffer: Uint8List.sublistView(storage, offset),
        )!;
        expect(out.offsetInBytes, offset);
        expect(out.lengthInBytes, 48);
        final data = ByteData.sublistView(out);
        expect(List.generate(12, (i) => data.getFloat32(i * 4, Endian.host)), [
          1,
          0,
          0,
          0,
          1,
          0,
          0,
          0,
          1,
          1,
          1,
          1,
        ]);
        expect(storage.take(offset), everyElement(77));
        expect(storage.skip(offset + 48), everyElement(77));
        out[0] = 19;
        expect(storage[offset], 19);
      }
    },
  );

  test(
    'unsupported types, invalid scales and undersized buffers fail safely',
    () {
      expect(getQuantized(grayImage(), type: TensorType.int32), isNull);
      expect(getQuantized(grayImage(), scale: double.nan), isNull);
      expect(getQuantized(grayImage(), scale: double.infinity), isNull);
      expect(getQuantized(grayImage(), scale: -1), isNull);
      final buffer = Uint8List(11)..fillRange(0, 11, 77);
      expect(getQuantized(grayImage(), outputBuffer: buffer), isNull);
      expect(buffer, everyElement(77));
    },
  );

  test('YUV uses independent row and pixel strides for Y, U and V', () {
    // Samples at (0,0), (2,0), (0,2), (2,2); padding bytes are deliberately 0.
    final y = List<int>.filled(40, 0);
    y[0] = 100;
    y[4] = 110;
    y[20] = 120;
    y[24] = 130;
    // ignore: deprecated_member_use
    final image = CameraImage.fromPlatformData({
      'format': 35,
      'width': 4,
      'height': 4,
      'planes': [
        _plane(y, 10, bytesPerPixel: 2),
        _plane([128, 255, 0, 0, 0, 128, 0], 4, bytesPerPixel: 1),
        _plane([128, 0, 128, 0, 0, 255, 0, 0], 5, bytesPerPixel: 2),
      ],
    });
    expect(getQuantized(image), [
      100,
      100,
      100,
      110,
      67,
      255,
      255,
      75,
      0,
      0,
      219,
      130,
    ]);
  });

  test('NV12 color samples respect padded rows and pixel strides', () {
    final y = List<int>.filled(40, 0);
    y[0] = 100;
    y[4] = 110;
    y[20] = 120;
    y[24] = 130;
    // ignore: deprecated_member_use
    final image = CameraImage.fromPlatformData({
      'format': 875704438,
      'width': 4,
      'height': 4,
      'planes': [
        _plane(y, 10, bytesPerPixel: 2),
        _plane(
          [
            128,
            128,
            0,
            0,
            255,
            128,
            0,
            0,
            0,
            0,
            0,
            255,
            0,
            0,
            128,
            0,
            0,
            0,
            0,
            0,
          ],
          10,
          bytesPerPixel: 4,
        ),
      ],
    });
    expect(getQuantized(image), [
      100,
      100,
      100,
      110,
      67,
      255,
      255,
      75,
      0,
      0,
      219,
      130,
    ]);
  });
}
