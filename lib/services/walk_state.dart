import 'dart:math';

import '../models/scene_info.dart';
import 'lidar_analysis.dart';

enum WalkPhase { straight, findWay, collect, sidestep, passing, returning }

enum WalkCue {
  turnOn,
  goStraight,
  findWay,
  findWayReminder,
  stepRight,
  stepLeft,
  stop,
}

enum DangerAction { none, stop, findWay }

/// Free walking: stop, verify a body-width lane, move sideways, pass the
/// obstacle, verify the return sweep, and confirm alignment before continuing.
/// Room position and positively observed floor are required for a bypass.
class WalkState {
  static const exitBeyond = 1.5;
  static const turningSettle = Duration(milliseconds: 300);
  static const settle = Duration(seconds: 1);
  static const findWayRepeat = Duration(seconds: 6);
  static const collectFrames = 5;
  static const collectAgree = 4;
  static const sidestepGapMin = LidarAnalysis.gapMin;
  static const centreClearFrames = 2;
  static const passMargin = 0.3;
  static const memoryAcross = 0.15;
  static const memoryReach = 0.6;
  static const collectTimeout = Duration(seconds: 2);
  static const sidestepTimeout = Duration(seconds: 5);
  static const passingTimeout = Duration(seconds: 20);
  static const scanMaxAge = Duration(milliseconds: 500);
  static const floorMemoryAge = Duration(seconds: 3);
  static const gapMemoryAge = Duration(seconds: 2);
  static const alignmentTolerance = 0.1;
  static const bodyHalfDepth = 0.25;

  WalkPhase _phase = WalkPhase.straight;
  int _revision = 0;
  bool _findWayPromptStarted = false;
  DateTime? _openSince, _phaseSince, _lastScanAt, _lastFindWayCueAt;
  HPos? _stepSide;
  int _frames = 0, _leftVotes = 0, _rightVotes = 0, _clearFrames = 0;
  double? _laneAcross;
  LidarPose? _origin, _lastPose;
  double _hx = 0, _hz = 0;
  double? _near, _far;
  double _acrossMin = 0, _acrossMax = 0;
  final _floor = <(int, int), _RoomCell>{};
  final _gaps = <HPos, _GapObservation>{};

  WalkPhase get phase => _phase;
  int get revision => _revision;
  HPos? get stepSide => _stepSide;
  bool get _bypassing =>
      _phase != WalkPhase.straight && _phase != WalkPhase.findWay;

  /// A queued TTS request is not yet an instruction the user has heard.
  /// Rotation guidance starts only after the matching find-way prompt begins.
  bool markFindWayPromptStarted(int revision, DateTime now) {
    if (_phase != WalkPhase.findWay || _revision != revision) return false;
    _findWayPromptStarted = true;
    _lastFindWayCueAt = now;
    return true;
  }

  /// Advance reminders only when the matching turn/status cue starts TTS.
  /// Merely returning a cue from [tick] must not consume its reminder period.
  bool markFindWayCueStarted(int revision, DateTime now) {
    if (_phase != WalkPhase.findWay ||
        _revision != revision ||
        !_findWayPromptStarted) return false;
    _lastFindWayCueAt = now;
    return true;
  }

  /// Detector warnings must enter the same avoidance flow as depth warnings;
  /// speech cooldowns and an empty column-load estimate cannot suppress it.
  DangerAction onAlert(
    HazardAlert alert, {
    required bool canBypass,
    bool wall = false,
  }) {
    if (alert.level != AlertLevel.danger ||
        (!alert.inPath && alert.pos != HPos.center)) {
      return DangerAction.none;
    }
    return onDanger(wall: wall, sideOpen: false, canBypass: canBypass);
  }

  DangerAction onDanger({
    required bool wall,
    required bool sideOpen,
    required bool canBypass,
  }) {
    if (_phase == WalkPhase.findWay) return DangerAction.none;
    if (wall) {
      _enter(WalkPhase.findWay);
      return DangerAction.findWay;
    }
    if (_phase == WalkPhase.collect || _phase == WalkPhase.sidestep) {
      return DangerAction.none;
    }
    if (canBypass) {
      _enter(WalkPhase.collect);
      return DangerAction.stop;
    }
    if (_bypassing || !sideOpen) {
      _enter(WalkPhase.findWay);
      return DangerAction.findWay;
    }
    return DangerAction.none;
  }

