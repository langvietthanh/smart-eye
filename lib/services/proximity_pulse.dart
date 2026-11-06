import 'dart:async';
import 'dart:ui';

import '../models/scene_info.dart';
import 'visual_proximity.dart';

/// Parking-sensor style haptic feedback: the closer the nearest detected
/// obstacle in the walking path, the faster the pulses. No pulse means no
/// *detected* obstacle in the path, never a verified clear path.
class ProximityPulse {
  ProximityPulse({required this.onPulse});

  /// [strong] is true at the near threshold.
  final void Function(bool strong) onPulse;

  static const slowest = Duration(milliseconds: 900);
  static const fastest = Duration(milliseconds: 200);

  Timer? _timer;
  double? _occupancy;

  /// Null while nothing relevant is in the path or it is still far.
  static Duration? intervalFor(double? occupancy) {
    if (occupancy == null || occupancy < VisualProximity.mediumEnter) {
      return null;
    }
    final t =
        ((occupancy - VisualProximity.mediumEnter) /
                (VisualProximity.nearEnter - VisualProximity.mediumEnter))
            .clamp(0.0, 1.0);
    final ms =
        slowest.inMilliseconds -
        (slowest.inMilliseconds - fastest.inMilliseconds) * t;
    return Duration(milliseconds: ms.round());
  }

  /// Largest image occupancy among currently observed relevant objects in the
  /// walking path, or null if there is none.
  static double? pathOccupancy(SceneAssessment scene, Size frame) {
    double? best;
    for (final object in scene.objects) {
      final box = object.track.observedBox;
      if (!object.isRelevant ||
          object.track.misses != 0 ||
          !VisualProximity.inPath(box, frame)) {
        continue;
      }
      final occupancy = VisualProximity.occupancy(box, frame);
      if (best == null || occupancy > best) best = occupancy;
    }
    return best;
  }

  void update(double? occupancy) {
    final wasIdle = intervalFor(_occupancy) == null;
    _occupancy = occupancy;
    // A newly appearing obstacle pulses at once; otherwise the running timer
    // picks up the new rate on its next tick.
    if (wasIdle && intervalFor(occupancy) != null) {
      _timer?.cancel();
      _tick();
    }
  }

  void _tick() {
    final interval = intervalFor(_occupancy);
    if (interval == null) {
      _timer = null;
      return;
    }
    onPulse(_occupancy! >= VisualProximity.nearEnter);
    _timer = Timer(interval, _tick);
  }

  void stop() {
    _occupancy = null;
    _timer?.cancel();
    _timer = null;
  }
}
