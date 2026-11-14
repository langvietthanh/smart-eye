import '../models/scene_info.dart';
import 'lidar_analysis.dart';

/// `entered`: a wall ahead, turn to find a way. `remind`: still facing it.
/// `found`: the way ahead is open, walk on. `left`: no longer a wall but
/// something else close ahead; the obstacle alerts take over, silently here.
enum WallEvent { entered, remind, found, left }

/// [turn]: the side to turn to, null when LiDAR cannot tell.
typedef WallCue = ({WallEvent event, HPos? turn});

/// The third walking state beside "free" and "obstacle": a wall is not
/// stepped round, the user turns until the way ahead opens. Pure Dart; time
/// is passed in. Needs LiDAR (only it tells a wall apart).
class WallGuide {
  /// Not a wall ahead for this long ends the state.
  static const exitAfter = Duration(seconds: 1);
  static const remindEvery = Duration(seconds: 5);

  /// One side corridor this much deeper than the other is the way to turn.
  static const turnMargin = 0.5;

  bool _active = false;
  DateTime? _awaySince;
  DateTime? _lastCue;

  bool get active => _active;

  /// [warned]: LiDAR's warning for this reading is caution or danger
  /// ([LidarWarning]: two readings, hysteresis, standing still 1.5–2 m is
  /// not warned), so entering follows the same distance rules.
  WallCue? update(DateTime now, LidarScan scan, {required bool warned}) {
    final centre = scan.center;
    // No evidence either way: hold, but an exit must start over.
    if (centre is LidarUnknown) {
      _awaySince = null;
      return null;
    }
    final wall = centre is LidarObstacle && centre.wall;
    if (!_active) {
      if (!wall || !warned) return null;
      _active = true;
      _lastCue = now;
      return (event: WallEvent.entered, turn: turnOf(scan));
    }
    if (wall) {
      _awaySince = null;
      if (now.difference(_lastCue!) < remindEvery) return null;
      _lastCue = now;
      return (event: WallEvent.remind, turn: turnOf(scan));
    }
    _awaySince ??= now;
    if (now.difference(_awaySince!) < exitAfter) return null;
    reset();
    final open =
        centre is LidarClear ||
        (centre as LidarObstacle).distance > LidarWarning.cautionExit;
    return (event: open ? WallEvent.found : WallEvent.left, turn: null);
  }

  /// The side whose corridor (beside the 50 cm core, out to ~1 m) reaches
  /// clearly deeper: an angled wall recedes that way.
  static HPos? turnOf(LidarScan scan) {
    double? depth(LidarReading r) => switch (r) {
      LidarClear() => double.infinity,
      LidarObstacle(:final distance) => distance,
      LidarUnknown() => null,
    };
    final left = depth(scan.left), right = depth(scan.right);
    if (left == null || right == null || left == right) return null;
    if (left - right >= turnMargin) return HPos.left;
    if (right - left >= turnMargin) return HPos.right;
    return null;
  }

  void reset() {
    _active = false;
    _awaySince = null;
    _lastCue = null;
  }
}

/// What to say for [cue]; empty for [WallEvent.left]. While guiding to a
/// target the guide owns the heading, so "Đi thẳng" is left out.
String wallCueText(WallCue cue, {bool guiding = false}) {
  final turn = switch (cue.turn) {
    HPos.left => 'Quay sang trái.',
    HPos.right => 'Quay sang phải.',
    _ => 'Xoay trái hoặc phải để tìm lối.',
  };
  return switch (cue.event) {
    WallEvent.entered => 'Tường phía trước. $turn',
    WallEvent.remind => 'Vẫn là tường. $turn',
    WallEvent.found => guiding ? 'Đã có lối.' : 'Đã có lối. Đi thẳng.',
    WallEvent.left => '',
  };
}
