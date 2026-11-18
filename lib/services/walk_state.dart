import 'dart:math';

import '../models/scene_info.dart';
import 'lidar_analysis.dart';

enum WalkPhase { straight, findWay, collect, sidestep, passing }

enum WalkCue {
  turnOn,
  goStraight,
  findWay,
  stepRight,
  stepLeft,
  turnBack,
  stepDone,

  /// Both sides tried up to [WalkState.maxSearchTurn]: no way on towards
  /// the goal. Said once; the app never sends the user back on its own.
  blocked,
}

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

  /// Narrowest gap beside the obstacle to step into: LiDAR's 50 cm core
  /// (shoulders) plus 10 cm, or walking through it reads as a new obstacle
  /// ahead (simulator: a 58 cm aisle gap gave "Dừng lại!" midway). Measured
  /// gaps read ~5 cm narrow (5 cm strips), so this is ~65 cm of real floor.
  /// It is taken from the walk up (see [approachNear]), where LiDAR sees it.
  static const sidestepGapMin = 2 * LidarAnalysis.coreHalfWidth + 0.10;

  /// Gaps beside the obstacle ahead are remembered while it is this far
  /// away. After "Dừng lại!" (under ~1 m) the floor beside it has left
  /// LiDAR's view and the gap reads 0 (simulator, phone tilted 0–15°).
  static const approachNear = 0.9, approachFar = 2.5;

  /// A remembered gap older than this is not used.
  static const approachMaxAge = Duration(seconds: 3);

  /// Finding a way: only an open way up to this far round from where the
  /// turn started is taken. Past it the other side is tried; past it there
  /// too, the way on is blocked. Turning round in a narrow aisle used to
  /// take the way back, walking the user back to the start, not the goal.
  static const maxSearchTurn = 100.0;

  /// Frames with the way ahead open that end the sidestep.
  static const centreClearFrames = 2;

  /// Without an ARKit pose: old side out of sight this long before stepping
  /// back (a time estimate of walking past the obstacle).
  static const passDelay = Duration(seconds: 1);

  /// With a pose: depth assumed until the obstacle's side face is seen
  /// (LiDAR never sees its far edge from the front).
  static const memoryDepth = 0.6;

  /// Step back once this far past the obstacle's far edge.
  static const passMargin = 0.3;

  /// With a pose: the sidestep ends once the body (half 23 cm plus a
  /// margin) is past the obstacle's edge. "Open ahead" alone fits a 50 cm
  /// corridor into a ~58 cm aisle gap only within a few centimetres.
  static const stepClearance = 0.3;

  /// With a pose: back on the old line within this, after stepping back.
  static const returnTolerance = 0.08;
  static const returnTimeout = Duration(seconds: 4);

  /// Room cells join the remembered obstacle only within this much of it
  /// across, and up to [memoryReach] beyond its far edge, so a desk row
  /// alongside does not stretch it.
  static const memoryAcross = 0.15;
  static const memoryReach = 0.6;

  static const collectTimeout = Duration(seconds: 2);
  static const sidestepTimeout = Duration(seconds: 5);

  WalkPhase _phase = WalkPhase.straight;
  DateTime? _openSince;
  DateTime? _phaseSince;
  HPos? _stepSide;
  int _frames = 0, _leftVotes = 0, _rightVotes = 0;
  int _clearFrames = 0;
  DateTime? _goneSince;
  DateTime? _returningSince; // stepping back to the old line (pose only)
  double _bestLeft = 0, _bestRight = 0; // gaps used to pick the side
  double _stepGap = 0; // width of the gap stepped into

  // Room memory of the obstacle being bypassed, in a path frame fixed when
  // it was first seen: along = metres ahead of that spot, across = left.
  LidarPose? _origin;
  double _hx = 0, _hz = 0;
  double? _near, _far;
  double _acrossMin = 0, _acrossMax = 0;

  // Widest gap each side of the obstacle seen while walking up to it.
  double _seenLeft = 0, _seenRight = 0;
  double? _seenAt; // distance of the latest centre obstacle
  DateTime? _seenTime;

  // Heading (ARKit) for the find-way search.
  LidarPose? _lastPose;
  DateTime? _lastPoseAt;
  (double, double)? _searchHeading;
  double _firstSide = 0; // sign of the side tried first, 0 = not yet

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
    final pose = scan.pose;
    if (pose != null) {
      _lastPose = pose;
      _lastPoseAt = now;
    }
    if (_phase == WalkPhase.straight) _noteApproach(now, scan.center);
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
        _remember(scan, seed: centre.distance);
        _frames++;
        final fresh =
            _seenTime != null && now.difference(_seenTime!) <= approachMaxAge;
        // LiDAR counts each side's gap from the walking line out. When the
        // remembered obstacle stops short of that line, the floor between
        // them belongs to the same gap (a chair 20 cm into a 1 m aisle
        // leaves 70 cm, read as 45 cm on the right without this).
        final reachRight = _near == null ? 0.0 : max(0.0, _acrossMin);
        final reachLeft = _near == null ? 0.0 : max(0.0, -_acrossMax);
        final left = max(centre.leftGap, fresh ? _seenLeft : 0.0) + reachLeft;
        final right =
            max(centre.rightGap, fresh ? _seenRight : 0.0) + reachRight;
        _bestLeft = max(_bestLeft, left);
        _bestRight = max(_bestRight, right);
        if (left >= sidestepGapMin - 1e-9) _leftVotes++;
        if (right >= sidestepGapMin - 1e-9) _rightVotes++;
        if (_frames < collectFrames) return null;
        if (_rightVotes >= collectAgree) return _step(HPos.right, now);
        if (_leftVotes >= collectAgree) return _step(HPos.left, now);
        _enter(WalkPhase.findWay);
        return WalkCue.findWay;
      case WalkPhase.sidestep:
        _remember(scan);
        if (_origin != null) {
          // ARKit: far enough aside once the body clears the obstacle's edge.
          if (pose == null) return null;
          final across = _across(pose.x, pose.z);
          final clear = _stepSide == HPos.right
              ? across <= _acrossMin - _stepOffset
              : across >= _acrossMax + _stepOffset;
          if (!clear) return null;
          _enter(WalkPhase.passing, now);
          return WalkCue.stepDone;
        }
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
        if (_origin != null) {
          // ARKit knows where the user is: step back only once past the
          // remembered far edge. No pose this frame: decide nothing.
          final since = _returningSince;
          if (since != null) {
            // Stepping back: "Đi thẳng." once on the old line again.
            final back =
                pose != null &&
                _across(pose.x, pose.z).abs() <= returnTolerance;
            if (!back && now.difference(since) < returnTimeout) return null;
            _enter(WalkPhase.straight);
            return WalkCue.stepDone;
          }
          if (pose == null) return null;
          _remember(scan);
          final far = max(_far!, _near! + memoryDepth * (_sideSeen ? 0 : 1));
          if (_along(pose.x, pose.z) < far + passMargin) return null;
          _returningSince = now;
          return oldSide == HPos.left ? WalkCue.stepLeft : WalkCue.stepRight;
        }
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

    final turned = _turnedFromStart(now);
    if (turned != null && turned.abs() > maxSearchTurn) {
      if (_firstSide == 0) {
        _firstSide = turned.sign;
        _openSince = null;
        return WalkCue.turnBack;
      }
      if (turned.sign != _firstSide) {
        // Past the limit on the other side too: nothing open towards the
        // goal. Back to normal alerts; going back is the user's choice.
        _enter(WalkPhase.straight);
        return WalkCue.blocked;
      }
    }
    final inSearch = turned == null || turned.abs() <= maxSearchTurn;
    if (aheadOpen && inSearch) {
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

  /// How far past the obstacle's edge to stand: the middle of the gap,
  /// at least [stepClearance], at most a long step.
  double get _stepOffset => max(stepClearance, min(_stepGap / 2, 0.45));

  WalkCue _step(HPos side, DateTime now) {
    _stepGap = side == HPos.right ? _bestRight : _bestLeft;
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
    _returningSince = null;
    _bestLeft = _bestRight = 0;
    if (phase == WalkPhase.straight ||
        phase == WalkPhase.findWay ||
        phase == WalkPhase.collect) {
      _stepSide = null;
      _origin = null;
      _near = _far = null;
    }
    if (phase != WalkPhase.collect) _forgetApproach();
    final p = _lastPose;
    _searchHeading = phase == WalkPhase.findWay && p != null
        ? (p.headX, p.headZ)
        : null;
    _firstSide = 0;
  }

  void _forgetApproach() {
    _seenLeft = _seenRight = 0;
    _seenAt = null;
    _seenTime = null;
  }

  /// Widest gaps seen beside the centre obstacle while walking up to it;
  /// forgotten when the way clears or another obstacle is ahead.
  void _noteApproach(DateTime now, LidarReading centre) {
    switch (centre) {
      case LidarClear():
        _forgetApproach();
      case LidarObstacle(:final distance, :final leftGap, :final rightGap):
        final last = _seenAt;
        if (last != null && distance > last + 0.5) _forgetApproach();
        _seenAt = distance;
        if (distance >= approachNear && distance <= approachFar) {
          _seenLeft = max(_seenLeft, leftGap);
          _seenRight = max(_seenRight, rightGap);
          _seenTime = now;
        }
      case LidarUnknown():
        break;
    }
  }

  /// Signed degrees turned since find-way began (ARKit heading), or null
  /// without a recent pose.
  double? _turnedFromStart(DateTime now) {
    final h0 = _searchHeading, p = _lastPose, at = _lastPoseAt;
    if (h0 == null || p == null || at == null) return null;
    if (now.difference(at) > const Duration(seconds: 1)) return null;
    final (x0, z0) = h0;
    final cross = x0 * p.headZ - z0 * p.headX;
    final dot = x0 * p.headX + z0 * p.headZ;
    return atan2(cross, dot) * 180 / pi;
  }

  /// The side face has been seen when cells reach past the front.
  bool get _sideSeen => _far! > _near! + 0.1;

  double _along(double x, double z) =>
      (x - _origin!.x) * _hx + (z - _origin!.z) * _hz;

  // left = up × forward = (hz, -hx) on the floor plane.
  double _across(double x, double z) =>
      (x - _origin!.x) * _hz - (z - _origin!.z) * _hx;

  /// Adds this scan's obstacle cells to the room memory. [seed] (collect):
  /// the centre obstacle's distance; only its front cells start the memory.
  void _remember(LidarScan scan, {double? seed}) {
    final pose = scan.pose;
    if (pose == null) return;
    final hl = sqrt(pose.headX * pose.headX + pose.headZ * pose.headZ);
    if (hl < 1e-6) return;
    final hx = pose.headX / hl, hz = pose.headZ / hl;
    if (_origin == null) {
      if (seed == null) return;
      _origin = pose;
      _hx = hx;
      _hz = hz;
    }
    final c = scan.cells;
    for (var i = 0; i + 1 < c.length; i += 2) {
      final f = c[i], s = c[i + 1];
      if (seed != null &&
          (s.abs() > LidarAnalysis.halfWidth ||
              f < seed - 0.1 ||
              f > seed + memoryReach)) {
        continue;
      }
      final x = pose.x + hx * f + hz * s, z = pose.z + hz * f - hx * s;
      final along = _along(x, z), across = _across(x, z);
      if (_near == null) {
        if (seed == null) continue;
        _near = _far = along;
        _acrossMin = _acrossMax = across;
        continue;
      }
      if (seed != null) {
        _near = min(_near!, along);
        _far = max(_far!, along);
        _acrossMin = min(_acrossMin, across);
        _acrossMax = max(_acrossMax, across);
        continue;
      }
      if (across < _acrossMin - memoryAcross ||
          across > _acrossMax + memoryAcross ||
          along < _near! - 0.1 ||
          along > _far! + memoryReach) {
        continue;
      }
      _far = max(_far!, along);
    }
  }
}
