import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// CN9 — Lớp bọc mỏng quanh flutter_tts (giọng tiếng Việt on-device).
/// Không tự chống spam — việc điều phối thuộc về [SpeechManager].
class TTSService {
  // Biến dùng một lần (Singleton) để chắc chắn chỉ có 1 cái loa hoạt động
  static final TTSService _instance = TTSService._internal();
  factory TTSService() => _instance;
  TTSService._internal();

  final FlutterTts _flutterTts = FlutterTts();
  Completer<void>? _done;
  Timer? _watchdog;
  bool _initialized = false;

  // Sự kiện cancel của câu cũ có thể tới SAU khi câu mới đã gửi đi →
  // chỉ tin completion/cancel khi câu hiện tại đã thực sự bắt đầu đọc.
  bool _started = false;

  /// Máy có giọng đọc tiếng Việt không — false thì UI phải nhắc người dùng cài thêm
  bool vietnameseAvailable = true;

  /// Khởi tạo và cấu hình Giọng đọc Tiếng Việt
  Future<void> init() async {
    if (_initialized) return;

    if (Platform.isIOS) {
      // Mặc định iOS tắt tiếng TTS khi gạt nút im lặng → cảnh báo nguy hiểm sẽ câm.
      // playback: luôn phát; duckOthers: nhạc/podcast đang phát tự nhỏ lại khi có cảnh báo.
      await _flutterTts.setSharedInstance(true);
      await _flutterTts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        [
          IosTextToSpeechAudioCategoryOptions.duckOthers,
          IosTextToSpeechAudioCategoryOptions.interruptSpokenAudioAndMixWithOthers,
        ],
        IosTextToSpeechAudioMode.voicePrompt,
      );
    }

    try {
      vietnameseAvailable = await _flutterTts.isLanguageAvailable("vi-VN") == true;
    } catch (e) {
      debugPrint('Không kiểm tra được giọng tiếng Việt: $e');
    }
    await _flutterTts.setLanguage("vi-VN"); // Tiếng Việt
    // Thang tốc độ khác nhau: iOS 0.5 = bình thường, Android 1.0 = bình thường
    await _flutterTts.setSpeechRate(Platform.isIOS ? 0.5 : 0.6);
    await _flutterTts.setVolume(1.0);       // Âm lượng tối đa
    await _flutterTts.setPitch(1.0);        // Tông giọng bình thường

    // Khi loa đọc xong / bị ngắt / lỗi → báo cho người đang chờ
    _flutterTts.setStartHandler(() => _started = true);
    _flutterTts.setCompletionHandler(() {
      if (_started) _finish();
    });
    _flutterTts.setCancelHandler(() {
      if (_started) _finish();
    });
    _flutterTts.setErrorHandler((msg) {
      debugPrint('TTS lỗi: $msg');
      _finish();
    });
    _initialized = true;
  }

  bool get isSpeaking => _done != null;

  /// Đọc [text], Future hoàn thành khi đọc xong hoặc bị [stop] ngắt.
  Future<void> speak(String text) async {
    _finish(); // Câu cũ (nếu còn) coi như đã kết thúc
    final done = Completer<void>();
    _done = done;
    _started = false;
    // Phòng hờ nền tảng không gọi completion handler
    _watchdog = Timer(Duration(milliseconds: 3000 + text.length * 120), _finish);
    try {
      await _flutterTts.speak(text);
    } catch (e) {
      // Lỗi nền tảng không được làm kẹt Speech Manager (câu sau sẽ không bao giờ được đọc)
      debugPrint('TTS speak lỗi: $e');
      _finish();
    }
    return done.future;
  }

  /// Dừng loa ngay lập tức (barge-in, tắt app, thoát màn hình)
  Future<void> stop() async {
    _finish();
    await _flutterTts.stop();
  }

  void _finish() {
    _watchdog?.cancel();
    _watchdog = null;
    final done = _done;
    _done = null;
    if (done != null && !done.isCompleted) done.complete();
  }
}
