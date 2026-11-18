import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/services/lidar_analysis.dart';
import 'package:smart_eye/services/tts_service.dart';
import 'package:smart_eye_sim/sim_driver.dart';
import 'package:smart_eye_sim/sim_world.dart';

/// A voice that takes as long as a short spoken line.
class TimedTts implements TTSService {
  Timer? _t;
  Completer<void>? _c;
  @override
  bool vietnameseAvailable = true;
  @override
  bool get isSpeaking => _c != null;
  @override
  Future<void> init() async {}
  @override
  Future<void> speak(String text) {
    _end();
    final c = _c = Completer<void>();
    _t = Timer(Duration(milliseconds: 400 + text.length * 60), _end);
    return c.future;
  }

  void _end() {
    _t?.cancel();
    final c = _c;
    _c = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  @override
  Future<void> stop() async => _end();
}

Preset named(String start) =>
    presets.firstWhere((p) => p.name.startsWith(start));

/// Runs [p] in auto mode for up to [seconds] of fake time.
Future<SimDriver> run(WidgetTester tester, Preset p, {int seconds = 45}) async {
  final d = SimDriver(
    tts: TimedTts(),
    now: tester.binding.clock.now,
    preset: p,
  );
  d.reset();
  for (var i = 0; i < seconds * 20 && !d.finished; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    d.advance(const Duration(milliseconds: 50));
  }
  // Let the last line and the speech manager's timers finish.
  await tester.pump(const Duration(seconds: 6));
  // ignore: avoid_print
  print(
    '${p.name}: z=${d.z.toStringAsFixed(2)} x=${d.x.toStringAsFixed(2)} '
    'va chạm=${d.collisions.length}\n  '
    '${d.heard.map((h) => '${(h.at.inMilliseconds / 1000).toStringAsFixed(1)}s ${h.text}').join('\n  ')}',
  );
  return d;
}

void main() {
  test('the ray-cast room reads like the LiDAR tests: chair ahead at 4 m', () {
    final frame = castFrame(named('Ghế giữa').boxes, 0, 0, 0);
    final scan = LidarAnalysis().analyzeScan(frame);
    expect(scan.center, isA<LidarObstacle>());
    expect((scan.center as LidarObstacle).distance, closeTo(4.0, 0.15));
    expect(frame.pose, isNotNull);
  });

  testWidgets('empty aisle: walks to the end saying only "Đi thẳng."', (
    tester,
  ) async {
    final d = await run(tester, named('Lối trống'));
    expect(d.finished, isTrue);
    expect(d.collisions, isEmpty);
    expect(d.heard.map((h) => h.text).toSet(), {'Đi thẳng.'});
  });

  testWidgets('phone tilted 35°: the whole bypass runs end to end', (
    tester,
  ) async {
    Phone.pitchDeg = 35;
    addTearDown(() => Phone.pitchDeg = 15);
    final d = await run(tester, named('Ghế dính'));
    final said = d.heard.map((h) => h.text).toList();
    expect(said, contains('Dừng lại!'));
    expect(said.where((t) => t.startsWith('Bước ngang')).toList(), [
      'Bước ngang sang phải.',
      'Bước ngang sang trái.',
    ]);
    expect(d.collisions, isEmpty);
    expect(d.finished, isTrue);
    expect(d.x.abs(), lessThan(0.15)); // back on the old line
  });

  // Held level (0°), a 42 cm bag leaves LiDAR's view under ~1.3 m, before
  // any "Dừng lại!": the app asks for a slight downward tilt.
  for (final pitch in [15.0, 30.0]) {
    testWidgets('phone tilted $pitch°: demo classroom walked end to end', (
      tester,
    ) async {
      Phone.pitchDeg = pitch;
      addTearDown(() => Phone.pitchDeg = 15);
      final d = await run(tester, named('Lớp học'), seconds: 60);
      final said = d.heard.map((h) => h.text).toList();
      expect(said.where((t) => t.startsWith('Bước ngang')).length, 4);
      expect(said, isNot(contains(findWayTextForTest)));
      expect(d.collisions, isEmpty);
      expect(d.finished, isTrue);
      expect(d.x.abs(), lessThan(0.2)); // back on the aisle's line
    });
  }

  testWidgets('58 cm gap: not squeezed through, never walked back', (
    tester,
  ) async {
    final d = await run(tester, named('Ghế chắn'), seconds: 40);
    final said = d.heard.map((h) => h.text).toList();
    expect(said.where((t) => t.startsWith('Bước ngang')), isEmpty);
    expect(said, contains(findWayTextForTest));
    expect(d.z, greaterThan(2.0));
    // The 55 cm between two rows of desks is no way on any more.
    expect(d.collisions, isEmpty);
  });

  testWidgets('chair in a wide corridor at 15°: stepped round, not turned', (
    tester,
  ) async {
    final d = await run(tester, named('Ghế giữa'));
    final said = d.heard.map((h) => h.text).toList();
    expect(said.where((t) => t.startsWith('Bước ngang')).length, 2);
    expect(d.collisions, isEmpty);
    expect(d.finished, isTrue);
  });

  testWidgets('30 cm gaps: no squeezing in, never walked back', (tester) async {
    final d = await run(tester, named('Lối hẹp'), seconds: 40);
    final said = d.heard.map((h) => h.text).toList();
    expect(said.where((t) => t.startsWith('Bước ngang')), isEmpty);
    expect(said, contains(findWayTextForTest));
    expect(said, contains('Xoay ngược lại.'));
    expect(said, contains('Phía trước bị chặn. Dò gậy tìm lối khác.'));
    expect(d.act, Act.blocked);
    expect(d.z, greaterThan(2.0)); // still where it stopped, not back home
    expect(d.collisions, isEmpty);
  });

  testWidgets('wall at the end: told it is a wall and to turn', (tester) async {
    final d = await run(tester, named('Tường cuối'), seconds: 20);
    final said = d.heard.map((h) => h.text).toList();
    expect(said.where((t) => t.contains('Tường phía trước')), isNotEmpty);
    expect(d.collisions, isEmpty);
  });
}

const findWayTextForTest = 'Dừng lại! Xoay người tìm lối.';
