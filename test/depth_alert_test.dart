import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/models/scene_info.dart';
import 'package:smart_eye/services/depth_alert.dart';

void main() {
  test('constants have exact text', () {
    expect(trapAlertText, 'Xoay người tìm lối.');
    expect(turnOnText, 'Xoay tiếp.');
  });

  group('depthAlertText', () {
    test('danger returns "Dừng lại!"', () {
      expect(
        depthAlertText(depthLevel: AlertLevel.danger),
        'Dừng lại!',
      );
    });

    test('caution returns "Chậm lại."', () {
      expect(
        depthAlertText(depthLevel: AlertLevel.caution),
        'Chậm lại.',
      );
    });

    test('danger with right clear returns "Dừng lại! Đi chéo sang phải."', () {
      expect(
        depthAlertText(
          depthLevel: AlertLevel.danger,
          right: SideState.clear,
        ),
        'Dừng lại! Đi chéo sang phải.',
      );
    });

    test('danger with both sides blocked returns "Dừng lại!"', () {
      expect(
        depthAlertText(
          depthLevel: AlertLevel.danger,
          left: SideState.blocked,
          right: SideState.blocked,
        ),
        'Dừng lại!',
      );
    });

    test('depthLevel info returns null', () {
      expect(depthAlertText(depthLevel: AlertLevel.info), isNull);
      expect(
        depthAlertText(
          depthLevel: AlertLevel.info,
          detectorLevel: AlertLevel.caution,
        ),
        isNull,
      );
      expect(
        depthAlertText(
          depthLevel: AlertLevel.info,
          detectorLevel: AlertLevel.danger,
        ),
        isNull,
      );
    });

    test('detectorLevel danger + depth danger returns null', () {
      expect(
        depthAlertText(
          depthLevel: AlertLevel.danger,
          detectorLevel: AlertLevel.danger,
        ),
        isNull,
      );
    });

    test('detectorLevel caution + depth danger returns "Dừng lại!"', () {
      expect(
        depthAlertText(
          depthLevel: AlertLevel.danger,
          detectorLevel: AlertLevel.caution,
        ),
        'Dừng lại!',
      );
    });

    test('detectorLevel caution + depth caution returns null', () {
      expect(
        depthAlertText(
          depthLevel: AlertLevel.caution,
          detectorLevel: AlertLevel.caution,
        ),
        isNull,
      );
    });

    test('detectorLevel danger + depth caution returns null', () {
      expect(
        depthAlertText(
          depthLevel: AlertLevel.caution,
          detectorLevel: AlertLevel.danger,
        ),
        isNull,
      );
    });

    test('detectorLevel info does not suppress caution or danger', () {
      expect(
        depthAlertText(
          depthLevel: AlertLevel.caution,
          detectorLevel: AlertLevel.info,
        ),
        'Chậm lại.',
      );
      expect(
        depthAlertText(
          depthLevel: AlertLevel.danger,
          detectorLevel: AlertLevel.info,
        ),
        'Dừng lại!',
      );
    });
  });

  group('sideClause', () {
    const c = SideState.clear, b = SideState.blocked, u = SideState.unknown;
    test('one side clear', () {
      expect(sideClause(c, b), 'Đi chéo sang trái.');
      expect(sideClause(u, c), 'Đi chéo sang phải.');
    });
    test('both clear goes right / both blocked says nothing', () {
      expect(sideClause(c, c), 'Đi chéo sang phải.');
      expect(sideClause(b, b), isNull);
    });
    test('nothing certain says nothing', () {
      expect(sideClause(u, u), isNull);
      expect(sideClause(b, u), isNull);
    });
  });

  group('side clause on alerts', () {
    test('caution with a free right side', () {
      expect(
        depthAlertText(
          depthLevel: AlertLevel.caution,
          left: SideState.blocked,
          right: SideState.clear,
        ),
        'Chậm lại. Đi chéo sang phải.',
      );
    });

    test('a suppressed depth alert stays suppressed', () {
      expect(
        depthAlertText(
          depthLevel: AlertLevel.caution,
          detectorLevel: AlertLevel.danger,
          left: SideState.clear,
          right: SideState.clear,
        ),
        isNull,
      );
    });

    test('withSideClause appends for a centre object', () {
      expect(
        withSideClause(
          'Dừng lại! Có ghế ngay phía trước.',
          pos: HPos.center,
          left: SideState.clear,
          right: SideState.blocked,
        ),
        'Dừng lại! Có ghế ngay phía trước. Đi chéo sang trái.',
      );
    });

    test('withSideClause leaves side objects alone', () {
      for (final pos in [HPos.left, HPos.right, null]) {
        expect(
          withSideClause(
            'Chậm lại. Có ghế bên phải.',
            pos: pos,
            left: SideState.clear,
            right: SideState.clear,
          ),
          'Chậm lại. Có ghế bên phải.',
        );
      }
    });
  });

  group('speakableSides', () {
    const sides = (left: SideState.clear, right: SideState.blocked);
    const none = (left: SideState.unknown, right: SideState.unknown);

    test('fresh sides are spoken', () {
      expect(
        speakableSides(sides, capturedAtMs: 1000, nowMs: 1500, trapped: false),
        sides,
      );
    });

    test('sides captured more than 500 ms ago are dropped', () {
      expect(
        speakableSides(sides, capturedAtMs: 1000, nowMs: 1501, trapped: false),
        none,
      );
    });

    test('sides are never spoken during a trap', () {
      expect(
        speakableSides(sides, capturedAtMs: 1000, nowMs: 1000, trapped: true),
        none,
      );
    });

    test('no LiDAR reading yet means no sides', () {
      expect(
        speakableSides(sides, capturedAtMs: -1, nowMs: 100, trapped: false),
        none,
      );
    });
  });

  group('spokenMetres', () {
    test('formats rounded half metres with Vietnamese comma', () {
      expect(spokenMetres(0.5), '0,5');
      expect(spokenMetres(1.0), '1');
      expect(spokenMetres(1.2), '1');
      expect(spokenMetres(1.4), '1,5');
      expect(spokenMetres(1.6), '1,5');
      expect(spokenMetres(1.8), '2');
      expect(spokenMetres(2.0), '2');
      expect(spokenMetres(2.2), '2');
      expect(spokenMetres(2.3), '2,5');
    });
  });

  group('monoSide', () {
    test('clear only when MiDaS is far and YOLO is empty', () {
      expect(monoSide(0.2, 0), SideState.clear);
      expect(monoSide(0.2, 0.5), SideState.unknown);
      expect(monoSide(0.6, 0), SideState.unknown);
    });

    test('blocked by MiDaS caution or a YOLO object', () {
      expect(monoSide(0.8, 0), SideState.blocked);
      expect(monoSide(0.1, 1), SideState.blocked);
    });
  });
}
