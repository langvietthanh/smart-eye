import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:smart_eye/models/Recognition.dart';
import 'package:smart_eye/services/lidar_analysis.dart';
import 'package:smart_eye/utils/label_catalog.dart';

/// What a box stands for: only colours and labels depend on it.
enum Kind { desk, chair, person, bag, wall, pillar }

/// Axis-aligned box in metres: x right, y up (floor at 0), z forward along
/// the aisle. Same convention as the ray-cast renderer in the LiDAR tests.
class Box {
  const Box(this.kind, this.x0, this.y0, this.z0, this.x1, this.y1, this.z1);
  final Kind kind;
  final double x0, y0, z0, x1, y1, z1;

  /// Ray parameter of the first hit, or null.
  double? hit(
    double ox,
    double oy,
    double oz,
    double dx,
    double dy,
    double dz,
  ) {
    var tMin = 0.0, tMax = double.infinity;
    for (final (o, d, lo, hi) in [
      (ox, dx, x0, x1),
      (oy, dy, y0, y1),
      (oz, dz, z0, z1),
    ]) {
      if (d.abs() < 1e-12) {
        if (o < lo || o > hi) return null;
        continue;
      }
      var t0 = (lo - o) / d, t1 = (hi - o) / d;
      if (t0 > t1) (t0, t1) = (t1, t0);
      tMin = max(tMin, t0);
      tMax = min(tMax, t1);
      if (tMin > tMax) return null;
    }
    return tMin > 0 ? tMin : null;
  }

  /// Beyond [Phone.range]: too small for YOLO in a real image.
  static bool _far(Box b, double x, double z) {
    final dx = x.clamp(b.x0, b.x1) - x, dz = z.clamp(b.z0, b.z1) - z;
    return dx * dx + dz * dz > Phone.range * Phone.range;
  }

  /// Footprint overlaps a body of [radius] at (x, z); low things (< 15 cm,
  /// what LiDAR treats as floor) are stepped over.
  bool bumps(double x, double z, double radius) {
    if (y1 < 0.15) return false;
    final cx = x.clamp(x0, x1), cz = z.clamp(z0, z1);
    return (x - cx) * (x - cx) + (z - cz) * (z - cz) < radius * radius;
  }
}

class Preset {
  const Preset(
    this.name,
    this.note,
    this.boxes, {
    this.length = 9,
    this.finish = true,
  });
  final String name, note;
  final List<Box> boxes;

  /// Aisle length (end wall at z = length).
  final double length;

  /// The walk ends 1.2 m before the end wall; off to see the wall handling.
  final bool finish;
}

const _deskH = 0.75, _chairH = 0.9, _seatedH = 1.25;

/// A row of desks with seated students (backs to the aisle edge at [edge]),
/// on the left (sign -1) or right (sign 1) of the aisle.
List<Box> _row(
  double sign,
  double edge,
  double length, {
  Set<int> empty = const {},
}) {
  final out = <Box>[];
  double x(double a) => sign * a;
  Box at(Kind k, double a0, double a1, double z0, double z1, double h) {
    final xa = x(a0), xb = x(a1);
    return Box(k, min(xa, xb), 0, z0, max(xa, xb), h, z1);
  }

  var k = 0;
  for (var z = 1.6; z + 0.6 <= length - 0.8; z += 1.5, k++) {
    // Desk 1.4 m wide (across), 0.5 m deep; chair and student behind it.
    out.add(at(Kind.desk, edge, edge + 1.4, z, z + 0.5, _deskH));
    if (!empty.contains(k)) {
      out.add(
        at(Kind.person, edge + 0.15, edge + 0.6, z + 0.55, z + 0.95, _seatedH),
      );
      out.add(
        at(Kind.person, edge + 0.8, edge + 1.25, z + 0.55, z + 0.95, _seatedH),
      );
    }
  }
  return out;
}

List<Box> _room(double length) => [
  Box(Kind.wall, -2.3, 0, -1, -2.2, 2.6, length), // side walls
  Box(Kind.wall, 2.2, 0, -1, 2.3, 2.6, length),
  Box(Kind.wall, -2.3, 0, length, 2.3, 2.6, length + 0.1), // end wall
  const Box(Kind.wall, -2.3, 0, -1.1, 2.3, 2.6, -1.0), // behind the start
];

