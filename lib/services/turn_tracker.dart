import 'dart:math';

/// Tracks rotation about the vertical (gravity-aligned) axis using gyroscope
/// and accelerometer data. Pure Dart with no direct platform dependencies.
class TurnTracker {
  static const stepDegrees = 50.0; // one "Xoay tiếp." per step
  static const turningRate = 15.0; // deg/s
  static const turningWindow = Duration(seconds: 1);

  double _gx = 0.0, _gy = 1.0, _gz = 0.0;
  double _net = 0.0; // signed: swaying back and forth cancels out
  DateTime? _lastAt;
  final List<({DateTime at, double rate})> _recent = [];

  /// Net rotation about the vertical axis since the last reset, in degrees.
  /// Not the absolute sum: a hand swaying while the user stands still made
  /// "Xoay tiếp." come nonstop (iPhone test).
  double get degrees => _net.abs();

  /// Updates current gravity vector from the accelerometer (m/s²).
  void onGravity(double x, double y, double z) {
    final len = sqrt(x * x + y * y + z * z);
    if (len >= 1e-6) {
      _gx = x / len;
      _gy = y / len;
      _gz = z / len;
    }
  }

  /// Ingests a gyroscope reading (rad/s) at [at].
  void onGyro(DateTime at, double x, double y, double z) {
    // Angular velocity component around the vertical axis (dot product ω · ĝ)
    final rateRad = x * _gx + y * _gy + z * _gz;
    final rateDeg = rateRad.abs() * (180.0 / pi);

    final dt = _lastAt == null
        ? 0.0
        : (at.difference(_lastAt!).inMicroseconds / 1000000.0).clamp(0.0, 0.1);
    _lastAt = at;

    _net += rateRad * (180.0 / pi) * dt;

    _recent.removeWhere((r) => at.difference(r.at) > turningWindow);
    _recent.add((at: at, rate: rateDeg));
  }

  /// Whether the average turning rate in [turningWindow] is >= [turningRate].
  bool turningAt(DateTime now) {
    _recent.removeWhere((r) => now.difference(r.at) > turningWindow);
    if (_recent.isEmpty) return false;
    final sum = _recent.fold<double>(0.0, (acc, r) => acc + r.rate);
    return (sum / _recent.length) >= turningRate;
  }

  void reset() {
    _net = 0.0;
    _lastAt = null;
    _recent.clear();
  }
}

