import 'dart:async';
import 'dart:ui';

import '../models/scene_info.dart';
import 'depth_analysis.dart';
import 'lidar_analysis.dart';
import 'visual_proximity.dart';

/// Parking-sensor style haptic feedback: the closer the nearest detected
/// obstacle in the walking path, the faster the pulses. Input is a proximity
/// in 0..1 (null = nothing worth signalling) from boxes or the depth map. No pulse means no
/// *detected* obstacle in the path, never a verified clear path.
class ProximityPulse {
  ProximityPulse({required this.onPulse});

  /// [strong] is true at full proximity.
  final void Function(bool strong) onPulse;

  static const slowest = Duration(milliseconds: 900);
  static const fastest = Duration(milliseconds: 200);

  Timer? _timer;
  double? _proximity;

  /// Box occupancy: medium threshold → 0, near threshold → 1.
  static double? fromOccupancy(double? occupancy) =>
      _scale(occupancy, VisualProximity.mediumEnter, VisualProximity.nearEnter);

  /// Depth closeness: starts below the caution threshold, full at danger.
  static double? fromCloseness(double? closeness) =>
      _scale(closeness, 0.6, DepthAnalysis.danger);

  /// LiDAR metres: slow pulses from 2.5 m, full at the danger distance.
  static double? fromDistance(double? metres) =>
      metres == null ? null : _scale(-metres, -2.5, -LidarWarning.dangerEnter);

  static double? _scale(double? value, double start, double full) =>
      value == null || value < start
      ? null
      : ((value - start) / (full - start)).clamp(0.0, 1.0);

  static Duration? intervalFor(double? proximity) {
    if (proximity == null) return null;
    final t = proximity.clamp(0.0, 1.0);
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

  void update(double? proximity) {
    final wasIdle = intervalFor(_proximity) == null;
    _proximity = proximity;
    // A newly appearing obstacle pulses at once; otherwise the running timer
    // picks up the new rate on its next tick.
    if (wasIdle && intervalFor(proximity) != null) {
      _timer?.cancel();
      _tick();
    }
  }

  void _tick() {
    final interval = intervalFor(_proximity);
    if (interval == null) {
      _timer = null;
      return;
    }
    onPulse(_proximity! >= 1);
    _timer = Timer(interval, _tick);
  }

  void stop() {
    _proximity = null;
    _timer?.cancel();
    _timer = null;
  }
}
