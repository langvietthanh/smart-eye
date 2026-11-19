import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/services/depth_alert.dart';
import 'package:smart_eye/services/speech_manager.dart';
import 'package:smart_eye/services/tts_service.dart';
import 'package:smart_eye/services/walk_state.dart';

class _HeldTts implements TTSService {
  final spoken = <String>[];
  Completer<void>? _active;

  @override
  bool vietnameseAvailable = true;

  @override
  bool get isSpeaking => _active != null;

  @override
  Future<void> init() async {}

  @override
  Future<void> speak(String text) {
    spoken.add(text);
    _active = Completer<void>();
    return _active!.future;
  }

  void finish() {
    final active = _active;
    _active = null;
    if (active != null && !active.isCompleted) active.complete();
  }

  @override
  Future<void> stop() async => finish();
}

void main() {
  testWidgets('reminder time advances on TTS start, not while waiting', (
    tester,
  ) async {
    final tts = _HeldTts();
    final manager = SpeechManager.forTesting(
      tts: tts,
      now: tester.binding.clock.now,
    );
    final walk = WalkState();
    DateTime now() => tester.binding.clock.now();
    WalkCue? blocked() => walk.tick(
      now(),
      aheadOpen: false,
      turning: false,
      turnedDegrees: 0,
    );

    walk.onDanger(wall: false, sideOpen: false, canBypass: false);
    final revision = walk.revision;
    // Hold another danger to exercise a genuinely queued first prompt.
    manager.say('Cảnh báo khác.', SpeechPriority.danger, subject: 'sight:test');
    expect(
      manager.sayNow(
        findWayText,
        SpeechPriority.danger,
        subject: 'path:findway',
        isStillValid: () => walk.revision == revision,
        onStart: () => walk.markFindWayPromptStarted(revision, now()),
      ),
      isTrue,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(blocked(), isNull);
    expect(tts.spoken, ['Cảnh báo khác.']);
    expect(manager.isSubjectActive('path:findway'), isTrue);

    tts.finish();
    await tester.pump();
    expect(tts.spoken.last, findWayText);
    await tester.pump(WalkState.findWayRepeat);
    expect(blocked(), WalkCue.findWayReminder);
    expect(manager.isBusy, isTrue);
    // The caller waits for idle speech: being due cannot replace the
    // currently speaking initial safety prompt or consume the next period.
    expect(manager.isSubjectActive('path:findway'), isTrue);
    tts.finish();
    await tester.pump();
    expect(blocked(), WalkCue.findWayReminder);
    expect(manager.isBusy, isFalse);

    manager.sayNow(
      findWayReminderText,
      SpeechPriority.danger,
      subject: 'path:reminder',
      isStillValid: () => walk.revision == revision,
      onStart: () => walk.markFindWayCueStarted(revision, now()),
    );
    expect(tts.spoken, [
      'Cảnh báo khác.',
      findWayText,
      findWayReminderText,
    ]);
    expect(blocked(), isNull);
    await tester.pump(const Duration(seconds: 5));
    expect(blocked(), isNull);
    await tester.pump(const Duration(seconds: 1));
    expect(blocked(), WalkCue.findWayReminder);
    await manager.stopAll();
  });

  testWidgets('queued status cannot speak after straight closes its episode', (
    tester,
  ) async {
    final tts = _HeldTts();
    final manager = SpeechManager.forTesting(
      tts: tts,
      now: tester.binding.clock.now,
    );
    final walk = WalkState();
    DateTime now() => tester.binding.clock.now();
    walk.onDanger(wall: false, sideOpen: false, canBypass: false);
    final oldRevision = walk.revision;
    manager.sayNow(
      findWayText,
      SpeechPriority.danger,
      subject: 'path:findway',
      onStart: () => walk.markFindWayPromptStarted(oldRevision, now()),
    );
    tts.finish();
    await tester.pump();

    // A status can become obsolete before its queued speech is dispatched.
    manager.say('Cảnh báo khác.', SpeechPriority.danger, subject: 'sight:test');
    var staleStatusStarted = false;
    manager.sayNow(
      findWayReminderText,
      SpeechPriority.danger,
      subject: 'path:reminder',
      isStillValid: () =>
          walk.phase == WalkPhase.findWay && walk.revision == oldRevision,
      onStart: () {
        staleStatusStarted = true;
        walk.markFindWayCueStarted(oldRevision, now());
      },
    );
    expect(
      walk.tick(now(), aheadOpen: true, turning: false, turnedDegrees: 0),
      isNull,
    );
    await tester.pump(WalkState.settle);
    expect(
      walk.tick(now(), aheadOpen: true, turning: false, turnedDegrees: 0),
      WalkCue.goStraight,
    );
    manager.say('Đi thẳng.', SpeechPriority.guidance, subject: 'path:straight');
    tts.finish();
    await tester.pump();
    expect(staleStatusStarted, isFalse);
    expect(tts.spoken, [findWayText, 'Cảnh báo khác.', 'Đi thẳng.']);

    expect(
      walk.onDanger(wall: false, sideOpen: false, canBypass: false),
      DangerAction.findWay,
    );
    final newRevision = walk.revision;
    expect(walk.markFindWayCueStarted(oldRevision, now()), isFalse);
    manager.sayNow(
      findWayText,
      SpeechPriority.danger,
      subject: 'path:findway',
      onStart: () => walk.markFindWayPromptStarted(newRevision, now()),
    );
    await tester.pump();
    expect(tts.spoken.last, findWayText);
    expect(
      walk.tick(now(), aheadOpen: false, turning: true, turnedDegrees: 0),
      isNull,
    );
    await manager.stopAll();
  });
}
