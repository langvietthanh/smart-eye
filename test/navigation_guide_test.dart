import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/models/nav_command.dart';
import 'package:smart_eye/models/scene_info.dart';
import 'package:smart_eye/models/tracked_object.dart';
import 'package:smart_eye/services/lidar_analysis.dart';
import 'package:smart_eye/services/navigation_guide.dart';

final t0 = DateTime(2026, 1, 1);
DateTime at(int ms) => t0.add(Duration(milliseconds: ms));
const f = Size(1000, 1000);

TrackedObject track(
  int id,
  String label,
  Rect box, {
  DistanceLevel? level,
  int misses = 0,
  bool confirmed = true,
}) {
  final r = Rect.fromLTRB(
    box.left * 1000,
    box.top * 1000,
    box.right * 1000,
    box.bottom * 1000,
  );
  return TrackedObject(
      id: id,
      classId: 0,
      labelEn: label,
      labelVi: label,
      box: r,
      score: 0.9,
    )
    ..distanceLevel = level
    ..misses = misses
    ..confirmed = confirmed;
}

/// Chair centred at x with a modest height.
TrackedObject chairAt(
  double x, {
  DistanceLevel? level = DistanceLevel.far,
  int id = 1,
  double h = 0.2,
}) => track(id, 'chair', Rect.fromLTWH(x - 0.05, 0.4, 0.1, h), level: level);

