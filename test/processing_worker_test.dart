import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/models/Recognition.dart';
import 'package:smart_eye/services/processing_worker.dart';

class _CounterProcessor implements IsolateProcessor<String, int> {
  _CounterProcessor({this.failInitialization = false, this.events});

  final bool failInitialization;
  final SendPort? events;
  int count = 0;

  @override
  void initialize() {
    if (failInitialization) throw StateError('initialization failed');
  }

  @override
  Future<int> process(String request) async {
    if (request == 'fail') throw StateError('bad frame');
    if (request == 'exit') Isolate.exit();
    if (request == 'wait') {
      final resume = ReceivePort();
      events!.send(resume.sendPort);
      await resume.first;
      resume.close();
    }
    return ++count;
  }

  @override
  void dispose() => events?.send('disposed');
}

class _ImageProcessor implements IsolateProcessor<CameraImage, Recognition> {
  @override
  void initialize() {}

  @override
  Recognition process(CameraImage image) => Recognition(
    0,
    'person',
    image.planes.first.bytes.first / 255,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    labelEn: 'person',
  );

  @override
  void dispose() {}
}

class _EchoProcessor implements IsolateProcessor<Object, String> {
  @override
  void initialize() {}

  @override
  String process(Object request) => request.toString();

  @override
  void dispose() {}
}

void main() {
  test('worker keeps state and recovers after a single bad frame', () async {
    final worker = await ProcessingWorker.start(_CounterProcessor());
    addTearDown(worker.close);
    expect(await worker.run('frame'), 1);
    await expectLater(worker.run('fail'), throwsA(isA<RemoteError>()));
    expect(await worker.run('frame'), 2);
  });

  test(
    'rejects queued frames and closes only after active processing',
    () async {
      final events = ReceivePort();
      final iterator = StreamIterator(events);
      final worker = await ProcessingWorker.start(
        _CounterProcessor(events: events.sendPort),
      );
      addTearDown(() async {
        await worker.close();
        await iterator.cancel();
        events.close();
      });
      final frame = worker.run('wait');
      expect(await iterator.moveNext(), isTrue);
      final resume = iterator.current as SendPort;
      await expectLater(worker.run('frame'), throwsStateError);
      final closed = worker.close();
      expect(identical(closed, worker.close()), isTrue);
      await expectLater(worker.run('frame'), throwsStateError);
      resume.send(null);
      expect(await frame, 1);
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current, 'disposed');
      await closed;
    },
  );

  test('initialization errors reach the caller instead of hanging', () async {
    await expectLater(
      ProcessingWorker.start(_CounterProcessor(failInitialization: true)),
      throwsA(isA<RemoteError>()),
    );
  });

  test('an unsendable request does not leave the worker busy', () async {
    final worker = await ProcessingWorker.start(_EchoProcessor());
    final port = ReceivePort();
    addTearDown(worker.close);
    addTearDown(port.close);
    await expectLater(worker.run(port), throwsArgumentError);
    expect(await worker.run('next frame'), 'next frame');
  });

  test(
    'unexpected worker exit completes an active request with error',
    () async {
      final worker = await ProcessingWorker.start(_CounterProcessor());
      await expectLater(worker.run('exit'), throwsStateError);
      await worker.close();
      await expectLater(worker.run('frame'), throwsStateError);
    },
  );

  test(
    'camera bytes and recognition geometry cross the isolate boundary',
    () async {
      final worker = await ProcessingWorker.start(_ImageProcessor());
      addTearDown(worker.close);
      // ignore: deprecated_member_use
      final image = CameraImage.fromPlatformData({
        'format': 1111970369,
        'width': 1,
        'height': 1,
        'planes': [
          {
            'bytes': Uint8List.fromList([128, 0, 0, 255]),
            'bytesPerRow': 4,
            'bytesPerPixel': 4,
          },
        ],
      });
      final result = await worker.run(image);
      expect(result.score, 128 / 255);
      expect(result.location, const Rect.fromLTWH(0, 0, 1, 1));
      expect(result.labelEn, 'person');
    },
  );
}
