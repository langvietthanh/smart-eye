import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/services/sight_monitor.dart';

void main() {
  final t0 = DateTime(2026, 1, 1);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  test('inactive monitor never reports a problem', () {
    expect(SightMonitor().check(at(60000)), isNull);
  });

  test('missing AI results become a blind problem after the grace period', () {
    final m = SightMonitor()..start(t0);
    expect(m.check(at(3900)), isNull);
    expect(m.check(at(4100)), SightProblem.noResults);
    m.onResult(at(4100), 120);
    expect(m.check(at(5500)), isNull);
    expect(m.check(at(5700)), SightProblem.noResults);
    expect(SightProblem.noResults.isBlind, isTrue);
  });

  test('darkness uses hysteresis', () {
    final m = SightMonitor()..start(t0);
    m.onResult(at(0), 25);
    expect(m.check(at(10)), SightProblem.tooDark);
    m.onResult(at(20), 35); // between enter and exit: still dark
    expect(m.check(at(30)), SightProblem.tooDark);
    m.onResult(at(40), 45);
    expect(m.check(at(50)), isNull);
    m.onResult(at(60), null); // unreadable frame keeps the last state
    expect(m.check(at(70)), isNull);
  });

  test('pitch: upright 0, screen up +90, screen down -90, landscape too', () {
    expect(SightMonitor.pitchDegrees(0, 9.8, 0), closeTo(0, 1e-9));
    expect(SightMonitor.pitchDegrees(0, 0, 9.8), closeTo(90, 1e-9));
    expect(SightMonitor.pitchDegrees(0, 0, -9.8), closeTo(-90, 1e-9));
    expect(SightMonitor.pitchDegrees(9.8, 0, 0), closeTo(0, 1e-9));
  });

  test('camera aimed at the floor or ceiling asks to adjust', () {
    final m = SightMonitor()..start(t0);
    for (var i = 0; i < 30; i++) {
      m.onAccelerometer(0, 1, 9.7); // almost flat, screen up
    }
    expect(m.check(at(10)), SightProblem.pointingDown);
    expect(SightProblem.pointingDown.isBlind, isFalse);
    for (var i = 0; i < 30; i++) {
      m.onAccelerometer(0, 9.3, 3.0); // ~18° down: normal walking hold
    }
    expect(m.check(at(20)), isNull);
    for (var i = 0; i < 30; i++) {
      m.onAccelerometer(0, 7, -7); // 45° up
    }
    expect(m.check(at(30)), SightProblem.pointingUp);
  });

  test('blind problems take precedence over aiming', () {
    final m = SightMonitor()..start(t0);
    for (var i = 0; i < 30; i++) {
      m.onAccelerometer(0, 0, 9.8);
    }
    m.onResult(at(0), 10);
    expect(m.check(at(10)), SightProblem.tooDark);
    expect(m.check(at(2000)), SightProblem.noResults);
  });

  test('LiDAR depth that stays unreadable is announced', () {
    final m = SightMonitor()
      ..enableDepth(true)
      ..start(t0);
    m.onResult(at(0), 120);
    m.onDepth(at(0), known: true);
    m.onResult(at(1000), 120);
    m.onDepth(at(800), known: false);
    expect(m.check(at(900)), isNull);
    expect(m.check(at(1100)), SightProblem.noDepth);
    expect(SightProblem.noDepth.isBlind, isFalse);

    expect(

      SightProblem.noDepth.message,

      'Không đo được khoảng cách. Đi chậm, dùng gậy.',

    );
    m.onDepth(at(1200), known: true);
    expect(m.check(at(1300)), isNull);
  });

  test('depth silence is ignored without LiDAR and loses to darkness', () {
    final plain = SightMonitor()..start(t0);
    plain.onResult(at(5000), 120);
    expect(plain.check(at(5100)), isNull);
    final m = SightMonitor()
      ..enableDepth(true)
      ..start(t0);
    m.onResult(at(5000), 10);
    expect(m.check(at(5100)), SightProblem.tooDark);
  });

  test('aiming problems have updated message and stopsUser', () {
    expect(
      SightProblem.pointingDown.message,
      'Dừng lại! Máy đang chĩa xuống sàn. Nâng máy lên.',
    );
    expect(
      SightProblem.pointingUp.message,
      'Dừng lại! Máy đang chĩa lên cao. Hạ máy xuống.',
    );
    expect(SightProblem.pointingDown.stopsUser, isTrue);
    expect(SightProblem.pointingUp.stopsUser, isTrue);
    expect(SightProblem.noResults.stopsUser, isTrue);
    expect(SightProblem.tooDark.stopsUser, isTrue);
    expect(SightProblem.noDepth.stopsUser, isFalse);

    // isBlind remains only noResults and tooDark
    expect(SightProblem.pointingDown.isBlind, isFalse);
    expect(SightProblem.pointingUp.isBlind, isFalse);
    expect(SightProblem.noResults.isBlind, isTrue);
    expect(SightProblem.tooDark.isBlind, isTrue);
  });

  test('sightRecoveryText returns correct recovery messages', () {
    expect(
      sightRecoveryText(SightProblem.pointingDown),
      'Đã đúng hướng. Đi tiếp.',
    );
    expect(
      sightRecoveryText(SightProblem.pointingUp),
      'Đã đúng hướng. Đi tiếp.',
    );
    expect(
      sightRecoveryText(SightProblem.noResults),
      'App đã nhìn thấy lại.',
    );
    expect(
      sightRecoveryText(SightProblem.tooDark),
      'App đã nhìn thấy lại.',
    );
    expect(sightRecoveryText(SightProblem.noDepth), isNull);
    expect(sightRecoveryText(null), isNull);
  });
}
