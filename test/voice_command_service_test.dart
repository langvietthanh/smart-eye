import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/services/voice_command_service.dart';

class FakeRecognizer implements SpeechRecognizer {
  bool initResult = true;
  bool permission = true;
  int initCalls = 0;
  int listenCalls = 0;
  int stopCalls = 0;
  String? localeId;
  Duration? pauseFor;
  Duration? listenFor;
  void Function(String)? onError;
  void Function()? onDone;
  void Function(String, bool)? onResult;

  @override
  Future<bool> initialize(
    void Function(String errorMsg) onError, {
    void Function()? onDone,
  }) async {
    initCalls++;
    this.onError = onError;
    this.onDone = onDone;
    return initResult;
  }

  @override
  Future<void> listen(
    String localeId,
    Duration pauseFor,
    Duration listenFor,
    void Function(String words, bool isFinal) onResult,
  ) async {
    listenCalls++;
    this.localeId = localeId;
    this.pauseFor = pauseFor;
    this.listenFor = listenFor;
    this.onResult = onResult;
  }

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<bool> hasPermission() async => permission;
}

void main() {
  test('mapError maps plugin error codes', () {
    expect(VoiceCommandService.mapError('error_network'), VoiceError.network);
    expect(
      VoiceCommandService.mapError('error_network_timeout'),
      VoiceError.network,
    );
    expect(
      VoiceCommandService.mapError('error_permission'),
      VoiceError.noPermission,
    );
    expect(
      VoiceCommandService.mapError('error_insufficient_permissions'),
      VoiceError.noPermission,
    );
    expect(VoiceCommandService.mapError('error_no_match'), VoiceError.noSpeech);
    expect(
      VoiceCommandService.mapError('error_speech_timeout'),
      VoiceError.noSpeech,
    );
    expect(VoiceCommandService.mapError('anything_else'), VoiceError.noSpeech);
  });

  test('mapError: language not supported/unavailable gives unavailable', () {
    expect(
      VoiceCommandService.mapError('error_language_not_supported'),
      VoiceError.unavailable,
    );
    expect(
      VoiceCommandService.mapError('error_language_unavailable'),
      VoiceError.unavailable,
    );
  });

  test('initialize false without mic permission gives noPermission', () async {
    final fake = FakeRecognizer()
      ..initResult = false
      ..permission = false;
    final r = await VoiceCommandService(fake).listen();
    expect(r.error, VoiceError.noPermission);
    expect(fake.listenCalls, 0);
  });

  test('initialize false with mic permission gives unavailable', () async {
    final fake = FakeRecognizer()
      ..initResult = false
      ..permission = true;
    final r = await VoiceCommandService(fake).listen();
    expect(r.error, VoiceError.unavailable);
  });

  test('final result returns text with Vietnamese settings', () async {
    final fake = FakeRecognizer();
    final s = VoiceCommandService(fake);
    final f = s.listen();
    await Future<void>.delayed(Duration.zero);
    expect(s.isListening, isTrue);
    expect(fake.localeId, 'vi_VN');
    expect(fake.pauseFor, const Duration(milliseconds: 1500));
    expect(fake.listenFor, const Duration(seconds: 6));
    fake.onResult!('đi đến', false);
    fake.onResult!('đi đến ghế', true);
    final r = await f;
    expect(r.text, 'đi đến ghế');
    expect(r.error, isNull);
    expect(s.isListening, isFalse);
  });

  test('initialize false gives unavailable', () async {
    final fake = FakeRecognizer()..initResult = false;
    final r = await VoiceCommandService(fake).listen();
    expect(r.error, VoiceError.unavailable);
    expect(r.text, isNull);
    expect(fake.listenCalls, 0);
  });

  test('onError maps, first error wins', () async {
    final fake = FakeRecognizer();
    final s = VoiceCommandService(fake);
    final f = s.listen();
    await Future<void>.delayed(Duration.zero);
    fake.onError!('error_network');
    fake.onError!('error_permission');
    expect((await f).error, VoiceError.network);
  });

  test('done without final result gives noSpeech', () async {
    final fake = FakeRecognizer();
    final s = VoiceCommandService(fake);
    final f = s.listen();
    await Future<void>.delayed(Duration.zero);
    fake.onResult!('đi', false);
    fake.onDone!();
    expect((await f).error, VoiceError.noSpeech);
  });

  test('empty final result gives noSpeech', () async {
    final fake = FakeRecognizer();
    final s = VoiceCommandService(fake);
    final f = s.listen();
    await Future<void>.delayed(Duration.zero);
    fake.onResult!('  ', true);
    expect((await f).error, VoiceError.noSpeech);
  });

  test('second listen while listening returns identical future', () async {
    final fake = FakeRecognizer();
    final s = VoiceCommandService(fake);
    final f1 = s.listen();
    final f2 = s.listen();
    expect(identical(f1, f2), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(fake.listenCalls, 1);
    fake.onResult!('ghế', true);
    await f1;
  });

  test('cancel stops recognizer and completes noSpeech', () async {
    final fake = FakeRecognizer();
    final s = VoiceCommandService(fake);
    final f = s.listen();
    await Future<void>.delayed(Duration.zero);
    await s.cancel();
    expect(fake.stopCalls, 1);
    expect((await f).error, VoiceError.noSpeech);
    expect(s.isListening, isFalse);
  });

  test('initialize only once across listens', () async {
    final fake = FakeRecognizer();
    final s = VoiceCommandService(fake);
    var f = s.listen();
    await Future<void>.delayed(Duration.zero);
    fake.onResult!('a', true);
    await f;
    f = s.listen();
    await Future<void>.delayed(Duration.zero);
    fake.onResult!('b', true);
    expect((await f).text, 'b');
    expect(fake.initCalls, 1);
    expect(fake.listenCalls, 2);
  });

  test('error and done callbacks work on later listens', () async {
    final fake = FakeRecognizer();
    final s = VoiceCommandService(fake);
    var f = s.listen();
    await Future<void>.delayed(Duration.zero);
    fake.onResult!('a', true);
    await f;
    expect(s.isListening, isFalse);

    f = s.listen();
    await Future<void>.delayed(Duration.zero);
    fake.onError!('error_network');
    expect((await f).error, VoiceError.network);
    expect(s.isListening, isFalse);

    f = s.listen();
    await Future<void>.delayed(Duration.zero);
    fake.onDone!();
    expect((await f).error, VoiceError.noSpeech);
    expect(s.isListening, isFalse);
  });

  test('failed initialize is retried on next listen', () async {
    final fake = FakeRecognizer()..initResult = false;
    final s = VoiceCommandService(fake);
    expect((await s.listen()).error, VoiceError.unavailable);
    expect(s.isListening, isFalse);

    fake.initResult = true;
    final f = s.listen();
    await Future<void>.delayed(Duration.zero);
    fake.onResult!('đi đến ghế', true);
    expect((await f).text, 'đi đến ghế');
    expect(fake.initCalls, 2);
  });
}
