import '../models/scene_info.dart';
import 'depth_analysis.dart';
import 'lidar_analysis.dart';

/// `cleared`: the way ahead is open after an obstacle warning (see [PathBlockage.watchAhead]).
enum PathEvent { cleared }

/// Monitors corridor occupancy and open path ahead. Pure Dart; time is passed in explicitly.
class PathBlockage {
  static const blockedWithin = 1.5;
  static const exitClearBeyond = 2.2;
  static const settle = Duration(seconds: 1);
  static const detectionMaxAge = Duration(seconds: 1);
  static const depthMaxAge = Duration(milliseconds: 500);
  // MiDaS runs every >= 300 ms plus inference time, slower than LiDAR.
  static const monoMaxAge = Duration(seconds: 1);

  List<double>? _load;
  DateTime? _loadAt;
  HazardAlert? _alert;
  LidarScan? _scan;
  DateTime? _scanAt;
  DepthReading? _mono;
  DateTime? _monoAt;
  bool _seenDepth = false;
  bool _watching = false;
  DateTime? _clearSince;
  DateTime? _openSince;

  void onDetections(
    DateTime at,
    List<double> columnLoad, {
    HazardAlert? alert,
  }) {
    _load = columnLoad;
    _loadAt = at;
    _alert = alert;
  }

  void onDepth(DateTime at, LidarScan scan) {
    _scan = scan;
    _scanAt = at;
    _seenDepth = true;
  }

  /// Relative depth (no LiDAR). Only used as evidence that a way is open;
  /// blocking stays with YOLO, as MiDaS thresholds are not field-calibrated.
  void onMonoDepth(DateTime at, DepthReading reading) {
    _mono = reading;
    _monoAt = at;
    _seenDepth = true;
  }

  /// A centre obstacle was just announced: emit [PathEvent.cleared] once the
  /// way ahead has been open for [settle], with depth evidence.
  void watchAhead() {
    _watching = true;
    _clearSince = null;
  }

  bool _fresh(DateTime? t, DateTime now, Duration maxAge) =>
      t != null && !now.isBefore(t) && now.difference(t) <= maxAge;

  bool _dangerAhead(DateTime now) =>
      _fresh(_loadAt, now, detectionMaxAge) &&
      _alert?.level == AlertLevel.danger &&
      (_alert?.inPath == true || _alert?.pos == HPos.center);

  /// Diagnostic occupancy, not permission to step sideways. An empty YOLO
  /// column alone is unknown; a centre danger remains blocked even when its
  /// narrow box did not reach the column-load threshold or depth sees clear.
  List<SideState> states(DateTime now) {
    final yolo = _fresh(_loadAt, now, detectionMaxAge);
    final lidar = _fresh(_scanAt, now, depthMaxAge);
    final mono = _fresh(_monoAt, now, monoMaxAge);
    final closeness = _mono == null
        ? const [double.nan, double.nan, double.nan]
        : [_mono!.left, _mono!.center, _mono!.right];
    return List.generate(3, (i) {
      if (i == HPos.center.index && _dangerAhead(now)) {
        return SideState.blocked;
      }
      final r = lidar ? _scan![HPos.values[i]] : const LidarUnknown();
      if (r is! LidarUnknown) {
        return r is LidarObstacle && r.distance <= blockedWithin
            ? SideState.blocked
            : SideState.clear;
      }
      if (yolo && _load![i] >= 1.0) return SideState.blocked;
      if (yolo && mono && closeness[i].isFinite &&
          closeness[i] < DepthAnalysis.clearBelow) {
        return SideState.clear;
      }
      return SideState.unknown;
    });
  }

  /// A false value may still mean unknown; use [states] for diagnostics.
  List<bool> blocked(DateTime now) =>
      states(now).map((state) => state == SideState.blocked).toList();

  /// Whether the corridor ahead is open: with LiDAR, clear or an obstacle
  /// beyond [beyond]; without LiDAR, MiDaS sees no obstacle and YOLO centre is clear.
  bool openAhead(DateTime now, {double beyond = exitClearBeyond}) {
    if (blocked(now)[HPos.center.index]) return false;
    if (!_seenDepth) return false;
    if (_fresh(_scanAt, now, depthMaxAge)) {
      return switch (_scan![HPos.center]) {
        LidarClear() => true,
        LidarObstacle(:final distance) => distance > beyond,
        LidarUnknown() => false,
      };
    }
    if (_fresh(_monoAt, now, monoMaxAge)) {
      final m = _mono!;
      return _fresh(_loadAt, now, detectionMaxAge) &&
          m.center.isFinite && m.center < DepthAnalysis.clearBelow;
    }
    return false;
  }

  PathEvent? evaluate(DateTime now) {
    if (!_watching || !_seenDepth || !openAhead(now)) {
      _clearSince = null;
      return null;
    }
    _clearSince ??= now;
    if (now.difference(_clearSince!) < settle) return null;
    _watching = false;
    _clearSince = null;
    return PathEvent.cleared;
  }

  /// The way ahead has been measured open for [settle], from inputs that are still fresh.
  bool aheadOpenSettled(DateTime now) {
    final fresh =
        _fresh(_loadAt, now, detectionMaxAge) ||
        _fresh(_scanAt, now, depthMaxAge);
    if (!fresh || !openAhead(now)) {
      _openSince = null;
      _clearSince = null;
      return false;
    }
    _openSince ??= now;
    return now.difference(_openSince!) >= settle;
  }

  /// Restarts the settle timers without changing seen depth.
  void interrupt() {
    _openSince = null;
    _clearSince = null;
  }

  void reset() {
    _load = null;
    _loadAt = null;
    _alert = null;
    _scan = null;
    _scanAt = null;
    _mono = null;
    _monoAt = null;
    _seenDepth = false;
    _watching = false;
    _clearSince = null;
    _openSince = null;
  }
}