void main() {
  late NavigationGuide g;
  setUp(() {
    g = NavigationGuide();
    g.start({'chair'}, 'ghế', at(0));
  });

  NavCue? up(int ms, List<TrackedObject> tracks, {LidarReading? lidar}) =>
      g.update(tracks: tracks, frame: f, lidarCenter: lidar, now: at(ms));

  test('start nói đang tìm', () {
    final g2 = NavigationGuide();
    final cue = g2.start({'chair'}, 'ghế', at(0));
    expect(cue.text, 'Đang tìm ghế. Xoay người chậm.');
    expect(cue.force, false);
    expect(g2.state, NavState.searching);
    expect(g2.isActive, true);
    expect(g2.targetName, 'ghế');
  });

  test('thấy đích → câu hướng giờ + khoảng cách', () {
    expect(up(100, [chairAt(0.7)])!.text, 'Thấy ghế ở hướng 1 giờ, còn xa.');
    expect(g.state, NavState.guiding);
  });

  test('hướng 11 giờ và phía trước', () {
    expect(
      up(100, [chairAt(0.3, level: DistanceLevel.medium)])!.text,
      'Thấy ghế ở hướng 11 giờ, khá gần.',
    );
    final g2 = NavigationGuide()..start({'chair'}, 'ghế', at(0));
    expect(
      g2
          .update(
            tracks: [chairAt(0.55, level: DistanceLevel.near)],
            frame: f,
            now: at(100),
          )!
          .text,
      'Thấy ghế ở phía trước, rất gần.',
    );
  });

  test('distanceLevel null coi như far', () {
    expect(
      up(100, [chairAt(0.5, level: null)])!.text,
      'Thấy ghế ở phía trước, còn xa.',
    );
  });

  test('chọn track gần nhất (box cao nhất) và khóa id', () {
    up(100, [chairAt(0.5, id: 1, h: 0.2), chairAt(0.5, id: 2, h: 0.4)]);
    expect(g.targetTrackId, 2);
    up(200, [chairAt(0.5, id: 1, h: 0.5), chairAt(0.5, id: 2, h: 0.4)]);
    expect(g.targetTrackId, 2);
  });

  test('chấp nhận mọi nhãn trong tập', () {
    final g2 = NavigationGuide()
      ..start({'motorcycle', 'motorbike'}, 'xe máy', at(0));
    final m = track(
      3,
      'motorbike',
      const Rect.fromLTWH(0.45, 0.4, 0.1, 0.2),
      level: DistanceLevel.far,
    );
    g2.update(tracks: [m], frame: f, now: at(100));
    expect(g2.state, NavState.guiding);
  });

  test('bỏ qua track chưa confirmed hoặc misses > 0 hoặc nhãn khác', () {
    const b = Rect.fromLTWH(0.45, 0.4, 0.1, 0.2);
    final a = track(1, 'chair', b, confirmed: false);
    final c = track(2, 'chair', b, misses: 1);
    final d = track(3, 'person', b);
    expect(up(100, [a, c, d]), isNull);
    expect(g.state, NavState.searching);
  });

  test('nhắc lệch sau 0,5 s, lặp mỗi 3 s', () {
    expect(up(100, [chairAt(0.8)])!.text, startsWith('Thấy ghế'));
    expect(up(400, [chairAt(0.8)]), isNull);
    expect(up(650, [chairAt(0.8)])!.text, 'Lệch phải.');
    expect(up(2000, [chairAt(0.8)]), isNull);
    expect(up(3700, [chairAt(0.8)])!.text, 'Lệch phải.');
  });

  test('lệch trái khi dx < 0', () {
    up(100, [chairAt(0.2)]);
    expect(up(700, [chairAt(0.2)])!.text, 'Lệch trái.');
  });

  test('về thẳng nói một lần', () {
    up(100, [chairAt(0.8)]);
    expect(up(700, [chairAt(0.8)])!.text, 'Lệch phải.');
    expect(up(800, [chairAt(0.55)])!.text, 'Thẳng rồi.');
    expect(up(900, [chairAt(0.55)]), isNull);
  });

  test('vùng trễ 0,12–0,22 không nói gì', () {
    up(100, [chairAt(0.8)]);
    up(700, [chairAt(0.8)]);
    expect(up(800, [chairAt(0.65)]), isNull); // dx 0.15
    expect(up(900, [chairAt(0.65)]), isNull);
    expect(up(1000, [chairAt(0.55)])!.text, 'Thẳng rồi.');
  });

  test('câu khoảng cách chỉ khi lại gần', () {
    up(100, [chairAt(0.5, level: DistanceLevel.far)]);
    expect(
      up(200, [chairAt(0.5, level: DistanceLevel.medium)])!.text,
      'Gần hơn rồi.',
    );
    expect(up(300, [chairAt(0.5, level: DistanceLevel.far)]), isNull);
    expect(up(400, [chairAt(0.5, level: DistanceLevel.medium)]), isNull);
    expect(
      up(500, [chairAt(0.5, level: DistanceLevel.near)])!.text,
      'Sắp tới.',
    );
  });

  test('tới nơi sau 2 lần near & |dx|<0,25', () {
    up(100, [chairAt(0.5, level: DistanceLevel.near)]);
    expect(
      up(200, [chairAt(0.5, level: DistanceLevel.near)])!.text,
      'Đã tới. Ghế ngay trước mặt. Dò bằng gậy.',
    );
  });

  test('tới nơi trả NavCue force + end, state idle', () {
    up(50, [chairAt(0.5, level: DistanceLevel.medium)]);
    expect(
      up(100, [chairAt(0.5, level: DistanceLevel.near)])!.text,
      'Sắp tới.',
    );
    final cue = up(200, [chairAt(0.5, level: DistanceLevel.near)])!;
    expect(cue.force, true);
    expect(cue.end, NavEnd.arrived);
    expect(g.state, NavState.idle);
    expect(g.isActive, false);
    expect(g.targetTrackId, isNull);
  });

  test('near nhưng lệch |dx|>=0,25 không tính tới nơi', () {
    up(100, [chairAt(0.8, level: DistanceLevel.near)]);
    up(200, [chairAt(0.8, level: DistanceLevel.near)]);
    expect(g.state, NavState.guiding);
  });

  test('LiDAR điều kiện tới nơi', () {
    NavCue? run(LidarReading? l) {
      final x = NavigationGuide()..start({'chair'}, 'ghế', at(0));
      NavCue? ended;
      for (final ms in [100, 200, 300]) {
        final c = x.update(
          tracks: [chairAt(0.5, level: DistanceLevel.near)],
          frame: f,
          lidarCenter: l,
          now: at(ms),
        );
        if (c?.end != null) ended = c;
      }
      return ended;
    }

    expect(run(const LidarObstacle(1.4)), isNull);
    expect(run(const LidarClear()), isNull);
    expect(run(const LidarObstacle(0.9))!.end, NavEnd.arrived);
    expect(run(const LidarUnknown())!.end, NavEnd.arrived);
    expect(run(null)!.end, NavEnd.arrived);
  });

  test('nhắc tìm mỗi 5 s; 15 s không thấy → notFound', () {
    expect(up(1000, []), isNull);
    expect(up(5000, [])!.text, 'Đang tìm ghế. Xoay người chậm.');
    expect(up(7000, []), isNull);
    expect(up(10000, [])!.text, 'Đang tìm ghế. Xoay người chậm.');
    final cue = up(15000, [])!;
    expect(cue.text, 'Không tìm thấy ghế. Đã dừng dẫn đường.');
    expect(cue.force, true);
    expect(cue.end, NavEnd.notFound);
    expect(g.state, NavState.idle);
  });

  test('frame Size.zero / tracks rỗng không crash', () {
    expect(
      g.update(tracks: [chairAt(0.5)], frame: Size.zero, now: at(100)),
      isNull,
    );
    expect(up(200, []), isNull);
    expect(g.state, NavState.searching);
  });

  test('ưu tiên một câu mỗi update: khoảng cách thắng lệch hướng', () {
    up(100, [chairAt(0.8, level: DistanceLevel.far)]);
    final cue = up(700, [chairAt(0.8, level: DistanceLevel.medium)])!;
    expect(cue.text, 'Gần hơn rồi.');
    expect(
      up(800, [chairAt(0.8, level: DistanceLevel.medium)])!.text,
      'Lệch phải.',
    );
  });

  test('không thấy đích khi guiding → không câu', () {
    up(100, [chairAt(0.5)]);
    expect(up(200, []), isNull);
    expect(g.state, NavState.guiding);
  });

  test('đổi bên: cue ngược lại ngay khi đủ 0,5 s, không chờ 3 s', () {
    up(100, [chairAt(0.8)]);
    expect(up(700, [chairAt(0.8)])!.text, 'Lệch phải.');
    expect(up(800, [chairAt(0.2)]), isNull);
    expect(up(1200, [chairAt(0.2)]), isNull);
    expect(up(1300, [chairAt(0.2)])!.text, 'Lệch trái.');
    expect(up(1400, [chairAt(0.2)]), isNull);
  });

  test('đổi bên qua vùng trễ vẫn nói ngay khi đủ 0,5 s', () {
    up(100, [chairAt(0.8)]);
    expect(up(700, [chairAt(0.8)])!.text, 'Lệch phải.');
    expect(up(800, [chairAt(0.65)]), isNull);
    expect(up(900, [chairAt(0.2)]), isNull);
    expect(up(1400, [chairAt(0.2)])!.text, 'Lệch trái.');
  });

  test('near đầu tiên khi đã guiding chưa kết thúc phiên', () {
    up(100, [chairAt(0.5, level: DistanceLevel.far)]);
    final cue = up(200, [chairAt(0.5, level: DistanceLevel.near)])!;
    expect(cue.text, 'Sắp tới.');
    expect(cue.end, isNull);
    expect(g.state, NavState.guiding);
  });

  test('dx 0,15 từ đầu thẳng im lặng', () {
    up(100, [chairAt(0.65)]);
    expect(up(1000, [chairAt(0.65)]), isNull);
    expect(up(2000, [chairAt(0.65)]), isNull);
  });
}
