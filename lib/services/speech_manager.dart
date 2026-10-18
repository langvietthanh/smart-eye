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

  _Request(
    this.text,
    this.priority,
    this.subject,
    this.onStart,
    this.createdAt,
  );

  /// Cảnh báo cũ quá 2 giây thì không còn đúng với thực tế → bỏ
  bool isStale(DateTime now) =>
      priority.index >= SpeechPriority.caution.index &&
      now.difference(createdAt) > const Duration(seconds: 2);
}

/// CN10 — Speech Manager: điều phối mọi câu nói theo nguyên tắc "nói ít, đúng lúc".
///
/// - Ưu tiên: cảnh báo nguy hiểm > chú ý > mô tả > nghe lại lịch sử
/// - Barge-in: câu ưu tiên cao hơn ngắt ngay câu đang nói
/// - Dedupe + hysteresis theo chủ thể: cùng 1 vật đã gửi tới TTS ở mức ≥ hiện tại
///   trong thời gian cooldown thì im lặng; chỉ nói lại khi mức nguy hiểm TĂNG.
///   (Chỉ tính khi gửi câu đi — câu bị bỏ lúc đang chờ không tiêu tốn cooldown.)
/// - Khoảng lặng tối thiểu giữa các câu không khẩn cấp để không che âm thanh môi trường
class SpeechManager {
  static final SpeechManager instance = SpeechManager._();
  SpeechManager._() : _tts = TTSService(), _now = DateTime.now;

  @visibleForTesting
  SpeechManager.forTesting({required this._tts, required this._now});

  static const Map<SpeechPriority, Duration> cooldown = {
    SpeechPriority.danger: Duration(seconds: 6),
    SpeechPriority.caution: Duration(seconds: 10),
    SpeechPriority.description: Duration(seconds: 3),
    SpeechPriority.playback: Duration.zero,
  };

  /// Khoảng lặng trước câu mô tả tiếp theo. Cảnh báo luôn được phát ngay.
  static const Duration _quietGap = Duration(seconds: 2);

  /// Câu vừa đọc xong còn hiện trên màn hình thêm bao lâu
  static const Duration _showAfterEnd = Duration(seconds: 3);

  final TTSService _tts;
  final DateTime Function() _now;
  final List<_Request> _queue = [];
  final Map<String, ({SpeechPriority priority, DateTime time})> _lastBySubject =
      {};
  _Request? _current;
  DateTime _lastEnd = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _hideTimer;
  Timer? _quietTimer;
  Future<void>? _stopping;

  /// Câu đang nói (hoặc vừa nói xong < 3 giây); null = không hiện gì
  final ValueNotifier<SpokenLine?> showing = ValueNotifier(null);

  /// Tắt tiếng mọi thứ trừ cảnh báo nguy hiểm
  bool muted = false;

  Future<void> init() => _tts.init();

  /// Máy có giọng đọc tiếng Việt không (kiểm tra lúc [init])
  bool get vietnameseAvailable => _tts.vietnameseAvailable;

  bool get isBusy => _current != null || _queue.isNotEmpty || _stopping != null;

  @visibleForTesting
  int get cooldownEntryCount => _lastBySubject.length;

  /// Câu này có được nhận không (không bị tắt tiếng, không trùng, chưa có câu cùng chủ thể đang chờ)
  bool canSay(SpeechPriority priority, {String? subject, bool force = false}) {
    final now = _now();
    _pruneCooldowns(now);
    if (muted && !force && priority != SpeechPriority.danger) return false;
    if (subject == null) return true;
    final current = _current;
    if (current != null &&
        current.subject == subject &&
        current.priority.index >= priority.index) {
      return false;
    }
    if (_isDuplicate(subject, priority, now)) return false;
    return !_queue.any(
      (r) => r.subject == subject && r.priority.index >= priority.index,
    );
  }

  /// Yêu cầu nói [text]. Trả về false nếu bị lọc (trùng lặp / đang tắt tiếng / đã đang chờ).
  /// [subject]: chủ thể để dedupe (VD 'track:12'); null = không dedupe.
  /// [force]: người dùng chủ động yêu cầu → nói kể cả khi đang yên lặng.
  /// [onStart]: gọi khi gửi câu tới TTS (VD để ghi lịch sử), không phải xác nhận
  /// loa đã phát âm; thời gian khởi động giọng nói phụ thuộc nền tảng.
  bool say(
    String text,
    SpeechPriority priority, {
    String? subject,
    bool force = false,
    VoidCallback? onStart,
  }) {
    return _enqueue(text, priority, subject, force, onStart) != null;
  }

