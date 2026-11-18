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
  testWidgets('changed position replaces a queued alert at the same priority', (
    tester,
  ) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    manager.say('Mô tả', SpeechPriority.description);
    tts.stopGate = Completer<void>();
    manager.say('Xe bên trái', SpeechPriority.caution, subject: 'track:1');
    manager.retainAlerts(
      subject: 'track:1',
      priority: SpeechPriority.caution,
      text: 'Xe bên phải',
    );
    expect(
      manager.say('Xe bên phải', SpeechPriority.caution, subject: 'track:1'),
      isTrue,
    );
    tts.stopGate!.complete();
    await tester.pump();
    expect(tts.spoken, ['Mô tả', 'Xe bên phải']);
    await manager.stopAll();
  });

  testWidgets('lower scene risk replaces a pending stop for the same subject', (
    tester,
  ) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    manager.say('Mô tả', SpeechPriority.description);
    tts.stopGate = Completer<void>();
    var dangerDispatched = false;
    manager.say(
      'Dừng lại',
      SpeechPriority.danger,
      subject: 'track:1',
      onStart: () => dangerDispatched = true,
    );
    manager.retainAlerts(subject: 'track:1', priority: SpeechPriority.caution);
    expect(manager.canSay(SpeechPriority.caution, subject: 'track:1'), isTrue);
    manager.say('Đi chậm lại', SpeechPriority.caution, subject: 'track:1');
    tts.stopGate!.complete();
    await tester.pump();

    expect(tts.spoken, ['Mô tả', 'Đi chậm lại']);
    expect(dangerDispatched, isFalse);
    await manager.stopAll();
  });

  testWidgets('danger replaces pending caution for the same subject', (
    tester,
  ) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    manager.say('Mô tả', SpeechPriority.description);
    tts.stopGate = Completer<void>();
    var cautionDispatched = false;
    manager.say(
      'Đi chậm lại',
      SpeechPriority.caution,
      subject: 'track:1',
      onStart: () => cautionDispatched = true,
    );
    manager.say('Dừng lại', SpeechPriority.danger, subject: 'track:1');
    expect(manager.canSay(SpeechPriority.caution, subject: 'track:1'), isFalse);
    tts.stopGate!.complete();
    await tester.pump();
    tts.finish();
    await tester.pump();

    expect(tts.spoken, ['Mô tả', 'Dừng lại']);
    expect(cautionDispatched, isFalse);
    await manager.stopAll();
  });

  testWidgets('caution starts immediately after a completed description', (
    tester,
  ) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    manager.say('Mô tả', SpeechPriority.description);
    tts.finish();
    await tester.pump();

    manager.say('Đi chậm lại', SpeechPriority.caution, subject: 'track:1');
    expect(tts.spoken, ['Mô tả', 'Đi chậm lại']);
    await manager.stopAll();
  });

  testWidgets(
    'caution interrupts lower priority without waiting for quiet gap',
    (tester) async {
      final tts = FakeTts();
      final manager = managerFor(tester, tts);
      manager.say('Mô tả', SpeechPriority.description);
      tts.finish();
      await tester.pump();
      manager.say('Nghe lại', SpeechPriority.playback);
      tts.stopGate = Completer<void>();
      manager.say('Đi chậm lại', SpeechPriority.caution, subject: 'track:1');
      expect(tts.spoken, ['Mô tả', 'Nghe lại']);

      tts.stopGate!.complete();
      await tester.pump();
      expect(tts.spoken, ['Mô tả', 'Nghe lại', 'Đi chậm lại']);
      await manager.stopAll();
    },
  );

  testWidgets(
    'scene invalidation drops queued alerts but keeps manual description',
    (tester) async {
      final tts = FakeTts();
      final manager = managerFor(tester, tts);
      manager.say('Dừng lại', SpeechPriority.danger);
      final caution = manager.sayAndWait(
        'Cảnh báo cũ',
        SpeechPriority.caution,
        subject: 'track:1',
      );
      final description = manager.sayAndWait(
        'Mô tả khi hỏi',
        SpeechPriority.description,
      );
      manager.retainAlerts();
      expect(await caution, isFalse);

      tts.finish();
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(tts.spoken, ['Dừng lại', 'Mô tả khi hỏi']);
      tts.finish();
      await tester.pump();
      expect(await description, isTrue);
      await manager.stopAll();
    },
  );

  testWidgets(
    'retaining the current subject drops an old queued alert during stop',
    (tester) async {
      final tts = FakeTts();
      final manager = managerFor(tester, tts);
      manager.say('Mô tả', SpeechPriority.description);
      tts.stopGate = Completer<void>();
      manager.say('Vật cản cũ', SpeechPriority.caution, subject: 'track:1');
      manager.say(
        'Vật cản hiện tại',
        SpeechPriority.danger,
        subject: 'track:2',
      );
      manager.retainAlerts(subject: 'track:2');
      tts.stopGate!.complete();
      await tester.pump();

      expect(tts.spoken, ['Mô tả', 'Vật cản hiện tại']);
      tts.finish();
      await tester.pump();
      expect(tts.spoken, ['Mô tả', 'Vật cản hiện tại']);
      expect(
        manager.canSay(SpeechPriority.caution, subject: 'track:1'),
        isTrue,
      );
      await manager.stopAll();
    },
  );

  testWidgets('retainAlerts only drops track alerts and retains depth alert', (
    tester,
  ) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    manager.say('Đang nói', SpeechPriority.playback);
    tts.stopGate = Completer<void>();

    final track1 = manager.sayAndWait(
      'Vật cản cũ',
      SpeechPriority.caution,
      subject: 'track:1',
    );
    final depth = manager.sayAndWait(
      'Dừng lại! Có vật cản ngay phía trước.',
      SpeechPriority.danger,
      subject: 'depth:center',
    );

    // YOLO has no alert this frame (subject: null)
    manager.retainAlerts();

    expect(await track1, isFalse);

    tts.stopGate!.complete();
    await tester.pump();

    while (manager.isBusy) {
      tts.finish();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(await depth, isTrue);
    expect(tts.spoken, ['Đang nói', 'Dừng lại! Có vật cản ngay phía trước.']);
    await manager.stopAll();
  });

  testWidgets(
    'retainAlerts only drops track alerts and retains sight and unassigned alerts',
    (tester) async {
      final tts = FakeTts();
      final manager = managerFor(tester, tts);
      manager.say('Đang nói', SpeechPriority.playback);
      tts.stopGate = Completer<void>();

      final trackDanger = manager.sayAndWait(
        'Nguy hiểm cũ',
        SpeechPriority.danger,
        subject: 'track:1',
      );
      final sight = manager.sayAndWait(
        'Không đo được khoảng cách. Đi chậm, dùng gậy.',
        SpeechPriority.caution,
        subject: 'sight:noDepth',
      );

      // YOLO has no alert this frame (subject: null)
      manager.retainAlerts();

      expect(await trackDanger, isFalse);

      tts.stopGate!.complete();
      await tester.pump();

      while (manager.isBusy) {
        tts.finish();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(await sight, isTrue);
      expect(tts.spoken, [
        'Đang nói',
        'Không đo được khoảng cách. Đi chậm, dùng gậy.',
      ]);

      // Verify unassigned alert (subject == null) is also retained
      final unassigned = manager.sayAndWait(
        'Thông báo chung',
        SpeechPriority.caution,
      );
      manager.retainAlerts();
      while (manager.isBusy) {
        tts.finish();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(await unassigned, isTrue);
      expect(tts.spoken, contains('Thông báo chung'));

      await manager.stopAll();
    },
  );

  testWidgets(
    'retainAlerts with another track subject drops old track alert but retains depth alert',
    (tester) async {
      final tts = FakeTts();
      final manager = managerFor(tester, tts);
      manager.say('Đang nói', SpeechPriority.playback);
      tts.stopGate = Completer<void>();

      final track1 = manager.sayAndWait(
        'Vật cản cũ',
        SpeechPriority.caution,
        subject: 'track:1',
      );
      final depth = manager.sayAndWait(
        'Dừng lại! Có vật cản ngay phía trước.',
        SpeechPriority.danger,
        subject: 'depth:center',
      );

      // YOLO alert changed to track:2
      manager.retainAlerts(
        subject: 'track:2',
        priority: SpeechPriority.danger,
        text: 'Dừng lại',
      );

      expect(await track1, isFalse);

      tts.stopGate!.complete();
      await tester.pump();

      while (manager.isBusy) {
        tts.finish();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(await depth, isTrue);
      expect(tts.spoken, isNot(contains('Vật cản cũ')));
      expect(tts.spoken, contains('Dừng lại! Có vật cản ngay phía trước.'));
      await manager.stopAll();
    },
  );

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

  testWidgets('dropSubject stops the current utterance of that subject', (
    tester,
  ) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    final trapped = manager.sayAndWait(
      'Đứng lại!',
      SpeechPriority.danger,
      subject: 'path:trapped',
    );
    manager.dropSubject('avoidance');
    expect(manager.showing.value?.text, 'Đứng lại!');
    expect(tts.stopCount, 0);

    tts.stopGate = Completer<void>();
    manager.dropSubject('path:trapped');
    expect(manager.showing.value, isNull);
    manager.say(
      'Đường đi thông thoáng.',
      SpeechPriority.caution,
      subject: 'path:cleared',
    );
    tts.stopGate!.complete();
    await tester.pump();

    expect(await trapped, isFalse);
    expect(tts.stopCount, 1);
    expect(tts.spoken, ['Đứng lại!', 'Đường đi thông thoáng.']);
    await manager.stopAll();
  });

  testWidgets('dropSubject clears only the matching completed banner', (
    tester,
  ) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    manager.say('Lệch trái', SpeechPriority.guidance, subject: 'avoidance');
    tts.finish();
    await tester.pump();
    manager.dropSubject('track:1');
    expect(manager.showing.value?.text, 'Lệch trái');
    manager.dropSubject('avoidance');
    expect(manager.showing.value, isNull);
    expect(tts.stopCount, 0);

    manager.say('Dừng lại', SpeechPriority.danger, subject: 'track:1');
    manager.dropSubject('avoidance');
    await tester.pump(const Duration(seconds: 3));
    expect(manager.showing.value?.text, 'Dừng lại');
    expect(tts.stopCount, 0);
    await manager.stopAll();
  });

  testWidgets('dropSubject removes queued requests of that subject only', (
    tester,
  ) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    manager.say('Dừng lại', SpeechPriority.danger, subject: 'track:1');
    final trapped = manager.sayAndWait(
      'Vẫn bị chặn.',
      SpeechPriority.danger,
      subject: 'path:trapped',
    );
    final other = manager.sayAndWait(
      'Không đo được khoảng cách.',
      SpeechPriority.caution,
      subject: 'sight:noDepth',
    );
    manager.dropSubject('path:trapped');
    expect(await trapped, isFalse);
    expect(tts.stopCount, 0);

    tts.finish();
    await tester.pump();
    tts.finish();
    await tester.pump();
    expect(await other, isTrue);
    expect(tts.spoken, ['Dừng lại', 'Không đo được khoảng cách.']);
    await manager.stopAll();
  });

  testWidgets('sayNow repeats a state line inside its cooldown', (
    tester,
  ) async {
    // "Xoay tiếp." / "Dừng lại! Xoay người tìm lối." mark a state change: a
    // cooldown that silences them leaves the user turning with no guidance.
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    expect(
      manager.sayNow('Xoay tiếp.', SpeechPriority.danger, subject: 'path:turn'),
      isTrue,
    );
    tts.finish();
    await tester.pump();
    expect(
      manager.say('Xoay tiếp.', SpeechPriority.danger, subject: 'path:turn'),
      isFalse,
    );
    expect(
      manager.sayNow('Xoay tiếp.', SpeechPriority.danger, subject: 'path:turn'),
      isTrue,
    );
    await tester.pump();
    expect(tts.spoken, ['Xoay tiếp.', 'Xoay tiếp.']);
    await manager.stopAll();
  });

  testWidgets('dropSubject forgets that subject cooldown only', (tester) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    manager.say('Đứng lại!', SpeechPriority.danger, subject: 'path:trapped');
    tts.finish();
    await tester.pump();
    manager.say('Dừng lại', SpeechPriority.danger, subject: 'track:1');
    tts.finish();
    await tester.pump();
    expect(
      manager.canSay(SpeechPriority.danger, subject: 'path:trapped'),
      isFalse,
    );

    manager.dropSubject('path:trapped');
    expect(
      manager.canSay(SpeechPriority.danger, subject: 'path:trapped'),
      isTrue,
    );
    expect(manager.canSay(SpeechPriority.danger, subject: 'track:1'), isFalse);
    expect(tts.stopCount, 0);
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

  testWidgets('guidance interrupts description', (tester) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    manager.say('Mô tả', SpeechPriority.description);
    manager.say('Đi thẳng', SpeechPriority.guidance, subject: 'nav');
    await tester.pump();
    expect(tts.stopCount, 1);
    expect(tts.spoken, ['Mô tả', 'Đi thẳng']);
    expect(manager.showing.value?.priority, SpeechPriority.guidance);
    await manager.stopAll();
  });

  testWidgets('invalid guidance is rejected without interrupting speech', (
    tester,
  ) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    manager.say('Mô tả', SpeechPriority.description);
    var started = false;
    expect(
      manager.say(
        'Lệch trái',
        SpeechPriority.guidance,
        subject: 'avoidance',
        isStillValid: () => false,
        onStart: () => started = true,
      ),
      isFalse,
    );
    expect(
      await manager.sayAndWait(
        'Lệch phải',
        SpeechPriority.guidance,
        subject: 'avoidance',
        isStillValid: () => false,
      ),
      isFalse,
    );
    expect(tts.spoken, ['Mô tả']);
    expect(tts.stopCount, 0);
    expect(started, isFalse);
    expect(manager.cooldownEntryCount, 0);
    await manager.stopAll();
  });

  testWidgets('validity is checked again after a delayed native stop', (
    tester,
  ) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    manager.say('Mô tả', SpeechPriority.description);
    tts.stopGate = Completer<void>();
    var valid = true;
    var started = false;
    expect(
      manager.say(
        'Dừng lại và quét trái',
        SpeechPriority.caution,
        subject: 'avoidance',
        isStillValid: () => valid,
        onStart: () => started = true,
      ),
      isTrue,
    );
    valid = false;
    tts.stopGate!.complete();
    await tester.pump();

    expect(tts.spoken, ['Mô tả']);
    expect(started, isFalse);
    expect(manager.isBusy, isFalse);
    expect(manager.cooldownEntryCount, 0);
    expect(manager.canSay(SpeechPriority.caution, subject: 'avoidance'), isTrue);
    await manager.stopAll();
  });

  testWidgets('invalid guidance waiting behind danger is dropped and resolved', (
    tester,
  ) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    manager.say('Dừng lại', SpeechPriority.danger);
    var valid = true;
    final queued = manager.sayAndWait(
      'Lệch trái',
      SpeechPriority.guidance,
      subject: 'avoidance',
      isStillValid: () => valid,
    );
    manager.say('Hãy đứng yên', SpeechPriority.guidance);
    valid = false;
    tts.finish();
    await tester.pump();

    expect(await queued, isFalse);
    expect(tts.spoken, ['Dừng lại', 'Hãy đứng yên']);
    expect(manager.cooldownEntryCount, 0);
    await manager.stopAll();
  });

  testWidgets('validity check failures reject speech at enqueue and dispatch', (
    tester,
  ) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    bool missingSensor() => throw StateError('Sensor unavailable');
    expect(
      manager.say(
        'Lệch trái',
        SpeechPriority.guidance,
        subject: 'avoidance',
        isStillValid: missingSensor,
      ),
      isFalse,
    );
    expect(tts.spoken, isEmpty);

    manager.say('Dừng lại', SpeechPriority.danger);
    var sensorAvailable = true;
    final queued = manager.sayAndWait(
      'Lệch phải',
      SpeechPriority.guidance,
      subject: 'avoidance',
      isStillValid: () => sensorAvailable ? true : missingSensor(),
    );
    sensorAvailable = false;
    tts.finish();
    await tester.pump();
    expect(await queued, isFalse);
    expect(tts.spoken, ['Dừng lại']);
    expect(manager.cooldownEntryCount, 0);
    await manager.stopAll();
  });

  testWidgets('sayNow rejects invalid replacement before cancelling speech', (
    tester,
  ) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    manager.say('Đứng yên', SpeechPriority.guidance, subject: 'avoidance');
    expect(
      manager.sayNow(
        'Lệch trái',
        SpeechPriority.guidance,
        subject: 'avoidance',
        isStillValid: () => false,
      ),
      isFalse,
    );
    expect(tts.spoken, ['Đứng yên']);
    expect(manager.showing.value?.text, 'Đứng yên');
    expect(tts.stopCount, 0);
    await manager.stopAll();
  });

  testWidgets('sayNow rechecks replacement validity after stopping old direction', (
    tester,
  ) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    final old = manager.sayAndWait(
      'Lệch trái',
      SpeechPriority.guidance,
      subject: 'avoidance',
    );
    tts.stopGate = Completer<void>();
    var valid = true;
    var started = false;
    expect(
      manager.sayNow(
        'Lệch phải',
        SpeechPriority.guidance,
        subject: 'avoidance',
        isStillValid: () => valid,
        onStart: () => started = true,
      ),
      isTrue,
    );
    expect(manager.showing.value, isNull);
    valid = false;
    tts.stopGate!.complete();
    await tester.pump();

    expect(await old, isFalse);
    expect(tts.spoken, ['Lệch trái']);
    expect(started, isFalse);
    expect(manager.showing.value, isNull);
    expect(manager.cooldownEntryCount, 0);
    await manager.stopAll();
  });

  testWidgets('caution interrupts guidance', (tester) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    manager.say('Đi thẳng', SpeechPriority.guidance, subject: 'nav');
    manager.say('Xe bên trái', SpeechPriority.caution, subject: 'track:1');
    await tester.pump();
    expect(tts.stopCount, 1);
    expect(tts.spoken, ['Đi thẳng', 'Xe bên trái']);
    expect(manager.showing.value?.priority, SpeechPriority.caution);
    await manager.stopAll();
  });

  testWidgets('guidance does not interrupt guidance of the same nav subject', (
    tester,
  ) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    manager.say('Lệch trái', SpeechPriority.guidance, subject: 'nav');
    expect(manager.canSay(SpeechPriority.guidance, subject: 'nav'), isFalse);
    expect(
      manager.say('Lệch phải', SpeechPriority.guidance, subject: 'nav'),
      isFalse,
    );
    expect(tts.stopCount, 0);
    expect(tts.spoken, ['Lệch trái']);
    await manager.stopAll();
  });

  testWidgets('guidance older than 2 seconds is dropped', (tester) async {
    final tts = FakeTts();
    final manager = managerFor(tester, tts);
    manager.say('Dừng lại, vật cản rất dài', SpeechPriority.danger);
    final queued = manager.sayAndWait(
      'Đi thẳng',
      SpeechPriority.guidance,
      subject: 'nav',
    );
    await tester.pump(const Duration(seconds: 3));
    tts.finish();
    await tester.pump();
    expect(await queued, isFalse);
    expect(tts.spoken, ['Dừng lại, vật cản rất dài']);
    await manager.stopAll();
  });
  testWidgets(
    'alertActive: true while a caution or danger line is current or queued',
    (tester) async {
      final tts = FakeTts();
      final manager = managerFor(tester, tts);
      expect(manager.alertActive, isFalse);
      manager.say('Mô tả', SpeechPriority.description);
      manager.say('Đi thẳng', SpeechPriority.guidance, subject: 'nav');
      await tester.pump();
      expect(manager.alertActive, isFalse);
      manager.say('Xe bên trái', SpeechPriority.caution, subject: 'track:1');
      expect(manager.alertActive, isTrue);
      expect(manager.isSubjectActive('track:1'), isTrue);
      expect(manager.isSubjectActive('path:findway'), isFalse);
      await tester.pump();
      expect(tts.spoken.last, 'Xe bên trái');
      expect(manager.alertActive, isTrue);
      tts.finish();
      await tester.pump();
      expect(manager.alertActive, isFalse);
      expect(manager.isSubjectActive('track:1'), isFalse);
      manager.say('Dừng lại', SpeechPriority.danger, subject: 'track:2');
      expect(manager.alertActive, isTrue);
      expect(manager.isSubjectActive('track:2'), isTrue);
      await manager.stopAll();
      expect(manager.alertActive, isFalse);
      expect(manager.isSubjectActive('track:2'), isFalse);
    },
  );
}
