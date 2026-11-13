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
  LidarScan? _scan;
  DateTime? _scanAt;
  DepthReading? _mono;
  DateTime? _monoAt;
  bool _seenDepth = false;
  bool _watching = false;
  DateTime? _clearSince;
  DateTime? _openSince;

  void onDetections(DateTime at, List<double> columnLoad) {
    _load = columnLoad;
    _loadAt = at;
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
      t != null && now.difference(t) <= maxAge;

  /// `[left, centre, right]` from inputs that are still fresh: a LiDAR
  /// obstacle within [blockedWithin] metres, or, where LiDAR has no reading,
  /// a full YOLO column.
  List<bool> blocked(DateTime now) {
    final yolo = _fresh(_loadAt, now, detectionMaxAge);
    final lidar = _fresh(_scanAt, now, depthMaxAge);
    return List.generate(3, (i) {
      final r = lidar ? _scan![HPos.values[i]] : const LidarUnknown();
      if (r is! LidarUnknown) {
        return r is LidarObstacle && r.distance <= blockedWithin;
      }
      return yolo && _load![i] >= 1.0;
    });
  }

  /// Whether the corridor ahead is open: with LiDAR, clear or an obstacle
  /// beyond [beyond]; without LiDAR, MiDaS sees no obstacle and YOLO centre is clear.
  bool openAhead(DateTime now, {double beyond = exitClearBeyond}) {
    if (blocked(now)[HPos.center.index]) return false;
    if (!_seenDepth) return true;
    if (_fresh(_scanAt, now, depthMaxAge)) {
      return switch (_scan![HPos.center]) {
        LidarClear() => true,
        LidarObstacle(:final distance) => distance > beyond,
        LidarUnknown() => false,
      };
    }
    if (_fresh(_monoAt, now, monoMaxAge)) {
      final m = _mono!;
      return m.center < DepthAnalysis.clearBelow;
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
