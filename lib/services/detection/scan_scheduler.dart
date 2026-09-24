import 'frame_data.dart';

/// Chế độ nhịp quét
enum ScanMode {
  /// Vừa có cảnh báo / vật đang tới gần → quét nhanh nhất có thể, luôn quét toàn khung
  alert,

  /// Đi lại bình thường → ~5 lần/giây, xen kẽ toàn khung và vùng hành lang phía trước
  normal,

  /// Cảnh đứng yên, không có vật liên quan → 1 lần/giây để tiết kiệm pin, đỡ nóng máy
  idle,
}

extension ScanModeText on ScanMode {
  String get vi => switch (this) {
        ScanMode.alert => 'Cảnh báo',
        ScanMode.normal => 'Thường',
        ScanMode.idle => 'Tiết kiệm',
      };
}

/// Quyết định KHI NÀO quét và quét VÙNG NÀO — thay cho việc quét mọi frame camera (30 fps).
///
/// Đi bộ ~1,4 m/s: quét 5 lần/giây → mỗi lần cách nhau ~0,3 m, đủ an toàn; quét nhanh hơn chỉ tốn pin.
/// Vùng "hành lang" (vuông, giữa khung, phía trước) được phóng to khi đưa vào model → vật ở xa
/// trên lối đi (cột điện, biển báo cách 5–10 m) to gấp ~1,7 lần (ngang) và ~2,5 lần (dọc, khung dọc 480×720)
/// so với quét toàn khung → phát hiện sớm hơn.
class ScanScheduler {
  static const Duration normalInterval = Duration(milliseconds: 200);

  /// Có nguy hiểm vẫn nghỉ tối thiểu 100 ms giữa 2 lần quét (≤ 10 lần/giây) — GPU còn thời gian vẽ
  /// màn hình (GPU máy tầm trung vừa chạy AI liên tục vừa vẽ camera dễ làm hình giật / nhấp nháy)
  static const Duration alertInterval = Duration(milliseconds: 100);
  static const Duration idleInterval = Duration(milliseconds: 1000);

  /// Giữ chế độ cảnh báo thêm bao lâu sau lần cuối có nguy hiểm (hysteresis)
  static const Duration alertHold = Duration(seconds: 2);

  /// Cảnh đứng yên liên tục bao lâu thì chuyển sang tiết kiệm
  static const Duration idleAfter = Duration(seconds: 3);

  /// Ngưỡng thay đổi cảnh (0..1) coi như đứng yên
  static const double stillThreshold = 0.02;

  bool corridorEnabled;

  ScanScheduler({this.corridorEnabled = true});

  DateTime _lastDispatch = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastHazard = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _stillSince;
  bool _lastWasCorridor = true; // → lần đầu quét toàn khung
  bool _inFlight = false;

  ScanMode _mode = ScanMode.normal;
  ScanMode get mode => _mode;

  /// Đang chờ kết quả lần quét trước
  bool get inFlight => _inFlight;

  Duration get interval => switch (_mode) {
        ScanMode.alert => alertInterval,
        ScanMode.normal => normalInterval,
        ScanMode.idle => idleInterval,
      };

  /// Frame camera vừa tới: có nên quét không. Nếu có, trả về vùng cần quét và đánh dấu đang bận.
  CropRect? nextScan(DateTime now, {required int frameWidth, required int frameHeight}) {
    if (_inFlight || now.difference(_lastDispatch) < interval) return null;
    _inFlight = true;
    _lastDispatch = now;

    final useCorridor = corridorEnabled && _mode == ScanMode.normal && !_lastWasCorridor;
    _lastWasCorridor = useCorridor;
    return useCorridor ? CropRect.corridor(frameWidth: frameWidth, frameHeight: frameHeight) : CropRect.full;
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
    _lastWasCorridor = true;
    _mode = ScanMode.normal;
    _lastDispatch = DateTime.fromMillisecondsSinceEpoch(0);
  }
}
