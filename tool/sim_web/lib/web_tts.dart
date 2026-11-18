import 'dart:async';
import 'dart:js_interop';

import 'package:smart_eye/services/tts_service.dart';

@JS('speechSynthesis')
external _Synth get _synth;

extension type _Synth._(JSObject _) implements JSObject {
  external void speak(_Utterance u);
  external void cancel();
}

@JS('SpeechSynthesisUtterance')
extension type _Utterance._(JSObject _) implements JSObject {
  external factory _Utterance(String text);
  external set lang(String v);
  external set rate(double v);
  external set onend(JSFunction? f);
  external set onerror(JSFunction? f);
}

/// The browser's own voice (Web Speech API) in place of flutter_tts, with
/// the same contract: [speak] completes when the line ends or is stopped.
class WebTts implements TTSService {
  Completer<void>? _done;
  Timer? _watchdog;

  /// Off: lines are still shown and followed, just not voiced.
  bool voiced = true;

  @override
  bool vietnameseAvailable = true;

  @override
  bool get isSpeaking => _done != null;

  @override
  Future<void> init() async {}

  @override
  Future<void> speak(String text) {
    _finish();
    final done = Completer<void>();
    _done = done;
    // Like TTSService: never wait forever for an end event.
    final estimate = Duration(milliseconds: 700 + text.length * 75);
    _watchdog = Timer(voiced ? estimate * 3 : estimate, _finish);
    if (voiced) {
      try {
        final u = _Utterance(text)
          ..lang = 'vi-VN'
          ..rate = 1.0
          ..onend = (() => _finish()).toJS
          ..onerror = (() => _finish()).toJS;
        _synth.speak(u);
      } catch (_) {
        // No speech in this browser: keep the timing, show the text.
      }
    }
    return done.future;
  }

  @override
  Future<void> stop() async {
    _finish();
    try {
      _synth.cancel();
    } catch (_) {}
  }

  void _finish() {
    _watchdog?.cancel();
    _watchdog = null;
    final done = _done;
    _done = null;
    if (done != null && !done.isCompleted) done.complete();
  }
}
