import 'dart:async';

import 'package:flutter/foundation.dart';

import 'tts_service.dart';

/// Độ ưu tiên câu nói — giá trị lớn hơn được nói trước và được phép ngắt lời (barge-in)
enum SpeechPriority { playback, description, caution, danger }

/// Câu đang/vừa nói — hiển thị trên màn hình cho người nhìn kém / demo
typedef SpokenLine = ({String text, SpeechPriority priority});

class _Request {
  final String text;
  final SpeechPriority priority;
  final String? subject;
  final VoidCallback? onStart;
  final DateTime createdAt;
  final Completer<bool> result = Completer<bool>();

  _Request(this.text, this.priority, this.subject, this.onStart) : createdAt = DateTime.now();

  /// Cảnh báo cũ quá 2 giây thì không còn đúng với thực tế → bỏ
  bool isStale(DateTime now) =>
      priority.index >= SpeechPriority.caution.index &&
      now.difference(createdAt) > const Duration(seconds: 2);
}

/// CN10 — Speech Manager: điều phối mọi câu nói theo nguyên tắc "nói ít, đúng lúc".
///
/// - Ưu tiên: cảnh báo nguy hiểm > chú ý > mô tả > nghe lại lịch sử
/// - Barge-in: câu ưu tiên cao hơn ngắt ngay câu đang nói
/// - Dedupe + hysteresis theo chủ thể: cùng 1 vật đã được ĐỌC ở mức ≥ hiện tại
///   trong thời gian cooldown thì im lặng; chỉ nói lại khi mức nguy hiểm TĂNG.
///   (Chỉ tính khi thực sự đọc — câu bị bỏ vì chờ quá lâu thì lần sau vẫn được nói.)
/// - Khoảng lặng tối thiểu giữa các câu không khẩn cấp để không che âm thanh môi trường
class SpeechManager {
  static final SpeechManager instance = SpeechManager._();
  SpeechManager._();

  static const Map<SpeechPriority, Duration> cooldown = {
    SpeechPriority.danger: Duration(seconds: 6),
    SpeechPriority.caution: Duration(seconds: 10),
    SpeechPriority.description: Duration(seconds: 3),
    SpeechPriority.playback: Duration.zero,
  };

  /// Khoảng lặng tối thiểu sau 1 câu trước khi được nói câu "chú ý" tiếp theo
  static const Duration _quietGap = Duration(seconds: 2);

  /// Câu vừa đọc xong còn hiện trên màn hình thêm bao lâu
  static const Duration _showAfterEnd = Duration(seconds: 3);

  final TTSService _tts = TTSService();
  final List<_Request> _queue = [];
  final Map<String, ({SpeechPriority priority, DateTime time})> _lastBySubject = {};
  _Request? _current;
  DateTime _lastEnd = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _hideTimer;

  /// Câu đang nói (hoặc vừa nói xong < 3 giây); null = không hiện gì
  final ValueNotifier<SpokenLine?> showing = ValueNotifier(null);

  /// Tắt tiếng mọi thứ trừ cảnh báo nguy hiểm
  bool muted = false;

  Future<void> init() => _tts.init();

  /// Máy có giọng đọc tiếng Việt không (kiểm tra lúc [init])
  bool get vietnameseAvailable => _tts.vietnameseAvailable;

  bool get isBusy => _current != null || _queue.isNotEmpty;

  /// Câu này có được nhận không (không bị tắt tiếng, không trùng, chưa có câu cùng chủ thể đang chờ)
  bool canSay(SpeechPriority priority, {String? subject, bool force = false}) {
    if (muted && !force && priority != SpeechPriority.danger) return false;
    if (subject == null) return true;
    if (_isDuplicate(subject, priority, DateTime.now())) return false;
    return !_queue.any((r) => r.subject == subject && r.priority == priority);
  }

  /// Yêu cầu nói [text]. Trả về false nếu bị lọc (trùng lặp / đang tắt tiếng / đã đang chờ).
  /// [subject]: chủ thể để dedupe (VD 'track:12'); null = không dedupe.
  /// [force]: người dùng chủ động yêu cầu → nói kể cả khi đang yên lặng.
  /// [onStart]: gọi khi câu THỰC SỰ bắt đầu được đọc (VD để ghi lịch sử).
  bool say(String text, SpeechPriority priority, {String? subject, bool force = false, VoidCallback? onStart}) {
    return _enqueue(text, priority, subject, force, onStart) != null;
  }

