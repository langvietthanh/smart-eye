import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../models/scene_info.dart';
import '../services/lidar_analysis.dart';
import '../services/visual_proximity.dart';

/// Vẽ khung vật thể (màu theo mức nguy hiểm) + vạch lối đi kiểu camera lùi.
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
  final PathCorridor _corridor;

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
           .toList(growable: false),
       _corridor = scene.corridor ?? PathCorridor.typical;

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

  /// Tô mờ vùng bị chắn (trái / lối đi / phải) trong vùng bước chân, và
  /// vạch hai mép lối đi 70 cm hội tụ về đường chân trời như camera lùi.
  void _paintColumns(Canvas canvas, Size size) {
    final top = VisualProximity.walkingRegionTop;
    Offset at(double x, double y) => Offset(x * size.width, y * size.height);
    final (l0, r0) = _corridor.span(top, LidarAnalysis.halfWidth);
    final (l1, r1) = _corridor.span(1, LidarAnalysis.halfWidth);
    final regions = [
      [at(0, top), at(l0, top), at(l1, 1), at(0, 1)],
      [at(l0, top), at(r0, top), at(r1, 1), at(l1, 1)],
      [at(r0, top), at(1, top), at(1, 1), at(r1, 1)],
    ];
    for (int c = 0; c < 3; c++) {
      final load = _columns[c];
      if (load < 1.0) continue;
      canvas.drawPath(
        Path()..addPolygon(regions[c], true),
        Paint()
          ..color = (load >= 2 ? Colors.red : Colors.orange).withValues(
            alpha: 0.12,
          ),
      );
    }
    final line = Paint()
      ..color = Colors.white54
      ..strokeWidth = 2;
    final horizon = _corridor.horizonY.clamp(0.0, top);
    final apex = at(0.5, horizon);
    canvas.drawLine(apex, at(l1, 1), line);
    canvas.drawLine(apex, at(r1, 1), line);
  }

  @override
  bool shouldRepaint(covariant BoundingBoxPainter oldDelegate) =>
      alertSubject != oldDelegate.alertSubject ||
      alertLevel != oldDelegate.alertLevel ||
      !listEquals(_objects, oldDelegate._objects) ||
      !listEquals(_columns, oldDelegate._columns) ||
      _corridor != oldDelegate._corridor;
}
