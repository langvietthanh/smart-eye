import '../models/scene_info.dart';
import 'lidar_analysis.dart';

enum PathEvent { trapped, cleared }

/// Decides when the user is boxed in (front, left and right all blocked) and
/// when the way ahead opens again. Pure Dart; time is passed in explicitly.
class PathBlockage {
  static const blockedWithin = 1.5;
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

  bool _centreOpen(DateTime now) {
    if (blocked(now)[1]) return false;
    if (!_seenDepth) return true;
    return _fresh(_scanAt, now, depthMaxAge) && _scan!.center is! LidarUnknown;
  }

  PathEvent? evaluate(DateTime now) {
    final holds = _trapped ? _centreOpen(now) : blocked(now).every((b) => b);
    if (!holds) {
      _since = null;
      return null;
    }
    _since ??= now;
    if (now.difference(_since!) < settle) return null;
    _trapped = !_trapped;
    _since = null;
    return _trapped ? PathEvent.trapped : PathEvent.cleared;
  }

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
