import 'dart:math';

/// Why the app cannot currently see the path. Silence must never be mistaken
/// for a clear path, so every one of these is announced.
enum SightProblem { noResults, tooDark, pointingDown, pointingUp, noDepth }

extension SightProblemText on SightProblem {
  String get message => switch (this) {
    SightProblem.noResults =>
      'Dừng lại! Camera không hoạt động, không thấy đường.',
    SightProblem.tooDark => 'Dừng lại! Quá tối, không nhìn rõ.',
    SightProblem.pointingDown =>
      'Dừng lại! Máy đang chĩa xuống sàn. Nâng máy lên.',
    SightProblem.pointingUp => 'Dừng lại! Máy đang chĩa lên cao. Hạ máy xuống.',
    SightProblem.noDepth => 'Không đo được khoảng cách. Đi chậm, dùng gậy.',
  };

  /// Blind states stop the user; aiming problems only ask to adjust.
  bool get isBlind =>
      this == SightProblem.noResults || this == SightProblem.tooDark;

  /// Whether the issue stops the user with danger priority and haptics.
  bool get stopsUser =>
      isBlind ||
      this == SightProblem.pointingDown ||
      this == SightProblem.pointingUp;
}

/// Trả về câu thông báo khi chuyển từ trạng thái lỗi [previous] về bình thường.
String? sightRecoveryText(SightProblem? previous) => switch (previous) {
  SightProblem.pointingDown || SightProblem.pointingUp =>
    'Đã đúng hướng. Đi tiếp.',
  SightProblem.noResults || SightProblem.tooDark => 'App đã nhìn thấy lại.',
  SightProblem.noDepth || null => null,
};

/// Pure state machine fed by AI results and the accelerometer. The screen
/// polls [check] on a timer so a stalled camera/detector is still noticed.
class SightMonitor {
  static const stallAfter = Duration(milliseconds: 1500);
  static const startGrace = Duration(seconds: 4);
  // Mean luma 0..255 with hysteresis; calibrate per device in field tests.
  static const darkEnter = 30.0;
  static const darkExit = 40.0;
  // Pitch of the camera axis below the horizon. A slight downward tilt is
  // wanted so floor obstacles stay in view.
  static const downEnter = 55.0;
  static const downExit = 45.0;
  static const upEnter = -20.0;
  static const upExit = -10.0;
  // LiDAR only: how long the depth sensor may be unreadable or silent.
  static const noDepthAfter = Duration(seconds: 1);

  DateTime? _deadline;
  bool _dark = false;
  double? _pitch;
  bool _down = false;
  bool _up = false;
  bool _depthEnabled = false;
  DateTime? _depthDeadline;

  /// Camera/AI (re)started: allow time for the first result.
  void start(DateTime now) {
    _deadline = now.add(startGrace);
    _depthDeadline = now.add(startGrace);
  }

  void stop() {
    _deadline = null;
    _depthDeadline = null;
  }

  /// A metric depth sensor is in use: its silence must be announced too.
  void enableDepth(bool enabled) => _depthEnabled = enabled;

  /// [known] is false when the reading had too little trustworthy depth.
  void onDepth(DateTime at, {required bool known}) {
    if (_depthDeadline == null || !known) return;
    _depthDeadline = at.add(noDepthAfter);
  }

  bool get active => _deadline != null;

  void onResult(DateTime at, double? meanLuma) {
    if (_deadline == null) return;
    _deadline = at.add(stallAfter);
    if (meanLuma != null) {
      _dark = meanLuma < (_dark ? darkExit : darkEnter);
    }
  }

  /// Raw accelerometer in m/s² (Android axes; sensors_plus maps iOS to them).
  void onAccelerometer(double x, double y, double z) {
    final pitch = pitchDegrees(x, y, z);
    // Smooth walking shake before applying thresholds.
    _pitch = _pitch == null ? pitch : _pitch! * 0.8 + pitch * 0.2;
    _down = _pitch! > (_down ? downExit : downEnter);
    _up = _pitch! < (_up ? upExit : upEnter);
  }

  /// Smoothed camera pitch below the horizon, degrees; null before the
  /// first accelerometer reading.
  double? get pitch => _pitch;

  SightProblem? check(DateTime now) {
    final deadline = _deadline;
    if (deadline == null) return null;
    if (now.isAfter(deadline)) return SightProblem.noResults;
    if (_dark) return SightProblem.tooDark;
    if (_down) return SightProblem.pointingDown;
    if (_up) return SightProblem.pointingUp;
    final depthDeadline = _depthDeadline;
    if (_depthEnabled && depthDeadline != null && now.isAfter(depthDeadline)) {
      return SightProblem.noDepth;
    }
    return null;
  }

  /// Degrees the rear camera points below the horizon: 0 upright, +90 at the
  /// floor (screen up), -90 at the ceiling. Works in portrait and landscape.
  static double pitchDegrees(double x, double y, double z) {
    final inPlane = sqrt(x * x + y * y);
    if (inPlane == 0 && z == 0) return 0;
    return atan2(z, inPlane) * 180 / pi;
  }
}
