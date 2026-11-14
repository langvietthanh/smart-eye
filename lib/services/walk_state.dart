import '../models/scene_info.dart';
import 'lidar_analysis.dart';

enum WalkPhase { straight, findWay, collect, sidestep, passing }

enum WalkCue { turnOn, goStraight, findWay, stepRight, stepLeft }

/// What the caller says when a depth danger is about to be spoken.
/// stop: "Dừng lại!"; findWay: findWayText; none: the usual danger line
/// while going straight, silence while an obstacle is being bypassed.
enum DangerAction { none, stop, findWay }

/// State machine for free-walking mode:
/// - [WalkPhase.straight]: walking forward, receiving standard alerts.
/// - [WalkPhase.findWay]: blocked (or a wall), turning in place.
/// - Bypass (LiDAR only): [WalkPhase.collect] the frames after "Dừng lại!",
///   [WalkPhase.sidestep] to the side with a gap, [WalkPhase.passing] the
///   obstacle until it has been out of sight on the old side for a moment,
///   then step back.
///
/// Pure Dart class with no platform or speech dependencies.
class WalkState {
  /// Way ahead counts as open past this distance (metres).
  static const exitBeyond = 1.5;
  static const turningSettle = Duration(milliseconds: 300);
  static const settle = Duration(seconds: 1);

  /// LiDAR frames with the obstacle ahead used to pick the side.
  static const collectFrames = 5;

  /// Frames that must show the gap on the chosen side.
  static const collectAgree = 4;

  /// Narrowest gap beside the obstacle to step into (owner: 20–30 cm).
  static const sidestepGapMin = 0.25;

  /// Frames with the way ahead open that end the sidestep.
  static const centreClearFrames = 2;

  /// Old side out of sight this long before stepping back: a time estimate
  /// of walking past the obstacle (no position tracking yet).
  static const passDelay = Duration(seconds: 1);

  static const collectTimeout = Duration(seconds: 2);
  static const sidestepTimeout = Duration(seconds: 5);

  WalkPhase _phase = WalkPhase.straight;
  DateTime? _openSince;
  DateTime? _phaseSince;
  HPos? _stepSide;
  int _frames = 0, _leftVotes = 0, _rightVotes = 0;
  int _clearFrames = 0;
  DateTime? _goneSince;

  WalkPhase get phase => _phase;

  /// The side stepped to while bypassing, else null.
  HPos? get stepSide => _stepSide;

  bool get _bypassing =>
      _phase == WalkPhase.collect ||
      _phase == WalkPhase.sidestep ||
      _phase == WalkPhase.passing;

  /// A depth danger is about to be spoken. [canBypass]: LiDAR present.
  DangerAction onDanger({
    required bool wall,
    required bool sideOpen,
    required bool canBypass,
  }) {
    if (_phase == WalkPhase.findWay ||
        _phase == WalkPhase.collect ||
        _phase == WalkPhase.sidestep) {
      return DangerAction.none;
    }
    if (wall) {
      _enter(WalkPhase.findWay);
      return DangerAction.findWay;
    }
    if (canBypass) {
      _enter(WalkPhase.collect);
      return DangerAction.stop;
    }
    if (_phase == WalkPhase.passing) {
      // Without LiDAR there is no bypass to resume: treat as a new start.
      _enter(WalkPhase.straight);
    }
    if (sideOpen) return DangerAction.none;
    _enter(WalkPhase.findWay);
    return DangerAction.findWay;
  }

  /// Each LiDAR scan. Drives collect / sidestep / passing.
  WalkCue? onScan(DateTime now, LidarScan scan) {
    if (!_bypassing) return null;
    _phaseSince ??= now;
    switch (_phase) {
      case WalkPhase.collect:
        final centre = scan.center;
        if (centre is LidarClear) {
          _enter(WalkPhase.straight);
          return WalkCue.goStraight;
        }
        if (centre is! LidarObstacle) return null;
        _frames++;
        if (centre.leftGap >= sidestepGapMin - 1e-9) _leftVotes++;
        if (centre.rightGap >= sidestepGapMin - 1e-9) _rightVotes++;
        if (_frames < collectFrames) return null;
        if (_rightVotes >= collectAgree) return _step(HPos.right, now);
        if (_leftVotes >= collectAgree) return _step(HPos.left, now);
        _enter(WalkPhase.findWay);
        return WalkCue.findWay;
      case WalkPhase.sidestep:
        final centre = scan.center;
        final open =
            centre is LidarClear ||
            (centre is LidarObstacle && centre.distance > exitBeyond);
        _clearFrames = open ? _clearFrames + 1 : 0;
        if (_clearFrames < centreClearFrames) return null;
        _enter(WalkPhase.passing, now);
        return WalkCue.goStraight;
      case WalkPhase.passing:
        final oldSide = _stepSide == HPos.right ? HPos.left : HPos.right;
        if (scan[oldSide] is LidarObstacle) {
          final wasGone = _goneSince != null;
          _goneSince = null;
          return wasGone ? WalkCue.goStraight : null;
        }
        _goneSince ??= now;
        if (now.difference(_goneSince!) < passDelay) return null;
        _enter(WalkPhase.straight);
        return oldSide == HPos.left ? WalkCue.stepLeft : WalkCue.stepRight;
      case WalkPhase.straight:
      case WalkPhase.findWay:
        return null;
    }
  }

  /// Timers and find-way. Only acts in [WalkPhase.findWay] and while
  /// collecting or stepping aside (timeouts).
  WalkCue? tick(
    DateTime now, {
    required bool aheadOpen,
    required bool turning,
    required double turnedDegrees,
  }) {
    if (_phase == WalkPhase.collect || _phase == WalkPhase.sidestep) {
      _phaseSince ??= now;
      final limit = _phase == WalkPhase.collect
          ? collectTimeout
          : sidestepTimeout;
      if (now.difference(_phaseSince!) >= limit) {
        _enter(WalkPhase.findWay);
        return WalkCue.findWay;
      }
      return null;
    }
    if (_phase != WalkPhase.findWay) return null;

    if (aheadOpen) {
      _openSince ??= now;
      final requiredDuration = turning ? turningSettle : settle;
      if (now.difference(_openSince!) >= requiredDuration) {
        _enter(WalkPhase.straight);
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
  void reset() => _enter(WalkPhase.straight);

  WalkCue _step(HPos side, DateTime now) {
    _enter(WalkPhase.sidestep, now);
    _stepSide = side;
    return side == HPos.right ? WalkCue.stepRight : WalkCue.stepLeft;
  }

  void _enter(WalkPhase phase, [DateTime? now]) {
    _phase = phase;
    _phaseSince = now;
    _openSince = null;
    _frames = 0;
    _leftVotes = 0;
    _rightVotes = 0;
    _clearFrames = 0;
    _goneSince = null;
    if (phase == WalkPhase.straight ||
        phase == WalkPhase.findWay ||
        phase == WalkPhase.collect) {
      _stepSide = null;
    }
  }
}