  /// Called once for each fresh scan, including while approaching an obstacle.
  /// Recent floor/gap observations are kept in room coordinates: close to an
  /// obstacle, the floor beside it often no longer fits in the camera view.
  WalkCue? onScan(DateTime now, LidarScan scan, {bool stopped = true}) {
    final previousAt = _lastScanAt;
    if (previousAt != null && !now.isAfter(previousAt)) return null;
    final pose = scan.pose;
    final center = scan.center;
    final valid = pose != null &&
        pose.isValid &&
        center is! LidarUnknown &&
        (center is! LidarObstacle ||
            (center.distance.isFinite && center.distance > 0));
    final interrupted =
        previousAt != null && now.difference(previousAt) > scanMaxAge;
    final jumped = pose != null && valid && _lastPose != null &&
        sqrt(pow(pose.x - _lastPose!.x, 2) +
            pow(pose.z - _lastPose!.z, 2)) > 0.75;
    _lastScanAt = now;
    if (interrupted || jumped || !valid) {
      _floor.clear();
      _gaps.clear();
      _lastPose = valid ? pose : null;
      if (_bypassing) return _findWay();
      if (!valid) return null;
    }
    _lastPose = pose;
    _observeRoom(now, scan, pose!);
    if (!_bypassing) return null;
    _phaseSince ??= now;
    if (_timedOut(now)) return _findWay();
    // A queued stop must reach TTS before any scan can vote for a side.
    if (_phase == WalkPhase.collect && !stopped) return null;
    if (_origin != null && !_aligned(pose)) return _findWay();
    final centre = scan.center;
    if (centre is LidarObstacle && centre.wall) return _findWay();
    if ((_phase == WalkPhase.passing || _phase == WalkPhase.returning) &&
        centre is LidarObstacle && centre.distance <= LidarWarning.dangerEnter) {
      _enter(WalkPhase.collect, now);
      return WalkCue.stop;
    }

    switch (_phase) {
      case WalkPhase.collect:
        if (_open(centre)) {
          _clearFrames++;
          if (_clearFrames < centreClearFrames) return null;
          _enter(WalkPhase.straight);
          return WalkCue.goStraight;
        }
        _clearFrames = 0;
        if (centre is! LidarObstacle) return null;
        _remember(scan, seed: centre.distance);
        _frames++;
        final left = _candidate(now, scan, HPos.left);
        final right = _candidate(now, scan, HPos.right);
        if (left != null) _leftVotes++;
        if (right != null) _rightVotes++;
        if (_frames < collectFrames) return null;
        // The latest frame must still authorize the side chosen by the votes.
        if (_rightVotes >= collectAgree && right != null) {
          return _step(HPos.right, right, now);
        }
        if (_leftVotes >= collectAgree && left != null) {
          return _step(HPos.left, left, now);
        }
        return _findWay();
      case WalkPhase.sidestep:
        _remember(scan);
        if (!_sweepClear(now, pose, _laneAcross!) ||
            _laneBlocked(now, pose, _laneAcross!)) {
          return _findWay();
        }
        final aligned =
            (_across(pose.x, pose.z) - _laneAcross!).abs() <= alignmentTolerance;
        _clearFrames = _open(centre) && aligned ? _clearFrames + 1 : 0;
        if (_clearFrames < centreClearFrames) return null;
        _enter(WalkPhase.passing, now);
        return WalkCue.goStraight;
      case WalkPhase.passing:
        _remember(scan);
        // Disappearance or elapsed time alone never proves the far side is
        // passable. The return sweep must contain observed floor, no obstacle.
        if (_far == null ||
            _along(pose.x, pose.z) < _far! + passMargin + bodyHalfDepth ||
            !_sweepClear(now, pose, 0)) {
          return null;
        }
        final back =
            _stepSide == HPos.right ? WalkCue.stepLeft : WalkCue.stepRight;
        _enter(WalkPhase.returning, now);
        return back;
      case WalkPhase.returning:
        if (!_sweepClear(now, pose, 0)) return _findWay();
        _clearFrames =
            _open(centre) && _across(pose.x, pose.z).abs() <= alignmentTolerance
            ? _clearFrames + 1
            : 0;
        if (_clearFrames < centreClearFrames) return null;
        _enter(WalkPhase.straight);
        return WalkCue.goStraight;
      case WalkPhase.straight:
      case WalkPhase.findWay:
        return null;
    }
  }

