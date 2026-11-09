import '../models/scene_info.dart';
import 'lidar_analysis.dart';

/// `cleared`: the way ahead is open. `opened`: a side opened while the
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

  List<double>? _load;
  DateTime? _loadAt;
  LidarScan? _scan;
  DateTime? _scanAt;
  bool _seenDepth = false;
  bool _trapped = false;
  DateTime? _since;

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

  bool _fresh(DateTime? t, DateTime now, Duration maxAge) =>
      t != null && now.difference(t) <= maxAge;

  /// `[left, centre, right]`: YOLO column full, or LiDAR obstacle within
  /// [blockedWithin] metres, from inputs that are still fresh.
  List<bool> blocked(DateTime now) {
    final yolo = _fresh(_loadAt, now, detectionMaxAge);
    final lidar = _fresh(_scanAt, now, depthMaxAge);
    return List.generate(3, (i) {
      if (yolo && _load![i] >= 1.0) return true;
      if (lidar) {
        final r = _scan![HPos.values[i]];
        return r is LidarObstacle && r.distance <= blockedWithin;
      }
      return false;
    });
  }

  /// Exit needs one direction clearly open: with LiDAR, clear or an obstacle
  /// beyond [exitClearBeyond] (matches `LidarWarning.cautionExit`).
  bool _open(DateTime now, HPos pos) {
    if (blocked(now)[pos.index]) return false;
    if (!_seenDepth) return true;
    if (!_fresh(_scanAt, now, depthMaxAge)) return false;
    return switch (_scan![pos]) {
      LidarClear() => true,
      LidarObstacle(:final distance) => distance > exitClearBeyond,
      LidarUnknown() => false,
    };
  }

  PathEvent? evaluate(DateTime now) {
    final centreOpen = _trapped && _open(now, HPos.center);
    final holds = _trapped
        ? centreOpen || _open(now, HPos.left) || _open(now, HPos.right)
        : blocked(now).every((b) => b);
    if (!holds) {
      _since = null;
      return null;
    }
    _since ??= now;
    if (now.difference(_since!) < settle) return null;
    _trapped = !_trapped;
    _since = null;
    if (_trapped) return PathEvent.trapped;
    return centreOpen ? PathEvent.cleared : PathEvent.opened;
  }

  /// The view cannot be trusted right now: restart the settle timer without
  /// changing [trapped], so neither entry nor exit completes meanwhile.
  void interrupt() => _since = null;

  void reset() {
    _load = null;
    _loadAt = null;
    _scan = null;
    _scanAt = null;
    _seenDepth = false;
    _trapped = false;
    _since = null;
  }
}
