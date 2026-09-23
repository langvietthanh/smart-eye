import 'dart:async';
import 'package:flutter_tts/flutter_tts.dart';

class TTSService {
  // Biến dùng một lần (Singleton) để chắc chắn chỉ có 1 cái loa hoạt động
  static final TTSService _instance = TTSService._internal();
  factory TTSService() => _instance;
  TTSService._internal();

  final FlutterTts _flutterTts = FlutterTts();
  
  // Trạng thái kiểm soát Spam
  bool _isSpeaking = false;
  Timer? _spamTimer;

  // Thời gian khóa loa (Cooldown) - Cứ 5 giây mới cho nói 1 câu
  final Duration _cooldownDuration = const Duration(seconds: 5);

  /// Khởi tạo và cấu hình Giọng đọc Tiếng Việt
  Future<void> init() async {
    await _flutterTts.setLanguage("vi-VN"); // Tiếng Việt
    await _flutterTts.setSpeechRate(0.6);   // Tốc độ đọc vừa phải
    await _flutterTts.setVolume(1.0);       // Âm lượng tối đa
    await _flutterTts.setPitch(1.0);        // Tông giọng bình thường

    // Lắng nghe trạng thái: Khi loa đọc xong thì xả cờ
    _flutterTts.setCompletionHandler(() {
      _isSpeaking = false;
    });
  }

  /// Hàm gọi đọc cảnh báo (Đã bao gồm cơ chế chống Spam)
  Future<void> speakWarning(String text) async {
    // Nếu loa đang nói câu gì đó -> Bỏ qua câu mới (Đang bận)
    if (_isSpeaking) return;

    // Nếu vừa nói xong, Timer vẫn đang đếm -> Bỏ qua (Đang Cooldown)
    if (_spamTimer != null && _spamTimer!.isActive) return;

    // --- Bắt đầu nói ---
    _isSpeaking = true;
    await _flutterTts.speak(text);

    // Kích hoạt khóa chống Spam (Sau 5 giây Timer này mới chết)
    _spamTimer = Timer(_cooldownDuration, () {
      // Hết 5 giây, cho phép nói câu tiếp theo
    });
  }

  /// Dừng loa ngay lập tức (Dùng khi tắt app hoặc thoát màn hình)
  Future<void> stop() async {
    await _flutterTts.stop();
    _isSpeaking = false;
    _spamTimer?.cancel();
  }
}
