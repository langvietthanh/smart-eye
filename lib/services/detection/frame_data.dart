import 'dart:isolate';
import 'dart:typed_data';

import 'package:camera/camera.dart';

/// 1 lớp (plane) dữ liệu ảnh
class PlaneData {
  final Uint8List bytes;
  final int bytesPerRow;

  /// Khoảng cách giữa 2 pixel liền kề (chỉ có trên Android); null trên iOS
  final int? bytesPerPixel;

  const PlaneData(this.bytes, this.bytesPerRow, [this.bytesPerPixel]);
}

/// Bản sao 1 frame camera, không phụ thuộc bộ đệm của plugin camera
/// (bộ đệm đó chỉ hợp lệ trong lúc callback đang chạy).
///
/// Nhận biết định dạng qua số lớp: 1 = BGRA8888 (iOS), 2 = NV12 (iOS yuv420), 3 = YUV_420_888 (Android).
class FrameData {
  final int width;
  final int height;
  final List<PlaneData> planes;

  const FrameData({required this.width, required this.height, required this.planes});
}

/// Gói frame để gửi sang isolate AI: copy đúng 1 lần vào [TransferableTypedData],
/// sau đó chuyển quyền sở hữu sang isolate kia mà không copy thêm.
class FramePacket {
  final int width;
  final int height;
  final List<({TransferableTypedData data, int bytesPerRow, int? bytesPerPixel})> planes;

  FramePacket._(this.width, this.height, this.planes);

  factory FramePacket.fromCameraImage(CameraImage image) => FramePacket._(
        image.width,
        image.height,
        [
          for (final p in image.planes)
            (
              data: TransferableTypedData.fromList([p.bytes]),
              bytesPerRow: p.bytesPerRow,
              bytesPerPixel: p.bytesPerPixel,
            ),
        ],
      );

  /// Mở gói ở phía nhận — chỉ gọi được 1 lần
  FrameData open() => FrameData(
        width: width,
        height: height,
        planes: [
          for (final p in planes)
            PlaneData(p.data.materialize().asUint8List(), p.bytesPerRow, p.bytesPerPixel),
        ],
      );
}

