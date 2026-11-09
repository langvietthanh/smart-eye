import 'dart:math' as math;

/// Bounded latency samples. Adding a frame is O(1); percentiles are calculated
/// only when a diagnostic consumer requests a snapshot.
class RollingLatency {
  RollingLatency({int capacity = 120})
    : _samples = List<int>.filled(_validCapacity(capacity), 0);

  final List<int> _samples;
  int _next = 0;
  int _count = 0;
  int _sum = 0;

  static int _validCapacity(int value) {
    if (value <= 0) {
      throw ArgumentError.value(value, 'capacity', 'Must be positive');
    }
    return value;
  }

  void addMicroseconds(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'Must not be negative');
    }
    if (_count == _samples.length) {
      _sum -= _samples[_next];
    } else {
      _count++;
    }
    _samples[_next] = value;
    _sum += value;
    _next = (_next + 1) % _samples.length;
  }

  LatencySummary get snapshot {
    if (_count == 0) return const LatencySummary.empty();
    final sorted = _samples.take(_count).toList()..sort();
    // Nearest-rank percentiles: an observed latency rather than interpolation.
    double percentile(double fraction) =>
        sorted[(_count * fraction).ceil() - 1] / 1000;
    return LatencySummary(
      count: _count,
      meanMs: _sum / _count / 1000,
      p50Ms: percentile(0.50),
      p95Ms: percentile(0.95),
      maxMs: sorted.last / 1000,
    );
  }
}

class LatencySummary {
  const LatencySummary({
    required this.count,
    required this.meanMs,
    required this.p50Ms,
    required this.p95Ms,
    required this.maxMs,
  });

  const LatencySummary.empty()
    : count = 0,
      meanMs = 0,
      p50Ms = 0,
      p95Ms = 0,
      maxMs = 0;

  final int count;
  final double meanMs;
  final double p50Ms;
  final double p95Ms;
  final double maxMs;
}

/// Wall-clock durations, not CPU time. Input copy is separated from native
/// inference; postprocess includes output decoding, filtering and NMS.
class DetectionTimings {
  const DetectionTimings({
    required this.preprocessUs,
    required this.inputCopyUs,
    required this.inferenceUs,
    required this.postprocessUs,
    required this.workerUs,
    required this.endToEndUs,
  });

  final int preprocessUs;
  final int inputCopyUs;
  final int inferenceUs;
  final int postprocessUs;
  final int workerUs;

  /// From DetectorService.detect dispatch until the result returns on the UI
  /// isolate; excludes camera acquisition, tracking, UI painting and speech.
  final int endToEndUs;

  int get transportAndSchedulingUs => math.max(0, endToEndUs - workerUs);

  DetectionTimings withEndToEnd(int elapsedUs) => DetectionTimings(
    preprocessUs: preprocessUs,
    inputCopyUs: inputCopyUs,
    inferenceUs: inferenceUs,
    postprocessUs: postprocessUs,
    workerUs: workerUs,
    endToEndUs: elapsedUs,
  );
}

class DetectorPerformance {
  DetectorPerformance({int capacity = 120})
    : preprocess = RollingLatency(capacity: capacity),
      inputCopy = RollingLatency(capacity: capacity),
      inference = RollingLatency(capacity: capacity),
      postprocess = RollingLatency(capacity: capacity),
      worker = RollingLatency(capacity: capacity),
      endToEnd = RollingLatency(capacity: capacity),
      transportAndScheduling = RollingLatency(capacity: capacity);

  final RollingLatency preprocess;
  final RollingLatency inputCopy;
  final RollingLatency inference;
  final RollingLatency postprocess;
  final RollingLatency worker;
  final RollingLatency endToEnd;
  final RollingLatency transportAndScheduling;
  DetectionTimings? latest;
  int completedFrames = 0;
  int failedFrames = 0;
  int skippedBusy = 0;
  int skippedUnavailable = 0;

  void record(DetectionTimings timings) {
    preprocess.addMicroseconds(timings.preprocessUs);
    inputCopy.addMicroseconds(timings.inputCopyUs);
    inference.addMicroseconds(timings.inferenceUs);
    postprocess.addMicroseconds(timings.postprocessUs);
    worker.addMicroseconds(timings.workerUs);
    endToEnd.addMicroseconds(timings.endToEndUs);
    transportAndScheduling.addMicroseconds(timings.transportAndSchedulingUs);
    latest = timings;
    completedFrames++;
  }

  DetectorPerformanceSnapshot get snapshot => DetectorPerformanceSnapshot(
    latest: latest,
    completedFrames: completedFrames,
    failedFrames: failedFrames,
    skippedBusy: skippedBusy,
    skippedUnavailable: skippedUnavailable,
    preprocess: preprocess.snapshot,
    inputCopy: inputCopy.snapshot,
    inference: inference.snapshot,
    postprocess: postprocess.snapshot,
    worker: worker.snapshot,
    endToEnd: endToEnd.snapshot,
    transportAndScheduling: transportAndScheduling.snapshot,
  );
}

class DetectorPerformanceSnapshot {
  const DetectorPerformanceSnapshot({
    required this.latest,
    required this.completedFrames,
    required this.failedFrames,
    required this.skippedBusy,
    required this.skippedUnavailable,
    required this.preprocess,
    required this.inputCopy,
    required this.inference,
    required this.postprocess,
    required this.worker,
    required this.endToEnd,
    required this.transportAndScheduling,
  });

  final DetectionTimings? latest;
  final int completedFrames;
  final int failedFrames;
  final int skippedBusy;
  final int skippedUnavailable;
  final LatencySummary preprocess;
  final LatencySummary inputCopy;
  final LatencySummary inference;
  final LatencySummary postprocess;
  final LatencySummary worker;
  final LatencySummary endToEnd;
  final LatencySummary transportAndScheduling;
}
