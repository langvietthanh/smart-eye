import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../models/scene_info.dart';

/// Vẽ khung vật thể (màu theo mức nguy hiểm) + lưới 3 cột free-space.
/// Phục vụ người nhìn kém, người đi cùng và demo.
class BoundingBoxPainter extends CustomPainter {
  // Tracks mutate between frames. Snapshot only what is painted so comparison
  // with the previous painter does not observe already-mutated track positions.
  final List<
    ({
      int id,
      Rect box,
      String label,
      DistanceLevel distance,
      bool approaching,
      bool relevant,
    })
  >
  _objects;
  final List<int> _columns;

  /// Chủ thể của cảnh báo hiện tại (VD 'track:12') — vật này được tô đậm
  final String? alertSubject;
  final AlertLevel? alertLevel;

  BoundingBoxPainter(
    SceneAssessment scene, {
    this.alertSubject,
    this.alertLevel,
  }) : _objects = scene.objects
           .map(
             (o) => (
               id: o.track.id,
               box: o.track.box,
               label: o.label,
               distance: o.distance,
               approaching: o.approaching,
               relevant: o.isRelevant,
             ),
           )
           .toList(growable: false),
       _columns = scene.columnLoad
           .map((load) => load < 1 ? 0 : (load < 2 ? 1 : 2))
           .toList(growable: false);

  static Color colorOf(AlertLevel? level) => switch (level) {
    AlertLevel.danger => Colors.redAccent,
    AlertLevel.caution => Colors.orangeAccent,
    _ => Colors.lightGreenAccent,
  };

  @override
  void paint(Canvas canvas, Size size) {
    _paintColumns(canvas, size);

    for (final o in _objects) {
      final isAlert = 'track:${o.id}' == alertSubject;
      final color = isAlert
          ? colorOf(alertLevel)
          : (o.relevant ? Colors.lightBlueAccent : Colors.white54);
      final rect = o.box;

      // --- Vẽ Khung Chữ Nhật ---
      canvas.drawRect(
        rect,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = isAlert ? 5.0 : 3.0,
      );

      // --- Vẽ Nhãn (Tên vật + khoảng cách + tới gần) ---
      final textPainter = TextPainter(
        text: TextSpan(
          text: '${o.label} · ${o.distance.vi}${o.approaching ? ' ↑' : ''}',
          style: const TextStyle(
            color: Colors.black,
            fontSize: 14.0,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width);

      final labelTop = (rect.top - textPainter.height - 4).clamp(
        0.0,
        size.height,
      );
      canvas.drawRect(
        Rect.fromLTWH(
          rect.left,
          labelTop,
          textPainter.width + 8,
          textPainter.height + 4,
        ),
        Paint()..color = color,
      );
      textPainter.paint(canvas, Offset(rect.left + 4, labelTop + 2));
      textPainter.dispose();
      textPainter.dispose();
    }
  }

  /// Tô mờ cột bị chắn, viền nhẹ 2 đường chia cột
  void _paintColumns(Canvas canvas, Size size) {
    final colW = size.width / 3;
    for (int c = 0; c < 3; c++) {
      final load = _columns[c];
      if (load < 1.0) continue;
      canvas.drawRect(
        Rect.fromLTWH(c * colW, 0, colW, size.height),
        Paint()
          ..color = (load >= 2 ? Colors.red : Colors.orange).withValues(
            alpha: 0.12,
          ),
      );
    }
    final line = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    for (int c = 1; c < 3; c++) {
      canvas.drawLine(Offset(c * colW, 0), Offset(c * colW, size.height), line);
    }
  }

  @override
  bool shouldRepaint(covariant BoundingBoxPainter oldDelegate) =>
      alertSubject != oldDelegate.alertSubject ||
      alertLevel != oldDelegate.alertLevel ||
      !listEquals(_objects, oldDelegate._objects) ||
      !listEquals(_columns, oldDelegate._columns);
}