  /// Nói và chờ nói xong. Trả về true nếu câu được đọc trọn vẹn (không bị lọc/ngắt/bỏ).
  Future<bool> sayAndWait(
    String text,
    SpeechPriority priority, {
    bool force = false,
  }) {
    final req = _enqueue(text, priority, null, force, null);
    return req?.result.future ?? Future.value(false);
  }

  _Request? _enqueue(
    String text,
    SpeechPriority priority,
    String? subject,
    bool force,
    VoidCallback? onStart,
  ) {
    if (!canSay(priority, subject: subject, force: force)) return null;
    final req = _Request(text, priority, subject, onStart, _now());

    final current = _current;
    if (current != null &&
        priority.index > current.priority.index &&
        priority.index >= SpeechPriority.caution.index) {
      // Barge-in: bỏ câu đang nói, nói ngay câu khẩn cấp hơn
      _drop(current);
      _current = null;
      unawaited(_stopSpeech());
    }

    // Mỗi mức cảnh báo chỉ giữ câu mới nhất đang chờ. Khi tăng mức nguy hiểm,
    // bỏ câu cảnh báo thấp hơn của cùng vật để không đọc lại chỉ dẫn đã cũ.
    if (priority.index >= SpeechPriority.caution.index) {
      _queue.removeWhere((r) {
        final superseded =
            r.priority == priority ||
            (subject != null &&
                r.subject == subject &&
                r.priority.index >= SpeechPriority.caution.index &&
                r.priority.index < priority.index);
        if (superseded) _drop(r);
        return superseded;
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

  void _pruneCooldowns(DateTime now) {
    _lastBySubject.removeWhere(
      (_, last) => now.difference(last.time) >= cooldown[last.priority]!,
    );
  }

  /// Không gửi câu mới trước khi nền tảng đã xử lý xong lệnh dừng câu cũ.
  /// Các lệnh dừng chồng nhau cùng đợi một Future để không dừng nhầm câu mới.
  Future<void> _stopSpeech() {
    final stopping = _stopping;
    if (stopping != null) return stopping;
    late final Future<void> pending;
    pending = Future<void>.sync(_tts.stop)
        .catchError((Object error) {
          debugPrint('Không dừng được TTS: $error');
        })
        .whenComplete(() {
          _stopping = null;
          _pump();
        });
    _stopping = pending;
    return pending;
  }

  void _pump() {
    _quietTimer?.cancel();
    _quietTimer = null;
    if (_stopping != null || _current != null || _queue.isEmpty) return;
    final now = _now();

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

    // Chỉ mô tả cần khoảng lặng; cảnh báo không được chậm 2 giây vì câu trước.
    if (next.priority == SpeechPriority.description) {
      final wait = _quietGap - now.difference(_lastEnd);
      if (wait > Duration.zero) {
        _quietTimer = Timer(wait, _pump);
        return;
      }
    }

    _queue.removeAt(0);
    _speak(next);
  }

  Future<void> _speak(_Request req) async {
    _current = req;
    final now = _now();
    _pruneCooldowns(now);
    if (req.subject != null) {
      _lastBySubject[req.subject!] = (priority: req.priority, time: now);
    }
    _hideTimer?.cancel();
    showing.value = (text: req.text, priority: req.priority);
    req.onStart?.call();

    await _tts.speak(req.text);
    if (_current != req) return; // Đã bị barge-in ngắt
    _current = null;
    _lastEnd = _now();
    if (!req.result.isCompleted) req.result.complete(true);
    _hideTimer = Timer(_showAfterEnd, () {
      if (_current == null) showing.value = null;
    });
    _pump();
  }

  void _drop(_Request r) {
    if (!r.result.isCompleted) r.result.complete(false);
  }

  /// Bỏ cảnh báo đang chờ khi cảnh đã đổi, giữ lại cảnh báo của [subject] và
  /// [priority]/[text] nếu có. Mức cảnh báo hoặc vị trí đổi cũng phải bỏ câu cũ.
  /// Không truyền [subject] để bỏ toàn bộ cảnh báo đang chờ. Câu đang đọc và
  /// các yêu cầu mô tả/nghe lại do người dùng chủ động vẫn được giữ nguyên.
  void retainAlerts({String? subject, SpeechPriority? priority, String? text}) {
    _queue.removeWhere((request) {
      final obsolete =
          request.priority.index >= SpeechPriority.caution.index &&
          (subject == null ||
              request.subject != subject ||
              (priority != null && request.priority != priority) ||
              (text != null && request.text != text));
      if (obsolete) _drop(request);
      return obsolete;
    });
    _pump();
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
    _quietTimer?.cancel();
    _quietTimer = null;
    showing.value = null;
    await _stopSpeech();
  }

  /// Quên lịch sử dedupe (VD khi bắt đầu chuyến đi mới)
  void resetDedupe() => _lastBySubject.clear();
}
