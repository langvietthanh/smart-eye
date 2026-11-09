import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/services/camera_feed.dart';
import 'package:smart_eye/widgets/camera_feed_preview.dart';

void main() {
  late CameraPlatform previousPlatform;
  late _CameraPlatform platform;
  late CameraFeed feed;
  late List<Object> errors;
  late List<int> receivedFrames;

  void cameraTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      previousPlatform = CameraPlatform.instance;
      platform = _CameraPlatform();
      CameraPlatform.instance = platform;
      errors = [];
      receivedFrames = [];
      feed = CameraFeed(
        onFrame: (controller, _) => receivedFrames.add(controller.cameraId),
        onChanged: (controller) =>
            platform.calls.add('published:${controller?.cameraId}'),
        onError: (error, _) => errors.add(error),
      );
      try {
        await body(tester);
      } finally {
        if (platform.stopGate case final gate? when !gate.isCompleted) {
          gate.complete();
        }
        if (platform.initializeGate case final gate? when !gate.isCompleted) {
          gate.complete();
        }
        await tester.pumpWidget(const SizedBox.shrink());
        final disposal = feed.dispose();
        await tester.pump();
        await disposal;
        // Close platform streams after the test's fake async scope.
        await tester.runAsync(platform.close);
        CameraPlatform.instance = previousPlatform;
        await tester.pump();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  Future<void> show(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(MaterialApp(home: CameraFeedPreview(feed: feed)));
    final opening = feed.setActive(true);
    await tester.pump();
    await opening;
    await tester.pump();
  }

  cameraTest('home and back repeatedly replaces preview and frame stream', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('camera:1'), findsOneWidget);
    expect(
      platform.selected.every(
        (camera) => camera.lensDirection == CameraLensDirection.back,
      ),
      isTrue,
    );
    expect(
      platform.calls.indexOf('published:1'),
      lessThan(platform.calls.indexOf('stream:1')),
    );

    for (var cameraId = 2; cameraId <= 4; cameraId++) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await feed.setActive(true);
      await tester.pump();
      expect(find.text('camera:$cameraId'), findsOneWidget);
      expect(find.text('camera:${cameraId - 1}'), findsNothing);
      expect(
        platform.calls.indexOf('stop:${cameraId - 1}'),
        lessThan(platform.calls.indexOf('dispose:${cameraId - 1}')),
      );
      expect(
        platform.calls.indexOf('dispose:${cameraId - 1}'),
        lessThan(platform.calls.indexOf('create:$cameraId')),
      );
      platform.emitFrame(cameraId);
      expect(receivedFrames.last, cameraId);
    }
    expect(errors, isEmpty);
  });

  cameraTest('resume waits for old image subscription cancellation', (
    tester,
  ) async {
    await show(tester);
    final stopped = Completer<void>();
    platform.stopGate = stopped;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(platform.created, 1);
    expect(platform.calls, contains('stop:1'));
    expect(platform.calls, isNot(contains('dispose:1')));
    stopped.complete();
    await feed.setActive(true);
    await tester.pump();
    expect(find.text('camera:2'), findsOneWidget);
    expect(errors, isEmpty);
  });

  cameraTest(
    'permission lifecycle events during initialization discard old camera',
    (tester) async {
      final initialized = Completer<void>();
      platform.initializeGate = initialized;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(MaterialApp(home: CameraFeedPreview(feed: feed)));
      final opening = feed.setActive(true);
      await tester.pump();
      expect(platform.created, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      initialized.complete();
      await opening;
      await feed.setActive(true);
      await tester.pump();
      expect(platform.calls, isNot(contains('stream:1')));
      expect(platform.calls, contains('dispose:1'));
      expect(find.text('camera:2'), findsOneWidget);
      expect(errors, isEmpty);
    },
  );

  cameraTest('history or mock mode keeps camera closed even after OS resume', (
    tester,
  ) async {
    await show(tester);
    await feed.setActive(false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(platform.created, 1);
    expect(find.text('camera:1'), findsNothing);
    await feed.setActive(true);
    await tester.pump();
    expect(find.text('camera:2'), findsOneWidget);
    expect(errors, isEmpty);
  });

  cameraTest(
    'discovery failure has a working retry and re-enumerates cameras',
    (tester) async {
      platform.failDiscovery = true;
      await show(tester);
      expect(feed.value, isNull);
      expect(errors, hasLength(1));
      platform.failDiscovery = false;
      await feed.retry();
      await tester.pump();
      expect(platform.discoveries, 2);
      expect(find.text('camera:1'), findsOneWidget);
    },
  );

  cameraTest(
    'platform errors recover once and then expose a retryable failure',
    (tester) async {
      await show(tester);
      platform.emitError(1);
      await tester.pump();
      expect(platform.created, 2);
      expect(errors, isEmpty);
      platform.emitError(2);
      await tester.pump();
      expect(platform.created, 2);
      expect(feed.value, isNull);
      expect(errors, hasLength(1));
      await feed.retry();
      await tester.pump();
      expect(find.text('camera:3'), findsOneWidget);
    },
  );

  cameraTest('a silent native stream retries once then exposes an error', (
    tester,
  ) async {
    await show(tester);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(platform.created, 2);
    expect(find.text('camera:2'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(feed.value, isNull);
    expect(errors, hasLength(1));
    await tester.pump(const Duration(seconds: 8));
    expect(platform.created, 2);
  });

  cameraTest(
    'stream startup failure releases the initialized camera before retry',
    (tester) async {
      platform.failStreamStart = true;
      await show(tester);
      expect(feed.value, isNull);
      expect(platform.calls.where((call) => call == 'dispose:1'), hasLength(1));
      expect(errors, hasLength(1));
      platform.failStreamStart = false;
      await feed.retry();
      await tester.pump();
      expect(find.text('camera:2'), findsOneWidget);
    },
  );
}

class _CameraPlatform extends CameraPlatform {
  final calls = <String>[];
  final selected = <CameraDescription>[];
  final initialized = <int, StreamController<CameraInitializedEvent>>{};
  final errors = <int, StreamController<CameraErrorEvent>>{};
  final frames = <int, StreamController<CameraImageData>>{};
  Completer<void>? initializeGate;
  Completer<void>? stopGate;
  bool failDiscovery = false;
  bool failStreamStart = false;
  int discoveries = 0;
  int created = 0;

  @override
  Future<List<CameraDescription>> availableCameras() async {
    discoveries++;
    if (failDiscovery) {
      throw CameraException('CameraAccessDenied', 'Permission denied');
    }
    return const [
      CameraDescription(
        name: 'front',
        lensDirection: CameraLensDirection.front,
        sensorOrientation: 90,
      ),
      CameraDescription(
        name: 'back',
        lensDirection: CameraLensDirection.back,
        sensorOrientation: 90,
      ),
    ];
  }

  @override
  Future<int> createCamera(
    CameraDescription cameraDescription,
    ResolutionPreset? resolutionPreset, {
    bool enableAudio = false,
  }) async {
    selected.add(cameraDescription);
    final id = ++created;
    calls.add('create:$id');
    initialized[id] = StreamController.broadcast(sync: true);
    errors[id] = StreamController.broadcast(sync: true);
    frames[id] = StreamController(
      sync: true,
      onListen: () => calls.add('stream:$id'),
      onCancel: () async {
        calls.add('stop:$id');
        await stopGate?.future;
      },
    );
    return id;
  }

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    await initializeGate?.future;
    initialized[cameraId]!.add(
      CameraInitializedEvent(
        cameraId,
        640,
        480,
        ExposureMode.auto,
        true,
        FocusMode.auto,
        true,
      ),
    );
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      initialized[cameraId]!.stream;
  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) =>
      errors[cameraId]!.stream;
  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();
  @override
  bool supportsImageStreaming() => true;
  @override
  Stream<CameraImageData> onStreamedFrameAvailable(
    int cameraId, {
    CameraImageStreamOptions? options,
  }) {
    if (failStreamStart) throw PlatformException(code: 'CameraAccess');
    return frames[cameraId]!.stream;
  }

  @override
  Widget buildPreview(int cameraId) => Text('camera:$cameraId');

  @override
  Future<void> dispose(int cameraId) async {
    // Reproduces the native lifecycle constraint hidden by a generic fake:
    // a live image subscription must be canceled before releasing the camera.
    if (frames[cameraId]?.hasListener ?? false) {
      throw StateError('image stream was not stopped');
    }
    calls.add('dispose:$cameraId');
  }

  void emitFrame(int id) => frames[id]!.add(
    CameraImageData(
      format: const CameraImageFormat(
        ImageFormatGroup.bgra8888,
        raw: 1111970369,
      ),
      planes: [CameraImagePlane(bytes: Uint8List(16), bytesPerRow: 8)],
      width: 2,
      height: 2,
    ),
  );

  void emitError(int id) =>
      errors[id]!.add(CameraErrorEvent(id, 'camera interrupted'));

  Future<void> close() async {
    for (final entry in errors.entries) {
      // CameraController uses first on this stream; complete pending listeners
      // before closing it to avoid unrelated "no element" stream errors.
      entry.value.add(CameraErrorEvent(entry.key, 'test cleanup'));
      await entry.value.close();
    }
    for (final stream in initialized.values) {
      await stream.close();
    }
    for (final entry in frames.entries) {
      if (!calls.contains('stream:${entry.key}')) {
        await entry.value.stream.listen((_) {}).cancel();
      }
      await entry.value.close();
    }
  }
}
