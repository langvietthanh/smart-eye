import 'package:flutter/material.dart';

/// Lớp đại diện cho một vật thể AI phát hiện được
class Recognition {
  final int id;           // Số thứ tự của lớp (VD: 0 cho 'người')
  final String label;     // Tên của vật thể (VD: 'Người đi bộ')
  final double score;     // Độ tự tin của AI (từ 0.0 đến 1.0)
  final Rect location;    // Toạ độ của khung chữ nhật (Bounding Box) bao quanh vật
  final String labelEn;   // Nhãn gốc tiếng Anh (VD: 'car') — dùng để phân loại nguy hiểm (F2)

  Recognition(this.id, this.label, this.score, this.location, {this.labelEn = ''});

  /// Helper: Tính xem cái khung này chiếm bao nhiêu % diện tích màn hình
  double getAreaRatio(double screenWidth, double screenHeight) {
    double boxArea = location.width * location.height;
    double screenArea = screenWidth * screenHeight;
    return boxArea / screenArea;
  }

  /// Tỉ lệ chiều cao box / chiều cao khung — cơ sở ước lượng khoảng cách (CN7)
  double getHeightRatio(double screenHeight) => location.height / screenHeight;
}
