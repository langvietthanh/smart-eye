import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/services/feed_handle.dart';
import 'package:smart_eye/services/lidar_analysis.dart';
import 'package:smart_eye/services/lidar_feed.dart';
import 'package:smart_eye/utils/image_utils.dart';

Map<String, Object> frameEvent({String orientation = 'portraitUp'}) => {
  'type': 'frame',
  'width': 640,
  'height': 480,
  'y': Uint8List(640 * 480)..fillRange(0, 640 * 480, 200),
  'yRow': 640,
  'uv': Uint8List(640 * 240)..fillRange(0, 640 * 240, 128),
  'uvRow': 640,
  'orientation': orientation,
};

Map<String, Object> depthEvent(Uint8List depthBytes) => {
  'type': 'depth',
  'width': 4,
  'height': 2,
  'depth': depthBytes,
  'confidence': Uint8List(8)..fillRange(0, 8, 2),
  'fx': 3.0,
  'fy': 3.0,
  'cx': 1.5,
  'cy': 0.5,
  'up': [0.0, 1.0, 0.0],
  'tracking': true,
};

/// Futures from mocked channels only complete while the fake clock pumps.
Future<T> drive<T>(WidgetTester tester, Future<T> future) async {
  var done = false;
  late T value;
  future.then((v) {
    value = v;
    done = true;
  });
  for (var i = 0; i < 50 && !done; i++) {
    await tester.pump();
  }
  expect(done, isTrue, reason: 'future did not complete');
  return value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('frames become 2-plane YUV camera images the pipeline can read', () {
    final image = LidarFeed.frameImage(frameEvent())!;
    expect(image.width, 640);
    expect(image.height, 480);
    expect(image.format.group, ImageFormatGroup.yuv420);
    expect(image.planes, hasLength(2));
    expect(ImageUtils.meanLuma(image), closeTo(200, 1));
    expect(LidarFeed.frameImage({...frameEvent(), 'y': Uint8List(10)}), isNull);
  });

  test('depth packets parse, also from unaligned byte arrays', () {
    final metres = Float32List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
    final padded = Uint8List(33)..setRange(1, 33, metres.buffer.asUint8List());
    final unaligned = Uint8List.sublistView(padded, 1);
    final frame = LidarFeed.depthFrame(depthEvent(unaligned))!;
    expect(frame.depth, metres);
    expect(frame.upY, 1);
    expect(frame.fx, 3);
    expect(frame.trackingAvailable, isTrue);
    expect(
      LidarFeed.depthFrame({
        ...depthEvent(unaligned),
        'up': [0, 1],
      }),
      isNull,
    );
  });

  test('handle rotates like a sensor-90 back camera', () {
    final h = LidarHandle(1);
    expect(h.frameRotation, 90);
    expect(h.updateOrientation('landscapeLeft'), isTrue);
    expect(h.frameRotation, 0);
    expect(h.updateOrientation('landscapeLeft'), isFalse);
    expect(h.updateOrientation('faceUp'), isFalse);
    h.updateOrientation('landscapeRight');
    expect(h.frameRotation, 180);
  });

  group('lifecycle', () {
    const methods = MethodChannel('test/lidar');
    const events = EventChannel('test/lidar/events');
    late List<String> calls;
    late MockStreamHandlerEventSink? sink;
    late List<FeedHandle> frames;
    late List<LidarDepthFrame> depths;
    late List<Object> errors;
    late LidarFeed feed;

    Future<void> setUpFeed(WidgetTester tester) async {
      calls = [];
      sink = null;
      frames = [];
      depths = [];
      errors = [];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call.method);
        return switch (call.method) {
          'start' => 7,
          'isSupported' => true,
          _ => null,
        };
      });
      messenger.setMockStreamHandler(
        events,
        MockStreamHandler.inline(
          onListen: (_, s) {
            sink = s;
          },
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      feed = LidarFeed(
        onFrame: (handle, _) => frames.add(handle),
        onDepth: depths.add,
        onChanged: (_) {},
        onError: (e, _) => errors.add(e),
        methods: methods,
        events: events,
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(methods, null);
        messenger.setMockStreamHandler(events, null);
      });
    }

    testWidgets('starts, delivers frames with acks, and stops', (tester) async {
      await setUpFeed(tester);
      expect(await drive(tester, LidarFeed.isSupported(methods)), isTrue);
      await drive(tester, feed.setActive(true));
      expect(calls, ['isSupported', 'start']);
      final handle = feed.value as LidarHandle;
      expect(handle.textureId, 7);

      sink!.success(frameEvent(orientation: 'landscapeLeft'));
      sink!.success(depthEvent(Uint8List(32)));
      await tester.pump();
      expect(frames, [handle]);
      expect(handle.deviceOrientation, DeviceOrientation.landscapeLeft);
      expect(depths, hasLength(1));
      expect(calls.last, 'ackFrame');

      await drive(tester, feed.setActive(false));
      expect(calls.last, 'stop');
      expect(feed.value, isNull);
      await drive(tester, feed.dispose());
    });

    testWidgets('a silent session restarts once, then reports an error', (
      tester,
    ) async {
      await setUpFeed(tester);
      await drive(tester, feed.setActive(true));
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(calls.where((c) => c == 'start'), hasLength(2));
      expect(errors, isEmpty);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(errors, hasLength(1));
      expect(feed.value, isNull);
      await drive(tester, feed.dispose());
    });

    testWidgets('an interruption pauses the watchdog', (tester) async {
      await setUpFeed(tester);
      await drive(tester, feed.setActive(true));
      sink!.success({'type': 'interrupted'});
      await tester.pump(const Duration(seconds: 9));
      expect(calls.where((c) => c == 'start'), hasLength(1));
      expect(errors, isEmpty);
      await drive(tester, feed.dispose());
    });

    testWidgets('going to the background stops the session', (tester) async {
      await setUpFeed(tester);
      await drive(tester, feed.setActive(true));
      feed.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump();
      expect(calls.last, 'stop');
      feed.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(calls.last, 'start');
      await drive(tester, feed.dispose());
    });
  });

  test('depth worker analyses frames off the UI isolate', () async {
    final service = LidarDepthService();
    await service.start();
    final frame = LidarDepthFrame(
      width: 8,
      height: 8,
      depth: Float32List(64),
      confidence: Uint8List(64),
      fx: 5,
      fy: 5,
      cx: 4,
      cy: 4,
      upX: 0,
      upY: 1,
      upZ: 0,
    );
    final scan = await service.analyze(frame);
    expect(scan, isA<LidarScan>());
    expect(scan!.center, isA<LidarUnknown>());
    await service.dispose();
    expect(await service.analyze(frame), isNull);
  });
}