  /// Nói và chờ nói xong. Trả về true nếu câu được đọc trọn vẹn (không bị lọc/ngắt/bỏ).
  Future<bool> sayAndWait(String text, SpeechPriority priority, {bool force = false}) {
    final req = _enqueue(text, priority, null, force, null);
    return req?.result.future ?? Future.value(false);
  }

  _Request? _enqueue(String text, SpeechPriority priority, String? subject, bool force, VoidCallback? onStart) {
    if (!canSay(priority, subject: subject, force: force)) return null;
    final req = _Request(text, priority, subject, onStart);

    final current = _current;
    if (current != null && priority.index > current.priority.index &&
        priority.index >= SpeechPriority.caution.index) {
      // Barge-in: bỏ câu đang nói, nói ngay câu khẩn cấp hơn
      _drop(current);
      _current = null;
      _tts.stop();
    }

    // Mỗi mức cảnh báo chỉ giữ câu mới nhất đang chờ
    if (priority.index >= SpeechPriority.caution.index) {
      _queue.where((r) => r.priority == priority).toList().forEach((r) {
        _queue.remove(r);
        _drop(r);
      });
    }
    _queue.add(req);
    _pump();
    return req;
  }

  bool _isDuplicate(String subject, SpeechPriority priority, DateTime now) {
    final last = _lastBySubject[subject];
    if (last == null) return false;
    // Mức nguy hiểm tăng → luôn nói; bằng hoặc giảm → chỉ nói lại khi hết cooldown của mức cũ
    if (priority.index > last.priority.index) return false;
    return now.difference(last.time) < cooldown[last.priority]!;
  }

  void _pump() {
    if (_current != null || _queue.isEmpty) return;
    final now = DateTime.now();

    _queue.where((r) => r.isStale(now)).toList().forEach((r) {
      _queue.remove(r);
      _drop(r);
    });
    if (_queue.isEmpty) return;

    // Chọn câu ưu tiên cao nhất, cùng mức thì câu đến trước
    _queue.sort((a, b) {
      final p = b.priority.index.compareTo(a.priority.index);
      return p != 0 ? p : a.createdAt.compareTo(b.createdAt);
    });
    final next = _queue.first;

    // Câu không khẩn cấp phải chờ 1 khoảng lặng để người dùng còn nghe môi trường
    if (next.priority != SpeechPriority.danger && next.priority != SpeechPriority.playback) {
      final wait = _quietGap - now.difference(_lastEnd);
      if (wait > Duration.zero) {
        Timer(wait, _pump);
        return;
      }
    }

    _queue.removeAt(0);
    _speak(next);
  }

  Future<void> _speak(_Request req) async {
    _current = req;
    if (req.subject != null) {
      _lastBySubject[req.subject!] = (priority: req.priority, time: DateTime.now());
    }
    _hideTimer?.cancel();
    showing.value = (text: req.text, priority: req.priority);
    req.onStart?.call();

    await _tts.speak(req.text);
    if (_current != req) return; // Đã bị barge-in ngắt
    _current = null;
    _lastEnd = DateTime.now();
    if (!req.result.isCompleted) req.result.complete(true);
    _hideTimer = Timer(_showAfterEnd, () {
      if (_current == null) showing.value = null;
    });
    _pump();
  }

  void _drop(_Request r) {
    if (!r.result.isCompleted) r.result.complete(false);
  }

  /// Dừng hết: xoá hàng đợi + ngắt câu đang nói
  Future<void> stopAll() async {
    for (final r in _queue) {
      _drop(r);
    }
    _queue.clear();
    final current = _current;
    _current = null;
    if (current != null) _drop(current);
    _hideTimer?.cancel();
    showing.value = null;
    await _tts.stop();
  }

  /// Quên lịch sử dedupe (VD khi bắt đầu chuyến đi mới)
  void resetDedupe() => _lastBySubject.clear();
}
