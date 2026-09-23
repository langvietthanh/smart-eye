import 'package:flutter/material.dart';
import '../models/Recognition.dart';

class BoundingBoxPainter extends CustomPainter {
  final List<Recognition> recognitions;

  BoundingBoxPainter(this.recognitions);

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Cọ vẽ khung chữ nhật (Màu đỏ, nét viền)
    final boxPaint = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    // 2. Cọ vẽ nền cho chữ (Màu đỏ, tô kín)
    final textBackgroundPaint = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.fill;

    // Lặp qua tất cả các vật thể AI nhận diện được
    for (var recognition in recognitions) {
      // Tọa độ thật của vật thể trên màn hình
      final rect = recognition.location;

      // --- Vẽ Khung Chữ Nhật ---
      canvas.drawRect(rect, boxPaint);

      // --- Vẽ Nhãn (Tên vật + Độ tự tin) ---
      // Chuẩn bị nội dung chữ
      final textSpan = TextSpan(
        text: '${recognition.label} ${(recognition.score * 100).toStringAsFixed(0)}%',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14.0,
          fontWeight: FontWeight.bold,
        ),
      );

      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();

      // Vẽ nền đỏ lót dưới chữ cho dễ nhìn
      final textBackgroundRect = Rect.fromLTWH(
        rect.left,
        rect.top - textPainter.height, // Đẩy nền lên trên mí của khung
        textPainter.width + 8,         // Rộng hơn chữ một xíu
        textPainter.height + 4,
      );
      canvas.drawRect(textBackgroundRect, textBackgroundPaint);

      // Vẽ chữ đè lên trên nền
      textPainter.paint(
        canvas,
        Offset(rect.left + 4, rect.top - textPainter.height + 2),
      );
    }
  }

  // Hàm này quyết định xem có cần vẽ lại khung không
  // True = Luôn vẽ lại mỗi khi có dữ liệu recognition mới
  @override
  bool shouldRepaint(covariant BoundingBoxPainter oldDelegate) {
    return true; 
  }
}
