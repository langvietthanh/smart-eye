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

/// Vùng cắt trên ảnh ĐÃ XOAY, toạ độ chuẩn hoá [0..1]
class CropRect {
  final double left;
  final double top;
  final double width;
  final double height;

  const CropRect(this.left, this.top, this.width, this.height);

  static const full = CropRect(0, 0, 1, 1);

  bool get isFull => left == 0 && top == 0 && width == 1 && height == 1;
  double get right => left + width;
  double get bottom => top + height;

  /// Vùng "hành lang" phía trước: hình VUÔNG (để ảnh không bị méo khi đưa vào model),
  /// cạnh = [fraction] × cạnh ngắn của khung, tâm ngang giữa khung, tâm dọc ở [centerY]
  /// (hơi trên giữa — nơi đường đi phía xa xuất hiện khi điện thoại đeo trước ngực).
  factory CropRect.corridor({
    required int frameWidth,
    required int frameHeight,
    double fraction = 0.6,
    double centerY = 0.45,
  }) {
    final side = fraction * (frameWidth < frameHeight ? frameWidth : frameHeight);
    final w = side / frameWidth;
    final h = side / frameHeight;
    final top = (centerY - h / 2).clamp(0.0, 1.0 - h);
    return CropRect((1 - w) / 2, top, w, h);
  }

  @override
  String toString() => 'CropRect($left, $top, $width, $height)';
}
