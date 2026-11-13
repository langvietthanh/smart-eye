enum WalkPhase { straight, findWay }

enum WalkCue { turnOn, goStraight }

/// State machine for free-walking mode with two phases:
/// - [WalkPhase.straight]: walking forward, receiving standard obstacle alerts.
/// - [WalkPhase.findWay]: blocked ahead, turning in place to locate an open corridor.
///
/// Pure Dart class with no platform or speech dependencies.
class WalkState {
  /// Way ahead counts as open past this distance (metres).
  static const exitBeyond = 1.5;
  static const turningSettle = Duration(milliseconds: 300);
  static const settle = Duration(seconds: 1);

  WalkPhase _phase = WalkPhase.straight;
  DateTime? _openSince;

  WalkPhase get phase => _phase;

  /// A depth danger is about to be spoken. Returns true when this enters
  /// [WalkPhase.findWay]: the caller then speaks findWayText instead of the
  /// regular danger alert line.
  bool onDanger({required bool wall, required bool sideOpen}) {
    if (_phase == WalkPhase.findWay) return false;
    if (wall || !sideOpen) {
      _phase = WalkPhase.findWay;
      _openSince = null;
      return true;
    }
    return false;
  }

  /// Evaluates state transitions. Only acts when in [WalkPhase.findWay].
  WalkCue? tick(
    DateTime now, {
    required bool aheadOpen,
    required bool turning,
    required double turnedDegrees,
  }) {
    if (_phase != WalkPhase.findWay) return null;

    if (aheadOpen) {
      _openSince ??= now;
      final requiredDuration = turning ? turningSettle : settle;
      if (now.difference(_openSince!) >= requiredDuration) {
        _phase = WalkPhase.straight;
        _openSince = null;
        return WalkCue.goStraight;
      }
    } else {
      _openSince = null;
    }

    if (turnedDegrees >= 30) {
      return WalkCue.turnOn;
    }

    return null;
  }

  /// Resets back to [WalkPhase.straight] silently.
  void reset() {
    _phase = WalkPhase.straight;
    _openSince = null;
  }
}