  WalkCue? tick(
    DateTime now, {
    required bool aheadOpen,
    required bool turning,
    required double turnedDegrees,
  }) {
    if (_bypassing) {
      _phaseSince ??= now;
      if (_lastScanAt != null && now.difference(_lastScanAt!) > scanMaxAge) {
        return _findWay();
      }
      if (_timedOut(now)) return _findWay();
      return null;
    }
    if (_phase != WalkPhase.findWay) return null;
    if (!_findWayPromptStarted) return null;
    if (aheadOpen) {
      _openSince ??= now;
      if (now.difference(_openSince!) >= (turning ? turningSettle : settle)) {
        _enter(WalkPhase.straight);
        return WalkCue.goStraight;
      }
      return null;
    } else {
      _openSince = null;
    }
    if (turnedDegrees >= 30) return WalkCue.turnOn;
    final lastCue = _lastFindWayCueAt;
    return lastCue != null && now.difference(lastCue) >= findWayRepeat
        ? WalkCue.findWayReminder
        : null;
  }

  void reset() {
    _enter(WalkPhase.straight);
    _floor.clear();
    _gaps.clear();
    _lastScanAt = null;
    _lastPose = null;
  }

  bool _open(LidarReading centre) =>
      centre is LidarClear ||
      (centre is LidarObstacle && centre.distance > exitBeyond);

  bool _timedOut(DateTime now) {
    final limit = switch (_phase) {
      WalkPhase.collect => collectTimeout,
      WalkPhase.passing => passingTimeout,
      _ => sidestepTimeout,
    };
    return _phaseSince != null && now.difference(_phaseSince!) >= limit;
  }

  WalkCue _findWay() {
    _enter(WalkPhase.findWay);
    return WalkCue.findWay;
  }

  WalkCue _step(HPos side, double across, DateTime now) {
    _enter(WalkPhase.sidestep, now);
    _stepSide = side;
    _laneAcross = across;
    return side == HPos.right ? WalkCue.stepRight : WalkCue.stepLeft;
  }

  void _enter(WalkPhase phase, [DateTime? now]) {
    _phase = phase;
    _revision++;
    _findWayPromptStarted = false;
    _lastFindWayCueAt = null;
    _phaseSince = now;
    _openSince = null;
    _frames = _leftVotes = _rightVotes = _clearFrames = 0;
    if (phase == WalkPhase.straight ||
        phase == WalkPhase.findWay ||
        phase == WalkPhase.collect) {
      _stepSide = null;
      _laneAcross = null;
      _origin = null;
      _near = _far = null;
    }
  }

  bool _aligned(LidarPose pose) {
    final len = sqrt(pose.headX * pose.headX + pose.headZ * pose.headZ);
    return (pose.headX * _hx + pose.headZ * _hz) / len >= 0.94;
  }

  double _along(double x, double z) =>
      (x - _origin!.x) * _hx + (z - _origin!.z) * _hz;
  double _across(double x, double z) =>
      (x - _origin!.x) * _hz - (z - _origin!.z) * _hx;

  void _observeRoom(DateTime now, LidarScan scan, LidarPose pose) {
    _floor.removeWhere((_, cell) => now.difference(cell.at) > floorMemoryAge);
    _gaps.removeWhere((_, gap) => now.difference(gap.at) > gapMemoryAge);
    final len = sqrt(pose.headX * pose.headX + pose.headZ * pose.headZ);
    final hx = pose.headX / len, hz = pose.headZ / len;
    void add(List<double> cells, bool free) {
      for (var i = 0; i + 1 < cells.length; i += 2) {
        final f = cells[i], s = cells[i + 1];
        if (!f.isFinite || !s.isFinite) continue;
        final x = pose.x + hx * f + hz * s, z = pose.z + hz * f - hx * s;
        final key = (
          (x / LidarAnalysis.cellSize).floor(),
          (z / LidarAnalysis.cellSize).floor(),
        );
        _floor[key] = _RoomCell(x, z, now, free);
      }
    }
    add(scan.freeCells, true);
    add(scan.cells, false); // Positive hazard evidence wins in the same scan.
    final c = scan.center;
    if (c is! LidarObstacle) return;
    for (final side in [HPos.left, HPos.right]) {
      final state = side == HPos.left ? c.left : c.right;
      final width = side == HPos.left ? c.leftGap : c.rightGap;
      final center = side == HPos.left ? c.leftGapCenter : c.rightGapCenter;
      if (state == SideState.blocked) _gaps.remove(side);
      if (state != SideState.clear ||
          !width.isFinite || width < sidestepGapMin - 1e-9 ||
          center == null || !center.isFinite ||
          (side == HPos.left ? center <= 0 : center >= 0)) continue;
      _gaps[side] = _GapObservation(now, pose, c.distance, center);
    }
  }

