/// Work that consumes a fresh camera frame. The caller never queues images.
enum CameraInference { detection, depth }

/// Runs the camera's two CPU-heavy models in separate time slots.
///
/// Both workers remain off the UI isolate, but running their native thread
/// pools at once can compete with the camera/renderer. Busy callers drop the
/// frame. Once idle, the oldest due model gets the new frame, so a slow depth
/// model cannot repeatedly take the slot ahead of object detection.
class CameraInferenceScheduler {
  static const detectionIntervalMs = 150;
  static const depthIntervalMs = 300;

  int? _detectionAt;
  int? _depthAt;

  CameraInference? take(
    int nowMs, {
    required bool busy,
    required bool depthAvailable,
    bool detectionPacedBySource = false,
  }) {
    if (busy || nowMs < 0) return null;
    final detectionDue = detectionPacedBySource
        ? nowMs
        : _detectionAt == null
        ? 0
        : _detectionAt! + detectionIntervalMs;
    final depthDue = _depthAt == null ? 0 : _depthAt! + depthIntervalMs;
    final detect = nowMs >= detectionDue;
    final depth = depthAvailable && nowMs >= depthDue;
    if (!detect && !depth) return null;

    // Equal deadlines favour detection, including the first frame. Otherwise
    // select the most overdue task, not whichever worker is checked first.
    if (depth && (!detect || depthDue < detectionDue)) {
      _depthAt = nowMs;
      return CameraInference.depth;
    }
    _detectionAt = nowMs;
    return CameraInference.detection;
  }
}
