import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/services/camera_session.dart';

void main() {
  test('resume waits for disposal before opening another camera', () async {
    var opens = 0;
    final closing = Completer<void>();
    final closeStarted = Completer<void>();
    final changes = <int?>[];
    final session = CameraSession<int>(
      open: () async => ++opens,
      close: (camera) async {
        if (camera == 1) {
          closeStarted.complete();
          await closing.future;
        }
      },
      onChanged: changes.add,
      onError: (error, stack) => fail('$error'),
    );

    await session.setActive(true);
    final paused = session.setActive(false);
    await closeStarted.future;
    final resumed = session.setActive(true);
    expect(opens, 1);
    expect(changes, [1, null]);
    closing.complete();
    await Future.wait([paused, resumed]);
    expect(opens, 2);
    expect(changes, [1, null, 2]);
    await session.dispose();
  });

  test(
    'a background/resume cycle rejects a camera still initializing',
    () async {
      final firstCamera = Completer<int>();
      final openStarted = Completer<void>();
      var opens = 0;
      final closed = <int>[];
      final changes = <int?>[];
      final session = CameraSession<int>(
        open: () {
          opens++;
          if (opens == 1) {
            openStarted.complete();
            return firstCamera.future;
          }
          return Future.value(opens);
        },
        close: (camera) async => closed.add(camera),
        onChanged: changes.add,
        onError: (error, stack) => fail('$error'),
      );

      final started = session.setActive(true);
      await openStarted.future;
      final paused = session.setActive(false);
      final resumed = session.setActive(true);
      firstCamera.complete(1);
      await Future.wait([started, paused, resumed]);
      expect(closed, [1]);
      expect(changes, [2]);
      expect(opens, 2);
      await session.dispose();
    },
  );

  test(
    'dispose during initialization closes once and never publishes the camera',
    () async {
      final camera = Completer<int>();
      final openStarted = Completer<void>();
      final closed = <int>[];
      final changes = <int?>[];
      var opens = 0;
      final session = CameraSession<int>(
        open: () {
          opens++;
          openStarted.complete();
          return camera.future;
        },
        close: (value) async => closed.add(value),
        onChanged: changes.add,
        onError: (error, stack) => fail('$error'),
      );

      final started = session.setActive(true);
      await openStarted.future;
      final disposed = session.dispose();
      camera.complete(1);
      await Future.wait([
        started,
        disposed,
        session.setActive(true),
        session.dispose(),
      ]);
      expect(opens, 1);
      expect(closed, [1]);
      expect(changes, isEmpty);
    },
  );

  test(
    'a failed initialization can be retried without overlapping opens',
    () async {
      var opens = 0;
      final errors = <Object>[];
      final changes = <int?>[];
      final session = CameraSession<int>(
        open: () async {
          if (++opens == 1) throw StateError('camera permission unavailable');
          return opens;
        },
        close: (_) async {},
        onChanged: changes.add,
        onError: (error, stack) => errors.add(error),
      );

      await session.setActive(true);
      await Future.wait([session.setActive(true), session.setActive(true)]);
      expect(errors, hasLength(1));
      expect(opens, 2);
      expect(changes, [2]);
      await session.dispose();
    },
  );
}
