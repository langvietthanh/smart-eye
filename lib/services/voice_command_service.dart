import 'dart:async';

import 'package:speech_to_text/speech_to_text.dart';

enum VoiceError { noPermission, unavailable, network, noSpeech }

class VoiceResult {
  final String? text;
  final VoiceError? error;
  const VoiceResult({this.text, this.error});
}

/// Seam over the OS speech recognizer so the service is testable.
abstract interface class SpeechRecognizer {
  /// [onDone] fires when the recognizer has finished a session (all results
  /// delivered or listening ended).
  Future<bool> initialize(
    void Function(String errorMsg) onError, {
    void Function()? onDone,
  });
  Future<void> listen(
    String localeId,
    Duration pauseFor,
    Duration listenFor,
    void Function(String words, bool isFinal) onResult,
  );
  Future<void> stop();
}

class _SttRecognizer implements SpeechRecognizer {
  final SpeechToText _stt = SpeechToText();

  @override
  Future<bool> initialize(
    void Function(String errorMsg) onError, {
    void Function()? onDone,
  }) {
    return _stt.initialize(
      onError: (e) => onError(e.errorMsg),
      onStatus: (s) {
        if (s == SpeechToText.doneStatus) onDone?.call();
      },
    );
  }

  @override
  Future<void> listen(
    String localeId,
    Duration pauseFor,
    Duration listenFor,
    void Function(String words, bool isFinal) onResult,
  ) {
    return _stt.listen(
      onResult: (r) => onResult(r.recognizedWords, r.finalResult),
      listenOptions: SpeechListenOptions(
        listenFor: listenFor,
        pauseFor: pauseFor,
        partialResults: true,
        localeId: localeId,
      ),
    );
  }

  @override
  Future<void> stop() => _stt.stop();
}

class VoiceCommandService {
  static const String localeId = 'vi_VN';
  static const Duration pauseFor = Duration(milliseconds: 1500);
  static const Duration listenFor = Duration(seconds: 6);

  final SpeechRecognizer _recognizer;
  bool _initialized = false;
  Completer<VoiceResult>? _pending;

  VoiceCommandService([SpeechRecognizer? recognizer])
    : _recognizer = recognizer ?? _SttRecognizer();

  bool get isListening => _pending != null;

  Future<VoiceResult> listen() {
    final existing = _pending;
    if (existing != null) return existing.future;
    final c = Completer<VoiceResult>();
    _pending = c;
    _start(c);
    return c.future;
  }

  Future<void> _start(Completer<VoiceResult> c) async {
    try {
      if (!_initialized) {
        _initialized = await _recognizer.initialize(
          (msg) => _completePending(VoiceResult(error: mapError(msg))),
          onDone: () =>
              _completePending(const VoiceResult(error: VoiceError.noSpeech)),
        );
      }
      if (c.isCompleted) return;
      if (!_initialized) {
        _complete(c, const VoiceResult(error: VoiceError.unavailable));
        return;
      }
      await _recognizer.listen(localeId, pauseFor, listenFor, (words, isFinal) {
        if (!isFinal) return;
        final t = words.trim();
        _complete(
          c,
          t.isEmpty
              ? const VoiceResult(error: VoiceError.noSpeech)
              : VoiceResult(text: t),
        );
      });
    } catch (_) {
      _complete(c, const VoiceResult(error: VoiceError.unavailable));
    }
  }

  void _completePending(VoiceResult r) {
    final c = _pending;
    if (c != null) _complete(c, r);
  }

  void _complete(Completer<VoiceResult> c, VoiceResult r) {
    if (c.isCompleted) return;
    if (identical(_pending, c)) _pending = null;
    c.complete(r);
  }

  Future<void> cancel() async {
    final c = _pending;
    if (c == null) return;
    try {
      await _recognizer.stop();
    } catch (_) {}
    _complete(c, const VoiceResult(error: VoiceError.noSpeech));
  }

  static VoiceError mapError(String errorMsg) {
    if (errorMsg.contains('network')) return VoiceError.network;
    if (errorMsg.contains('permission')) return VoiceError.noPermission;
    return VoiceError.noSpeech;
  }
}
