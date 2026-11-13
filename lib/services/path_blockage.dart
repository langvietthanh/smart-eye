import '../models/scene_info.dart';
import 'depth_analysis.dart';
import 'lidar_analysis.dart';

/// `cleared`: the way ahead is open (leaving a trap, or after a centre
/// warning, see [PathBlockage.watchAhead]). `opened`: a side opened while the
/// centre is still blocked (the user turned towards a single obstacle).
enum PathEvent { trapped, cleared, opened }

/// Decides when the user is boxed in (front, left and right all blocked) and
/// when the way ahead opens again. Pure Dart; time is passed in explicitly.
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
  bool _trapped = false;
  DateTime? _since;
  bool _watching = false;
  DateTime? _clearSince;
  DateTime? _openSince;

  bool get trapped => _trapped;

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
  /// a full YOLO column. YOLO's "near" is box size, not metres: a chair 2–3 m
  /// away reads "khá gần", so it never overrules a LiDAR measurement.
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

  /// Exit needs one direction clearly open: with LiDAR, clear or an obstacle
  /// beyond [exitClearBeyond] (matches `LidarWarning.cautionExit`).
  bool _open(DateTime now, HPos pos) {
    if (blocked(now)[pos.index]) return false;
    if (!_seenDepth) return true;
    if (_fresh(_scanAt, now, depthMaxAge)) {
      return switch (_scan![pos]) {
        LidarClear() => true,
        LidarObstacle(:final distance) => distance > exitClearBeyond,
        LidarUnknown() => false,
      };
    }
    if (_fresh(_monoAt, now, monoMaxAge)) {
      final m = _mono!;
      final closeness = switch (pos) {
        HPos.left => m.left,
        HPos.center => m.center,
        HPos.right => m.right,
      };
      return closeness < DepthAnalysis.clearBelow;
    }
    return false;
  }

  PathEvent? evaluate(DateTime now) {
    final centreOpen = _trapped && _open(now, HPos.center);
    final holds = _trapped
        ? centreOpen || _open(now, HPos.left) || _open(now, HPos.right)
        : blocked(now).every((b) => b);
    if (!holds) {
      _since = null;
    } else {
      _since ??= now;
      if (now.difference(_since!) >= settle) {
        _trapped = !_trapped;
        _since = null;
        _clearSince = null;
        if (_trapped) {
          _watching = true;
          return PathEvent.trapped;
        }
        if (centreOpen) {
          _watching = false;
          return PathEvent.cleared;
        }
        return PathEvent.opened;
      }
    }
    // Outside a trap, "open ahead" is never claimed from YOLO alone: it
    // cannot see walls, doors or boxes it has no class for.
    if (_trapped || !_watching || !_seenDepth || !_open(now, HPos.center)) {
      _clearSince = null;
      return null;
    }
    _clearSince ??= now;
    if (now.difference(_clearSince!) < settle) return null;
    _watching = false;
    _clearSince = null;
    return PathEvent.cleared;
  }

  /// The way ahead has been measured open (same rule as leaving a trap) for
  /// [settle], from inputs that are still fresh.
  bool aheadOpenSettled(DateTime now) {
    final fresh =
        _fresh(_loadAt, now, detectionMaxAge) ||
        _fresh(_scanAt, now, depthMaxAge);
    if (!fresh || !_open(now, HPos.center)) {
      _openSince = null;
    _clearSince = null;
      return false;
    }
    _openSince ??= now;
    return now.difference(_openSince!) >= settle;
  }

  /// The view cannot be trusted right now: restart the settle timers without
  /// changing [trapped], so neither entry, exit nor clearing completes.
  void interrupt() {
    _since = null;
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
    _trapped = false;
    _since = null;
    _watching = false;
    _clearSince = null;
    _openSince = null;
  }
}