  double? _candidate(DateTime now, LidarScan scan, HPos side) {
    final gap = _gaps[side], pose = scan.pose!;
    if (gap == null ||
        now.difference(gap.at) > gapMemoryAge || !_aligned(gap.pose)) return null;
    final len = sqrt(gap.pose.headX * gap.pose.headX + gap.pose.headZ * gap.pose.headZ);
    final hx = gap.pose.headX / len, hz = gap.pose.headZ / len;
    final x = gap.pose.x + hx * gap.distance + hz * gap.side;
    final z = gap.pose.z + hz * gap.distance - hx * gap.side;
    if ((_along(x, z) - _near!).abs() > 0.35) return null;
    final across = _across(x, z);
    if ((side == HPos.left ? across <= 0 : across >= 0) ||
        !_sweepClear(now, pose, across) || _laneBlocked(now, pose, across)) {
      return null;
    }
    return across;
  }

  /// Fresh positive returns also veto a lane observed earlier on approach.
  bool _laneBlocked(DateTime now, LidarPose pose, double across) {
    final from = _along(pose.x, pose.z);
    final end = max(_near! + LidarAnalysis.lanePastObstacle,
        LidarAnalysis.laneMinDepth);
    return _floor.values.any((p) => !p.free &&
        now.difference(p.at) <= floorMemoryAge &&
        _along(p.x, p.z) >= from - bodyHalfDepth &&
        _along(p.x, p.z) <= end &&
        (_across(p.x, p.z) - across).abs() <= LidarAnalysis.halfWidth);
  }

  /// Verify the entire body footprint swept sideways. Unknown cells, holes,
  /// and expired observations cannot authorize a step. Room memory supplies
  /// the floor now outside the camera view, sampled on approach.
  bool _sweepClear(DateTime now, LidarPose pose, double destination) {
    final along = _along(pose.x, pose.z), across = _across(pose.x, pose.z);
    final lo = min(across, destination) - LidarAnalysis.halfWidth;
    final hi = max(across, destination) + LidarAnalysis.halfWidth;
    const cell = LidarAnalysis.cellSize;
    final occupied = _floor.values.where(
      (p) => !p.free && now.difference(p.at) <= floorMemoryAge,
    );
    for (final p in occupied) {
      if ((_along(p.x, p.z) - along).abs() <= bodyHalfDepth + cell &&
          _across(p.x, p.z) >= lo - cell &&
          _across(p.x, p.z) <= hi + cell) return false;
    }
    final seen = _floor.values.where(
      (p) => p.free && now.difference(p.at) <= floorMemoryAge,
    ).toList();
    for (var a = along - bodyHalfDepth; a <= along + bodyHalfDepth + 1e-9; a += cell) {
      for (var s = lo; s <= hi + 1e-9; s += cell) {
        final x = _origin!.x + _hx * a + _hz * s;
        final z = _origin!.z + _hz * a - _hx * s;
        if (!seen.any((p) =>
            (p.x - x).abs() <= cell * 0.76 &&
            (p.z - z).abs() <= cell * 0.76)) return false;
      }
    }
    return true;
  }

  void _remember(LidarScan scan, {double? seed}) {
    final pose = scan.pose!;
    final len = sqrt(pose.headX * pose.headX + pose.headZ * pose.headZ);
    final hx = pose.headX / len, hz = pose.headZ / len;
    if (_origin == null) {
      if (seed == null) return;
      _origin = pose;
      _hx = hx;
      _hz = hz;
      _near = _far = seed;
      _acrossMin = -LidarAnalysis.halfWidth;
      _acrossMax = LidarAnalysis.halfWidth;
    }
    for (var i = 0; i + 1 < scan.cells.length; i += 2) {
      final f = scan.cells[i], s = scan.cells[i + 1];
      if (!f.isFinite || !s.isFinite) continue;
      if (seed != null &&
          (s.abs() > LidarAnalysis.halfWidth ||
              f < seed - 0.1 || f > seed + memoryReach)) continue;
      final x = pose.x + hx * f + hz * s, z = pose.z + hz * f - hx * s;
      final along = _along(x, z), across = _across(x, z);
      if (across < _acrossMin - memoryAcross ||
          across > _acrossMax + memoryAcross ||
          along < _near! - 0.1 || along > _far! + memoryReach) continue;
      _far = max(_far!, along);
    }
  }
}

class _RoomCell {
  const _RoomCell(this.x, this.z, this.at, this.free);
  final double x, z;
  final DateTime at;
  final bool free;
}

class _GapObservation {
  const _GapObservation(this.at, this.pose, this.distance, this.side);
  final DateTime at;
  final LidarPose pose;
  final double distance, side;
}
