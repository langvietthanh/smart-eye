/// Chế độ nhịp quét
enum ScanMode {
  /// Vừa có cảnh báo / vật đang tới gần → quét liên tục
  alert,

  /// Đi lại bình thường → quét liên tục (máy rảnh là quét: GPU ~11 lần/giây)
  normal,

  /// Cảnh đứng yên, không có vật liên quan → 1 lần/giây cho đỡ tốn pin, NHƯNG luồng camera vẫn so độ sáng
  /// từng frame — có chuyển động là quét ngay (xem [ScanScheduler.wakeUp])
  idle,
}

extension ScanModeText on ScanMode {
  String get vi => switch (this) {
        ScanMode.alert => 'Cảnh báo',
        ScanMode.normal => 'Thường',
        ScanMode.idle => 'Tiết kiệm',
      };
}

/// Quyết định KHI NÀO quét.
///
/// Với tình huống nguy hiểm, độ trễ quan trọng hơn pin: máy rảnh là quét ngay (chỉ nghỉ [minGap] cho
/// GPU còn thời gian vẽ màn hình). Chỉ khi cảnh đứng yên hẳn mới giãn ra 1 lần/giây — và luồng camera
/// vẫn theo dõi chuyển động từng frame để "đánh thức" ngay khi có gì thay đổi.
class ScanScheduler {
  /// Nghỉ tối thiểu giữa 2 lần quét — đủ để GPU vẽ 1–2 khung hình camera
  static const Duration minGap = Duration(milliseconds: 30);
  static const Duration idleInterval = Duration(milliseconds: 1000);

  /// Giữ chế độ cảnh báo thêm bao lâu sau lần cuối có nguy hiểm (hysteresis)
  static const Duration alertHold = Duration(seconds: 2);

  /// Cảnh đứng yên liên tục bao lâu thì chuyển sang tiết kiệm
  static const Duration idleAfter = Duration(seconds: 3);

  /// Ngưỡng thay đổi cảnh (0..1) coi như đứng yên
  static const double stillThreshold = 0.02;

  DateTime _lastDispatch = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastHazard = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _stillSince;
  bool _inFlight = false;

  ScanMode _mode = ScanMode.normal;
  ScanMode get mode => _mode;

  /// Đang chờ kết quả lần quét trước
  bool get inFlight => _inFlight;

  Duration get interval => switch (_mode) {
        ScanMode.alert || ScanMode.normal => minGap,
        ScanMode.idle => idleInterval,
      };

  /// Frame camera vừa tới: có nên quét không. Nếu có thì đánh dấu đang bận.
  bool shouldScan(DateTime now) {
    if (_inFlight || now.difference(_lastDispatch) < interval) return false;
    _inFlight = true;
    _lastDispatch = now;
    return true;
  }

  /// Báo kết quả lần quét để cập nhật chế độ.
  /// [hazard]: có cảnh báo hoặc vật đang tới gần; [relevantObjects]: có vật liên quan trong cảnh.
  void onResult(DateTime now, {required double motion, required bool hazard, required bool relevantObjects}) {
    _inFlight = false;
    if (hazard) _lastHazard = now;

    if (motion < stillThreshold && !relevantObjects) {
      _stillSince ??= now;
    } else {
      _stillSince = null;
    }

    if (now.difference(_lastHazard) < alertHold) {
      _mode = ScanMode.alert;
    } else if (_stillSince != null && now.difference(_stillSince!) >= idleAfter) {
      _mode = ScanMode.idle;
    } else {
      _mode = ScanMode.normal;
    }
  }

  /// Lần quét lỗi / bị huỷ → cho phép quét lại ngay
  void onFailed() => _inFlight = false;

  /// Người dùng vừa hỏi / thao tác → quét ngay frame kế tiếp, thoát chế độ tiết kiệm
  void wakeUp() {
    _lastDispatch = DateTime.fromMillisecondsSinceEpoch(0);
    _stillSince = null;
    if (_mode == ScanMode.idle) _mode = ScanMode.normal;
  }

  void reset() {
    _inFlight = false;
    _stillSince = null;
    _mode = ScanMode.normal;
    _lastDispatch = DateTime.fromMillisecondsSinceEpoch(0);
  }
}
