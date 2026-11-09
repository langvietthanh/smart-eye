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
    // Frames every 100 ms: the clocks add at most 500 ms per update.
    final said = <int, String>{};
    for (var ms = 100; ms < 15000; ms += 100) {
      final c = up(ms, []);
      if (c != null) said[ms] = c.text;
    }
    expect(said, {
      5000: 'Đang tìm ghế. Xoay người chậm.',
      10000: 'Đang tìm ghế. Xoay người chậm.',
    });
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

  group('mất dấu, im lặng, hủy, đổi đích', () {
    TrackedObject bigChair({
      DistanceLevel level = DistanceLevel.near,
      double left = 0.35,
      double right = 0.65,
      double top = 0.5,
      double bottom = 0.97,
    }) => track(
      1,
      'chair',
      Rect.fromLTRB(left, top, right, bottom),
      level: level,
    );

    NavCue? upq(
      int ms,
      List<TrackedObject> tracks, {
      bool quiet = false,
      bool sightLost = false,
    }) => g.update(
      tracks: tracks,
      frame: f,
      quiet: quiet,
      sightLost: sightLost,
      now: at(ms),
    );

    // Lock onto a mid-frame far chair, then lose it.
    void lockMid() => up(100, [chairAt(0.5)]);

    test('tụt khỏi đáy khung khi near → tới nơi', () {
      up(0, [bigChair()]);
      final cue = up(200, [])!;
      expect(cue.text, 'Ghế ngay trước mặt, rất gần. Dò bằng gậy.');
      expect(cue.force, true);
      expect(cue.end, NavEnd.arrived);
      expect(g.state, NavState.idle);
    });

    test('box cao > 0,6 khi near rồi biến mất → tới nơi', () {
      up(0, [bigChair(top: 0.2, bottom: 0.85)]);
      expect(up(200, [])!.end, NavEnd.arrived);
    });

    test('ra mép phải → nói hướng ngay, state lost', () {
      up(0, [track(1, 'chair', const Rect.fromLTRB(0.8, 0.4, 0.98, 0.6))]);
      final cue = up(200, [])!;
      expect(cue.text, 'Ghế ở bên phải. Xoay phải chậm.');
      expect(cue.end, isNull);
      expect(g.state, NavState.lost);
    });

    test('ra mép trái', () {
      up(0, [track(1, 'chair', const Rect.fromLTRB(0.02, 0.4, 0.2, 0.6))]);
      expect(up(200, [])!.text, 'Ghế ở bên trái. Xoay trái chậm.');
      expect(g.state, NavState.lost);
    });

    test('biến mất giữa khung: im 1,5 s rồi mất dấu', () {
      lockMid();
      expect(up(1000, []), isNull);
      expect(g.state, NavState.guiding);
      expect(up(1600, [])!.text, 'Mất dấu ghế. Đứng yên, xoay người chậm.');
      expect(g.state, NavState.lost);
    });

    test('thấy lại trong 1,5 s → không nói gì, vẫn guiding', () {
      lockMid();
      expect(up(1000, []), isNull);
      expect(up(1200, [chairAt(0.5)]), isNull);
      expect(g.state, NavState.guiding);
      expect(g.targetTrackId, 1);
    });

    test('khi chờ chỉ id đã khóa mới tính là thấy lại', () {
      lockMid();
      expect(up(500, [chairAt(0.5, id: 7)]), isNull);
      expect(g.targetTrackId, 1);
      expect(up(1700, [chairAt(0.5, id: 7)])!.text, startsWith('Mất dấu'));
    });

    test('LiDAR ≤ 1 m khi đích biến mất sau near → tới nơi', () {
      up(0, [chairAt(0.5, level: DistanceLevel.near)]);
      final cue = up(200, [], lidar: const LidarObstacle(0.8))!;
      expect(cue.text, 'Đã tới. Ghế ngay trước mặt. Dò bằng gậy.');
      expect(cue.end, NavEnd.arrived);
      expect(cue.force, true);
    });

    test('LiDAR xa hoặc lastLevel không near → không tới nơi', () {
      up(0, [chairAt(0.5, level: DistanceLevel.near)]);
      expect(up(200, [], lidar: const LidarObstacle(1.4)), isNull);
      expect(g.state, NavState.guiding);
      final g2 = NavigationGuide()..start({'chair'}, 'ghế', at(0));
      g2.update(tracks: [chairAt(0.5)], frame: f, now: at(100));
      expect(
        g2.update(
          tracks: [],
          frame: f,
          lidarCenter: const LidarObstacle(0.5),
          now: at(200),
        ),
        isNull,
      );
    });

    test('frame Size.zero cũng tính là không thấy đích', () {
      up(0, [bigChair()]);
      final cue = g.update(
        tracks: [bigChair()],
        frame: Size.zero,
        now: at(200),
      )!;
      expect(cue.end, NavEnd.arrived);
    });

    test('lost → thấy lại cùng id', () {
      lockMid();
      up(1800, []);
      expect(up(2000, [chairAt(0.5)])!.text, 'Thấy lại ghế, phía trước.');
      expect(g.state, NavState.guiding);
      expect(g.targetTrackId, 1);
    });

    test('thấy lại hướng 1 giờ / 11 giờ', () {
      lockMid();
      up(1800, []);
      expect(up(2000, [chairAt(0.8)])!.text, 'Thấy lại ghế, hướng 1 giờ.');
      final g2 = NavigationGuide()..start({'chair'}, 'ghế', at(0));
      g2.update(tracks: [chairAt(0.5)], frame: f, now: at(100));
      g2.update(tracks: [], frame: f, now: at(1800));
      expect(
        g2.update(tracks: [chairAt(0.2)], frame: f, now: at(2000))!.text,
        'Thấy lại ghế, hướng 11 giờ.',
      );
    });

    test('lost → track cũ bị xóa, chọn track cùng lớp gần nhất', () {
      lockMid();
      up(1800, []);
      final cue = up(2000, [
        chairAt(0.5, id: 5, h: 0.2),
        chairAt(0.5, id: 6, h: 0.4),
        track(
          9,
          'person',
          const Rect.fromLTWH(0.4, 0.2, 0.2, 0.7),
          level: DistanceLevel.far,
        ),
      ])!;
      expect(cue.text, 'Thấy lại ghế, phía trước.');
      expect(g.targetTrackId, 6);
    });

    test('lost 15 s → lostTimeout', () {
      lockMid();
      up(1800, []);
      for (var ms = 1900; ms < 16800; ms += 100) {
        expect(up(ms, []), isNull);
      }
      final cue = up(16800, [])!;
      expect(cue.text, 'Không tìm lại được ghế. Đã dừng dẫn đường.');
      expect(cue.force, true);
      expect(cue.end, NavEnd.lostTimeout);
      expect(g.state, NavState.idle);
    });

    test('thấy lại đặt lại bộ đếm: đứng gần không tới nơi ngay khung đầu', () {
      lockMid();
      up(1800, []);
      up(2000, [chairAt(0.5, level: DistanceLevel.near)]);
      expect(g.state, NavState.guiding);
      expect(
        up(2100, [chairAt(0.5, level: DistanceLevel.near)])!.end,
        NavEnd.arrived,
      );
    });

    test('thấy lại lệch bên phải phải chờ 0,5 s mới nhắc lệch', () {
      lockMid();
      up(1800, []);
      up(2000, [chairAt(0.8)]);
      expect(up(2300, [chairAt(0.8)]), isNull);
      expect(up(2600, [chairAt(0.8)])!.text, 'Lệch phải.');
    });

    test('quiet: không trả câu thường; câu chốt được giữ', () {
      expect(upq(100, [chairAt(0.5)], quiet: true), isNull);
      expect(g.state, NavState.guiding);
      expect(
        upq(200, [chairAt(0.5, level: DistanceLevel.medium)])!.text,
        'Thấy ghế ở phía trước, khá gần.',
      );
      // Final cue held while quiet.
      final g2 = NavigationGuide()..start({'chair'}, 'ghế', at(0));
      expect(
        g2.update(tracks: [bigChair()], frame: f, quiet: true, now: at(100)),
        isNull,
      );
      expect(
        g2.update(tracks: [], frame: f, quiet: true, now: at(200)),
        isNull,
      );
      expect(g2.state, NavState.idle);
      expect(g2.isActive, false);
      expect(
        g2.update(tracks: [], frame: f, quiet: true, now: at(300)),
        isNull,
      );
      final cue = g2.update(tracks: [], frame: f, now: at(400))!;
      expect(cue.end, NavEnd.arrived);
      expect(cue.force, true);
      expect(g2.update(tracks: [], frame: f, now: at(500)), isNull);
    });

    test('hasPendingCue: báo câu chốt đang giữ sau khi guide đã idle', () {
      final g2 = NavigationGuide()..start({'chair'}, 'ghế', at(0));
      expect(g2.hasPendingCue, false);
      g2.update(tracks: [bigChair()], frame: f, quiet: true, now: at(100));
      g2.update(tracks: [], frame: f, quiet: true, now: at(200));
      expect(g2.isActive, false);
      expect(g2.hasPendingCue, true);
      expect(
        g2.update(tracks: [], frame: f, now: at(300))!.end,
        NavEnd.arrived,
      );
      expect(g2.hasPendingCue, false);
      // cancel() discards a held cue.
      final g3 = NavigationGuide()..start({'chair'}, 'ghế', at(0));
      g3.update(tracks: [bigChair()], frame: f, quiet: true, now: at(100));
      g3.update(tracks: [], frame: f, quiet: true, now: at(200));
      expect(g3.hasPendingCue, true);
      g3.cancel(announce: false);
      expect(g3.hasPendingCue, false);
    });

    test(
      'đích thấy trong lúc quiet → hết quiet nói câu vào, dựng từ hiện tại',
      () {
        expect(upq(100, [chairAt(0.5)], quiet: true), isNull);
        expect(
          upq(200, [chairAt(0.8, level: DistanceLevel.medium)])!.text,
          'Thấy ghế ở hướng 1 giờ, khá gần.',
        );
        expect(upq(300, [chairAt(0.8, level: DistanceLevel.medium)]), isNull);
      },
    );

    test('mất dấu mép bên trong lúc quiet → hết quiet vẫn LOST thì nói', () {
      lockMid();
      up(150, [track(1, 'chair', const Rect.fromLTRB(0.8, 0.4, 0.98, 0.6))]);
      expect(upq(300, [], quiet: true), isNull);
      expect(g.state, NavState.lost);
      expect(upq(400, [])!.text, 'Ghế ở bên phải. Xoay phải chậm.');
      expect(upq(500, []), isNull);
    });

    test(
      'câu vào bị bỏ rồi mất và thấy lại trước hết quiet → không phát lại',
      () {
        expect(upq(100, [chairAt(0.5)], quiet: true), isNull);
        expect(upq(1800, [], quiet: true), isNull);
        expect(g.state, NavState.lost);
        expect(upq(2000, [chairAt(0.5)])!.text, 'Thấy lại ghế, phía trước.');
        expect(upq(2100, [chairAt(0.5)]), isNull);
      },
    );

    test('câu thấy lại bị bỏ trong quiet được nói khi hết quiet', () {
      lockMid();
      up(1800, []);
      expect(upq(2000, [chairAt(0.2)], quiet: true), isNull);
      expect(upq(2100, [chairAt(0.2)])!.text, 'Thấy lại ghế, hướng 11 giờ.');
    });

    test('LiDAR chắn giữa lúc chờ không tính tới nơi: phân loại một lần', () {
      up(0, [chairAt(0.5, level: DistanceLevel.near)]);
      expect(up(100, [], lidar: const LidarClear()), isNull);
      expect(up(600, [], lidar: const LidarObstacle(0.8)), isNull);
      expect(g.state, NavState.guiding);
      expect(
        up(1600, [], lidar: const LidarObstacle(0.8))!.text,
        'Mất dấu ghế. Đứng yên, xoay người chậm.',
      );
    });

    test('quiet: câu thường bị bỏ không đánh dấu đã nói, sau đó còn nói', () {
      up(100, [chairAt(0.8)]);
      expect(upq(700, [chairAt(0.8)], quiet: true), isNull);
      expect(up(800, [chairAt(0.8)])!.text, 'Lệch phải.');
      final g2 = NavigationGuide()..start({'chair'}, 'ghế', at(0));
      g2.update(tracks: [chairAt(0.5)], frame: f, now: at(100));
      expect(
        g2.update(
          tracks: [chairAt(0.5, level: DistanceLevel.medium)],
          frame: f,
          quiet: true,
          now: at(200),
        ),
        isNull,
      );
      expect(
        g2
            .update(
              tracks: [chairAt(0.5, level: DistanceLevel.medium)],
              frame: f,
              now: at(300),
            )!
            .text,
        'Gần hơn rồi.',
      );
    });

    test('quiet không dừng đồng hồ; sightLost dừng đồng hồ 15 s', () {
      for (var ms = 100; ms <= 15000; ms += 100) {
        expect(upq(ms, [], quiet: true), isNull);
      }
      expect(g.state, NavState.idle);
      expect(upq(15100, [])!.end, NavEnd.notFound);

      final g2 = NavigationGuide()..start({'chair'}, 'ghế', at(0));
      for (var ms = 1000; ms <= 20000; ms += 1000) {
        g2.update(tracks: [], frame: f, sightLost: true, now: at(ms));
      }
      expect(g2.state, NavState.searching);
      g2.update(tracks: [], frame: f, now: at(21000));
      expect(g2.state, NavState.searching);
    });

    test('sightLost dừng đồng hồ lost', () {
      lockMid();
      up(1800, []);
      for (var ms = 3000; ms <= 30000; ms += 1000) {
        g.update(tracks: [], frame: f, sightLost: true, now: at(ms));
      }
      expect(g.state, NavState.lost);
    });

    test(
      'cancel nói "Đã dừng dẫn đường."; announce:false → null; idle → null',
      () {
        lockMid();
        final cue = g.cancel()!;
        expect(cue.text, 'Đã dừng dẫn đường.');
        expect(cue.force, true);
        expect(cue.end, NavEnd.cancelled);
        expect(g.state, NavState.idle);
        expect(g.cancel(), isNull);
        g.start({'chair'}, 'ghế', at(300));
        expect(g.cancel(announce: false), isNull);
        expect(g.isActive, false);
      },
    );

    test('cancel / start bỏ câu chốt đang chờ', () {
      up(0, [bigChair()]);
      g.update(tracks: [], frame: f, quiet: true, now: at(100));
      g.cancel();
      expect(up(200, []), isNull);
      up(300, [bigChair()]);
      g.update(tracks: [], frame: f, quiet: true, now: at(400));
      g.start({'chair'}, 'ghế', at(500));
      expect(up(600, []), isNull);
    });

    test('near rời mép bên khi LiDAR ≤ 1 m → câu mép bên, không tới nơi', () {
      up(0, [
        track(
          1,
          'chair',
          const Rect.fromLTRB(0.8, 0.4, 0.98, 0.6),
          level: DistanceLevel.near,
        ),
      ]);
      final cue = up(200, [], lidar: const LidarObstacle(0.8))!;
      expect(cue.text, 'Ghế ở bên phải. Xoay phải chậm.');
      expect(cue.end, isNull);
      expect(g.state, NavState.lost);
    });

    test('khoảng trống khung hình không làm hết giờ ngay (kẹp 500 ms)', () {
      expect(up(100, []), isNull);
      up(20000, []);
      expect(g.state, NavState.searching);
      lockMid();
      up(20000 + 1800, []);
      expect(g.state, NavState.lost);
      up(60000, []);
      expect(g.state, NavState.lost);
    });

    test('start khi đang dẫn → "Đổi sang tìm bàn." và về searching', () {
      lockMid();
      final cue = g.start({'dining table'}, 'bàn', at(300));
      expect(cue.text, 'Đổi sang tìm bàn.');
      expect(cue.force, false);
      expect(cue.end, isNull);
      expect(g.state, NavState.searching);
      expect(g.targetTrackId, isNull);
      expect(g.targetName, 'bàn');
      expect(up(5300, [])!.text, 'Đang tìm bàn. Xoay người chậm.');
    });
  });
  group('vừa tới nơi: loại trừ đích khỏi cảnh báo', () {
    TrackedObject nearChair({int id = 1}) =>
        chairAt(0.5, id: id, level: DistanceLevel.near);

    void arrive() {
      up(100, [nearChair()]);
      expect(up(200, [nearChair()])!.end, NavEnd.arrived);
    }

    test('giữ id đích vừa tới khi còn near, trong 6 s', () {
      expect(g.arrivedTrackId(tracks: [nearChair()], now: at(150)), isNull);
      arrive();
      expect(g.targetTrackId, isNull);
      expect(g.arrivedTrackId(tracks: [nearChair()], now: at(300)), 1);
      expect(g.arrivedTrackId(tracks: [nearChair()], now: at(6100)), 1);
    });

    test('hết 6 s thì bỏ loại trừ', () {
      arrive();
      expect(g.arrivedTrackId(tracks: [nearChair()], now: at(6200)), isNull);
      expect(g.arrivedTrackId(tracks: [nearChair()], now: at(1000)), isNull);
    });

    test('đích không còn near thì bỏ loại trừ, không quay lại', () {
      arrive();
      final medium = chairAt(0.5, level: DistanceLevel.medium);
      expect(g.arrivedTrackId(tracks: [medium], now: at(500)), isNull);
      expect(g.arrivedTrackId(tracks: [nearChair()], now: at(600)), isNull);
    });

    test('đích biến mất khỏi danh sách thì bỏ loại trừ', () {
      arrive();
      expect(
        g.arrivedTrackId(tracks: [nearChair(id: 2)], now: at(500)),
        isNull,
      );
    });

    test('tới nơi khi đích tụt khỏi khung cũng ghi id', () {
      up(0, [
        track(
          1,
          'chair',
          const Rect.fromLTRB(0.35, 0.5, 0.65, 0.97),
          level: DistanceLevel.near,
        ),
      ]);
      expect(up(200, [])!.end, NavEnd.arrived);
      expect(g.arrivedTrackId(tracks: [nearChair()], now: at(300)), 1);
    });

    test('start / cancel xóa loại trừ', () {
      arrive();
      g.start({'chair'}, 'ghế', at(300));
      expect(g.arrivedTrackId(tracks: [nearChair()], now: at(400)), isNull);
      g.cancel(announce: false);
      g.start({'chair'}, 'ghế', at(500));
      up(600, [nearChair()]);
      up(700, [nearChair()]);
      expect(g.arrivedTrackId(tracks: [nearChair()], now: at(800)), 1);
      g.cancel(announce: false);
      expect(g.arrivedTrackId(tracks: [nearChair()], now: at(900)), isNull);
    });
  });
}
