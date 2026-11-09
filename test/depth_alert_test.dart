import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/models/scene_info.dart';
import 'package:smart_eye/services/depth_alert.dart';

void main() {
  group('depthAlertText', () {
    test('depthLevel info returns null', () {
      expect(depthAlertText(depthLevel: AlertLevel.info), isNull);
      expect(
        depthAlertText(
          depthLevel: AlertLevel.info,
          detectorLevel: AlertLevel.caution,
          metres: 1.4,
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
      expect(
        depthAlertText(
          depthLevel: AlertLevel.danger,
          detectorLevel: AlertLevel.danger,
          metres: 0.8,
        ),
        isNull,
      );
    });

    test(
      'detectorLevel caution + depth danger returns "Dừng lại! Vật cản ngay trước mặt."',
      () {
        expect(
          depthAlertText(
            depthLevel: AlertLevel.danger,
            detectorLevel: AlertLevel.caution,
          ),
          'Dừng lại! Vật cản ngay trước mặt.',
        );
        expect(
          depthAlertText(
            depthLevel: AlertLevel.danger,
            detectorLevel: AlertLevel.caution,
            metres: 0.9,
          ),
          'Dừng lại! Vật cản ngay trước mặt.',
        );
      },
    );

    test('detectorLevel caution + depth caution returns null', () {
      expect(
        depthAlertText(
          depthLevel: AlertLevel.caution,
          detectorLevel: AlertLevel.caution,
          metres: 1.4,
        ),
        isNull,
      );
      expect(
        depthAlertText(
          depthLevel: AlertLevel.caution,
          detectorLevel: AlertLevel.caution,
          metres: null,
        ),
        isNull,
      );
    });

    test('detectorLevel danger + depth caution returns null', () {
      expect(
        depthAlertText(
          depthLevel: AlertLevel.caution,
          detectorLevel: AlertLevel.danger,
          metres: 1.5,
        ),
        isNull,
      );
    });

    test(
      'không có YOLO + caution + metres 1.4 returns "Chậm lại. Vật cản cách 1,5 mét."',
      () {
        expect(
          depthAlertText(
            depthLevel: AlertLevel.caution,
            detectorLevel: null,
            metres: 1.4,
          ),
          'Chậm lại. Vật cản cách 1,5 mét.',
        );
      },
    );

    test(
      'không có YOLO + caution + metres 2.0 returns "Chậm lại. Vật cản cách 2 mét."',
      () {
        expect(
          depthAlertText(
            depthLevel: AlertLevel.caution,
            detectorLevel: null,
            metres: 2.0,
          ),
          'Chậm lại. Vật cản cách 2 mét.',
        );
      },
    );

    test(
      'không có YOLO + caution + metres null returns "Chậm lại. Có vật phía trước."',
      () {
        expect(
          depthAlertText(
            depthLevel: AlertLevel.caution,
            detectorLevel: null,
            metres: null,
          ),
          'Chậm lại. Có vật phía trước.',
        );
      },
    );

    test('không có YOLO + danger returns "Dừng lại! Vật cản ngay trước mặt."', () {
      expect(
        depthAlertText(
          depthLevel: AlertLevel.danger,
          detectorLevel: null,
        ),
        'Dừng lại! Vật cản ngay trước mặt.',
      );
    });

    test('detectorLevel info does not suppress caution or danger', () {
      expect(
        depthAlertText(
          depthLevel: AlertLevel.caution,
          detectorLevel: AlertLevel.info,
          metres: 1.8,
        ),
        'Chậm lại. Vật cản cách 2 mét.',
      );
      expect(
        depthAlertText(
          depthLevel: AlertLevel.danger,
          detectorLevel: AlertLevel.info,
        ),
        'Dừng lại! Vật cản ngay trước mặt.',
      );
    });
  });

  group('sideClause', () {
    const c = SideState.clear, b = SideState.blocked, u = SideState.unknown;
    test('one side clear', () {
      expect(sideClause(c, b), 'Bên trái trống.');
      expect(sideClause(u, c), 'Bên phải trống.');
    });
    test('both clear / both blocked', () {
      expect(sideClause(c, c), 'Hai bên trống.');
      expect(sideClause(b, b), 'Hai bên có vật cản.');
    });
    test('nothing certain says nothing', () {
      expect(sideClause(u, u), isNull);
      expect(sideClause(b, u), isNull);
    });
  });

  group('side clause on alerts', () {
    test('LiDAR caution with a free right side', () {
      expect(
        depthAlertText(
          depthLevel: AlertLevel.caution,
          metres: 1.4,
          left: SideState.blocked,
          right: SideState.clear,
        ),
        'Chậm lại. Vật cản cách 1,5 mét. Bên phải trống.',
      );
    });

    test('a suppressed depth alert stays suppressed', () {
      expect(
        depthAlertText(
          depthLevel: AlertLevel.caution,
          detectorLevel: AlertLevel.danger,
          metres: 1.4,
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
        'Dừng lại! Có ghế ngay phía trước. Bên trái trống.',
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
}