final presets = <Preset>[
  Preset(
    'Lớp học như ảnh demo',
    'Lối giữa hai dãy bàn có người ngồi (~1 m). Một ghế bị kéo ra lối 30 cm ở '
        'bên trái, một ba lô dựng ở bên phải: mỗi lần còn khe khoảng 70 cm.',
    [
      ..._room(9),
      ..._row(-1, 0.5, 9),
      ..._row(1, 0.5, 9),
      const Box(Kind.chair, -0.5, 0, 3.6, -0.2, _chairH, 4.0),
      const Box(Kind.bag, 0.2, 0, 6.2, 0.5, 0.42, 6.45),
    ],
  ),
  Preset(
    'Ghế chắn nửa lối (khe 58 cm)',
    'Ghế kéo ra 42 cm, chỉ còn khe 58 cm: rộng hơn vai một chút. App bảo '
        'bước ngang vào giữa khe rồi đi qua.',
    [
      ..._room(9),
      ..._row(-1, 0.5, 9),
      ..._row(1, 0.5, 9),
      const Box(Kind.chair, -0.5, 0, 3.6, -0.08, _chairH, 4.0),
    ],
  ),
  Preset(
    'Ghế giữa lối, hai bên rộng',
    'Hành lang 2 m, một ghế đứng giữa lối: trường hợp né vật dễ nhất.',
    [..._room(9), const Box(Kind.chair, -0.22, 0, 4.0, 0.22, _chairH, 4.45)],
  ),
  Preset(
    'Ghế dính dãy bàn',
    'Ghế kéo ra từ dãy bàn trái, mép ghế chạm bàn. Xem app có bảo bước về '
        'đúng lúc không (lỗi đã thấy khi đọc code).',
    [
      ..._room(9),
      ..._row(-1, 0.5, 9, empty: {1, 2}),
      const Box(Kind.chair, -0.5, 0, 3.2, -0.05, _chairH, 3.65),
    ],
  ),
  Preset(
    'Lối hẹp: khe 30 cm',
    'Thùng giữa lối hẹp 1 m, mỗi bên chỉ còn khoảng 30 cm: hẹp hơn vai người.',
    [
      ..._room(9),
      ..._row(-1, 0.5, 9),
      ..._row(1, 0.5, 9),
      const Box(Kind.bag, -0.2, 0, 3.8, 0.2, 0.6, 4.2),
    ],
  ),
  Preset(
    'Tường cuối hành lang',
    'Đi thẳng tới tường: app phải bảo dừng và xoay tìm lối.',
    [..._room(4.5)],
    length: 4.5,
    finish: false,
  ),
  Preset('Lối trống', 'Không có vật: app chỉ nên nói "Đi thẳng."', [
    ..._room(9),
  ]),
];

/// The phone held at chest height in portrait, tilted down, like the demo.
class Phone {
  static const height = 1.3;

  /// Degrees the camera points below the horizon; the demo can change it.
  static double pitchDeg = 15.0;
  static const w = 256, h = 192;
  static const focal = 193.0;
  static const range = 5.0;
}

