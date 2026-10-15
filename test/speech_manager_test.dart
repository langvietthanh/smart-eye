import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/services/speech_manager.dart';
import 'package:smart_eye/services/tts_service.dart';

class FakeTts implements TTSService {
  final List<String> spoken = [];
  Completer<void>? _speaking;
  Completer<void>? stopGate;
  int stopCount = 0;

  @override
  bool vietnameseAvailable = true;

  @override
  bool get isSpeaking => _speaking != null;

  @override
  Future<void> init() async {}

  @override
  Future<void> speak(String text) {
    spoken.add(text);
    _speaking = Completer<void>();
    return _speaking!.future;
  }

  void finish() {
    final speaking = _speaking;
    _speaking = null;
    if (speaking != null && !speaking.isCompleted) speaking.complete();
  }

  @override
  Future<void> stop() async {
    stopCount++;
    await stopGate?.future;
    // A delayed platform stop would also cancel a newer utterance, if one was
    // incorrectly sent while this stop command was still pending.
    finish();
  }
}

SpeechManager managerFor(WidgetTester tester, FakeTts tts) =>
    SpeechManager.forTesting(tts: tts, now: tester.binding.clock.now);

void main() {
  testWidgets('danger waits for native stop before interrupting description', (
    tester,
  ) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    final description = manager.sayAndWait('Mô tả', SpeechPriority.description);
    tts.stopGate = Completer<void>();

    final danger = manager.sayAndWait('Dừng lại', SpeechPriority.danger);
    await tester.pump();
    expect(await description, isFalse);
    expect(tts.spoken, ['Mô tả']);
    expect(manager.isBusy, isTrue);

    tts.stopGate!.complete();
    await tester.pump();
    expect(tts.spoken, ['Mô tả', 'Dừng lại']);
    tts.finish();
    await tester.pump();
    expect(await danger, isTrue);
    await manager.stopAll();
  });

  testWidgets(
    'stopAll during interruption drops waiting danger and shares stop',
    (tester) async {
      final tts = FakeTts();
      final manager = managerFor(tester, tts);
      manager.say('Mô tả', SpeechPriority.description);
      tts.stopGate = Completer<void>();
      final danger = manager.sayAndWait('Dừng lại', SpeechPriority.danger);
      final stopped = manager.stopAll();
      await tester.pump();

      expect(await danger, isFalse);
      expect(tts.stopCount, 1);
      tts.stopGate!.complete();
      await stopped;
      await tester.pump();
      expect(tts.spoken, ['Mô tả']);
      expect(manager.isBusy, isFalse);
      expect(manager.showing.value, isNull);
    },
  );

  testWidgets('only latest danger survives while native stop is pending', (
    tester,
  ) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    manager.say('Mô tả', SpeechPriority.description);
    tts.stopGate = Completer<void>();
    final oldDanger = manager.sayAndWait(
      'Xe phía trước',
      SpeechPriority.danger,
    );
    final newDanger = manager.sayAndWait(
      'Dừng lại ngay',
      SpeechPriority.danger,
    );
    await tester.pump();
    expect(await oldDanger, isFalse);

    tts.stopGate!.complete();
    await tester.pump();
    expect(tts.spoken, ['Mô tả', 'Dừng lại ngay']);
    tts.finish();
    await tester.pump();
    expect(await newDanger, isTrue);
    await manager.stopAll();
  });

  testWidgets('stopAll cancels quiet-gap wakeup timers and queued speech', (
    tester,
  ) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    manager.say('Mô tả đầu', SpeechPriority.description);
    tts.finish();
    await tester.pump();

    final second = manager.sayAndWait('Mô tả tiếp', SpeechPriority.description);
    final third = manager.sayAndWait('Tóm tắt', SpeechPriority.description);
    expect(tts.spoken, ['Mô tả đầu']);
    await manager.stopAll();
    expect(await second, isFalse);
    expect(await third, isFalse);
    expect(manager.isBusy, isFalse);
    // Ending without advancing fake time also verifies that no wakeup or hide
    // timer remains: testWidgets rejects pending timers after this body exits.
  });

  testWidgets('danger bypasses quiet gap while descriptions still wait', (
    tester,
  ) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    manager.say('Mô tả đầu', SpeechPriority.description);
    tts.finish();
    await tester.pump();
    manager.say('Mô tả tiếp', SpeechPriority.description);
    await tester.pump(const Duration(seconds: 1));
    expect(tts.spoken, ['Mô tả đầu']);

    manager.say('Dừng lại', SpeechPriority.danger);
    expect(tts.spoken, ['Mô tả đầu', 'Dừng lại']);
    tts.finish();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(tts.spoken, ['Mô tả đầu', 'Dừng lại']);
    await tester.pump(const Duration(seconds: 1));
    expect(tts.spoken, ['Mô tả đầu', 'Dừng lại', 'Mô tả tiếp']);
    await manager.stopAll();
  });

  testWidgets(
    'expired cooldown entries are removed but active subject stays deduped',
    (tester) async {
      final tts = FakeTts();
      final manager = managerFor(tester, tts);
      manager.say('Dừng lại', SpeechPriority.danger, subject: 'track:1');
      expect(manager.cooldownEntryCount, 1);
      expect(
        manager.canSay(SpeechPriority.danger, subject: 'track:1'),
        isFalse,
      );

      await tester.pump(const Duration(seconds: 7));
      expect(
        manager.canSay(SpeechPriority.danger, subject: 'track:1'),
        isFalse,
      );
      expect(manager.cooldownEntryCount, 0);
      tts.finish();
      await tester.pump();
      expect(manager.canSay(SpeechPriority.danger, subject: 'track:1'), isTrue);
      manager.say('Vật khác', SpeechPriority.danger, subject: 'track:2');
      expect(manager.cooldownEntryCount, 1);
      await manager.stopAll();
    },
  );

  testWidgets('escalation bypasses subject cooldown and still waits for stop', (
    tester,
  ) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    manager.say('Cẩn thận', SpeechPriority.caution, subject: 'track:1');
    expect(manager.canSay(SpeechPriority.caution, subject: 'track:1'), isFalse);
    expect(manager.canSay(SpeechPriority.danger, subject: 'track:1'), isTrue);
    tts.stopGate = Completer<void>();
    manager.say('Dừng lại', SpeechPriority.danger, subject: 'track:1');
    expect(tts.spoken, ['Cẩn thận']);

    tts.stopGate!.complete();
    await tester.pump();
    expect(tts.spoken, ['Cẩn thận', 'Dừng lại']);
    expect(manager.canSay(SpeechPriority.caution, subject: 'track:1'), isFalse);
    await manager.stopAll();
  });

  testWidgets(
    'stale danger after slow stop does not consume subject cooldown',
    (tester) async {
      final tts = FakeTts();
      final manager = managerFor(tester, tts);
      manager.say('Mô tả', SpeechPriority.description);
      tts.stopGate = Completer<void>();
      manager.say('Dừng lại', SpeechPriority.danger, subject: 'track:1');
      await tester.pump(const Duration(seconds: 3));
      tts.stopGate!.complete();
      await tester.pump();

      expect(tts.spoken, ['Mô tả']);
      expect(manager.canSay(SpeechPriority.danger, subject: 'track:1'), isTrue);
      expect(manager.cooldownEntryCount, 0);
      await manager.stopAll();
    },
  );
}
