import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/services/performance_metrics.dart';

void main() {
  test('empty latency window reports no samples and rejects invalid input', () {
    final window = RollingLatency();
    expect(window.snapshot.count, 0);
    expect(window.snapshot.meanMs, 0);
    expect(window.snapshot.p95Ms, 0);
    expect(() => RollingLatency(capacity: 0), throwsArgumentError);
    expect(() => window.addMicroseconds(-1), throwsArgumentError);
    expect(window.snapshot.count, 0);
  });

  test(
    'rolling percentiles discard expired spikes and keep microsecond precision',
    () {
      final window = RollingLatency(capacity: 4);
      for (final value in [100000, 1500, 2500, 3500]) {
        window.addMicroseconds(value);
      }
      final before = window.snapshot;
      expect(before.count, 4);
      expect(before.maxMs, 100);
      expect(before.p95Ms, 100);
      window.addMicroseconds(4500);
      final after = window.snapshot;
      expect(after.count, 4);
      expect(after.meanMs, 3);
      expect(after.p50Ms, 2.5);
      expect(after.p95Ms, 4.5);
      expect(after.maxMs, 4.5);
      expect(
        before.maxMs,
        100,
      ); // A snapshot stays independent of future samples.
    },
  );

  test(
    'p95 is the nearest ranked observation, not the single largest spike',
    () {
      final window = RollingLatency(capacity: 20);
      for (var i = 1; i <= 20; i++) {
        window.addMicroseconds(i * 1000);
      }
      expect(window.snapshot.p50Ms, 10);
      expect(window.snapshot.p95Ms, 19);
      expect(window.snapshot.meanMs, 10.5);
      expect(window.snapshot.maxMs, 20);
    },
  );

  test(
    'detector keeps bounded stage windows and lifetime completion counters',
    () {
      final performance = DetectorPerformance(capacity: 2);
      for (var i = 1; i <= 3; i++) {
        final timings = DetectionTimings(
          preprocessUs: i * 1000,
          inputCopyUs: i * 100,
          inferenceUs: i * 10000,
          postprocessUs: i * 2000,
          workerUs: i * 13100,
          endToEndUs: 0,
        );
        performance.record(timings.withEndToEnd(i * 15000));
      }
      performance.failedFrames++;
      performance.skippedBusy += 2;
      final stats = performance.snapshot;
      expect(stats.completedFrames, 3);
      expect(stats.failedFrames, 1);
      expect(stats.skippedBusy, 2);
      expect(stats.skippedUnavailable, 0);
      expect(stats.inference.count, 2);
      expect(stats.preprocess.meanMs, 2.5);
      expect(stats.inputCopy.meanMs, 0.25);
      expect(stats.inference.meanMs, 25);
      expect(stats.postprocess.meanMs, 5);
      expect(stats.worker.meanMs, 32.75);
      expect(stats.endToEnd.meanMs, 37.5);
      expect(stats.transportAndScheduling.meanMs, 4.75);
      expect(stats.latest!.endToEndUs, 45000);
      expect(stats.latest!.inferenceUs, 30000);
    },
  );
}