/// Ray-casts an ARKit-like depth frame from (x, z) facing [yaw] (radians,
/// 0 = along the aisle, + = turning right). Only the pixels LiDAR analysis
/// samples (every 2nd) are cast; the rest stay at confidence 0. The pose is
/// in ARKit's world (camera looks along -z), as the iOS plugin sends it.
LidarDepthFrame castFrame(List<Box> boxes, double x, double z, double yaw) {
  final p = Phone.pitchDeg * pi / 180, r = pi / 2; // portrait
  List<double> yawed(List<double> v) => [
    v[0] * cos(yaw) + v[2] * sin(yaw),
    v[1],
    -v[0] * sin(yaw) + v[2] * cos(yaw),
  ];
  final look = yawed([0.0, -sin(p), cos(p)]);
  final right0 = yawed([1.0, 0.0, 0.0]);
  final up0 = yawed([0.0, cos(p), sin(p)]);
  final right = [
    for (var i = 0; i < 3; i++) cos(r) * right0[i] + sin(r) * up0[i],
  ];
  final up = [
    for (var i = 0; i < 3; i++) -sin(r) * right0[i] + cos(r) * up0[i],
  ];
  const oy = Phone.height;
  final near = [
    for (final b in boxes)
      if (b.x1 > x - Phone.range &&
          b.x0 < x + Phone.range &&
          b.z1 > z - Phone.range &&
          b.z0 < z + Phone.range)
        b,
  ];
  const w = Phone.w, h = Phone.h;
  final depth = Float32List(w * h);
  final conf = Uint8List(w * h);
  const cx = (w - 1) / 2, cy = (h - 1) / 2;
  for (var v = 0; v < h; v += 2) {
    for (var u = 0; u < w; u += 2) {
      final xr = (u - cx) / Phone.focal, yr = -(v - cy) / Phone.focal;
      final dx = xr * right[0] + yr * up[0] + look[0];
      final dy = xr * right[1] + yr * up[1] + look[1];
      final dz = xr * right[2] + yr * up[2] + look[2];
      double? t = dy < 0 ? -oy / dy : null;
      for (final b in near) {
        final bt = b.hit(x, oy, z, dx, dy, dz);
        if (bt != null && (t == null || bt < t)) t = bt;
      }
      if (t == null) continue;
      final i = v * w + u;
      depth[i] = t; // dir has unit length along the view axis
      conf[i] = t <= Phone.range ? 2 : 0;
    }
  }
  return LidarDepthFrame(
    width: w,
    height: h,
    depth: depth,
    confidence: conf,
    fx: Phone.focal,
    fy: Phone.focal,
    cx: cx,
    cy: cy,
    upX: right[1],
    upY: up[1],
    upZ: -look[1],
    // Sim world (x right, z forward) → ARKit world (x right, -z forward).
    pose: LidarPose(x: x, z: -z, headX: sin(yaw), headZ: -cos(yaw)),
  );
}

/// COCO labels YOLO gives these kinds; walls, pillars and bags (a backpack
/// is not an obstacle class) are not named.
const yoloLabels = {
  Kind.chair: 'chair',
  Kind.desk: 'dining table',
  Kind.person: 'person',
};

/// The camera image YOLO sees: portrait, the depth frame's lens turned
/// upright, so a box in it lines up with the depth view.
const cameraFrame = Size(Phone.h * 1.0, Phone.w * 1.0);

/// What YOLO would box from (x, z) facing [yaw]: each named box projected
/// into [cameraFrame]. No occlusion (YOLO also boxes a chair half hidden by
/// a desk); boxes with a corner behind the camera are left out.
List<Recognition> detect(List<Box> boxes, double x, double z, double yaw) {
  final p = Phone.pitchDeg * pi / 180;
  List<double> yawed(List<double> v) => [
    v[0] * cos(yaw) + v[2] * sin(yaw),
    v[1],
    -v[0] * sin(yaw) + v[2] * cos(yaw),
  ];
  final look = yawed([0.0, -sin(p), cos(p)]);
  final right = yawed([1.0, 0.0, 0.0]);
  final up = yawed([0.0, cos(p), sin(p)]);
  double dot(List<double> a, List<double> b) =>
      a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  final out = <Recognition>[];
  for (final b in boxes) {
    final label = yoloLabels[b.kind];
    if (label == null) continue;
    var l = double.infinity, t = double.infinity;
    var r = double.negativeInfinity, btm = double.negativeInfinity;
    var behind = false;
    for (final cx in [b.x0, b.x1]) {
      for (final cy in [b.y0, b.y1]) {
        for (final cz in [b.z0, b.z1]) {
          final d = [cx - x, cy - Phone.height, cz - z];
          final depth = dot(d, look);
          if (depth < 0.1) behind = true;
          if (behind) continue;
          final u = dot(d, right) / depth * Phone.focal + cameraFrame.width / 2;
          final v = -dot(d, up) / depth * Phone.focal + cameraFrame.height / 2;
          l = min(l, u);
          r = max(r, u);
          t = min(t, v);
          btm = max(btm, v);
        }
      }
    }
    if (behind || Box._far(b, x, z)) continue;
    final rect = Rect.fromLTRB(
      l,
      t,
      r,
      btm,
    ).intersect(Offset.zero & cameraFrame);
    // A sliver at the image edge is not recognised.
    if (rect.width < 4 || rect.height < 4) continue;
    out.add(
      Recognition(
        b.kind.index,
        labelVi[label] ?? label,
        0.9,
        rect,
        labelEn: label,
      ),
    );
  }
  return out;
}
