import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/models/scene_info.dart';
import 'package:smart_eye/services/depth_analysis.dart';

const w = 60, h = 100;

/// Rows above the band: far wall 0.1; band: open floor 0.4; bottom: floor 1.0.
Float32List room({double centreBand = 0.4}) {
  final d = Float32List(w * h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final inCentre = x >= w ~/ 3 && x < 2 * w ~/ 3;
      d[y * w + x] = y < 35
          ? 0.1
          : y < 88
          ? (inCentre ? centreBand : 0.4)
          : 1.0;
    }
  }
  return d;
}

void main() {
  test('open path in front reads as far', () {
    final r = DepthAnalysis.analyze(room(), w, h)!;
    expect(r.center, closeTo(1 / 3, 1e-6));
    expect(r.left, closeTo(1 / 3, 1e-6));
    expect(r.center < DepthAnalysis.caution, isTrue);
  });

  test('obstacle as close as the floor ahead reads as near, centre only', () {
    final r = DepthAnalysis.analyze(room(centreBand: 0.95), w, h)!;
    expect(r.center, closeTo(0.85 / 0.9, 1e-6));
    expect(r.center >= DepthAnalysis.danger, isTrue);
    expect(r.left, closeTo(1 / 3, 1e-6));
    expect(r.right, closeTo(1 / 3, 1e-6));
  });

  test('uniform depth (wall filling the view) reads as near', () {
    final d = Float32List(w * h)..fillRange(0, w * h, 3.0);
    final r = DepthAnalysis.analyze(d, w, h)!;
    expect([r.left, r.center, r.right], [1.0, 1.0, 1.0]);
  });

  test('rejects maps that are too small or non-finite', () {
    expect(DepthAnalysis.analyze(Float32List(4), 2, 2), isNull);
    final d = room()..fillRange(0, w * h, double.nan);
    expect(DepthAnalysis.analyze(d, w, h), isNull);
  });

  test('warning needs two consecutive readings and resets on clear', () {
    final warn = DepthWarning();
    expect(warn.update(0.95), AlertLevel.info);
    expect(warn.update(0.95), AlertLevel.danger);
    expect(warn.update(0.8), AlertLevel.caution);
    expect(warn.update(0.3), AlertLevel.info);
    expect(warn.update(0.8), AlertLevel.info);
  });

  group('step detection (simulated pinhole camera, 1.3 m, 20° down)', () {
    const sh = 256, sw = 60;

    /// Inverse depth (scaled 3x + 0.5, as MiDaS has unknown scale/shift) per
    /// row for: flat floor, a step up/down at [dist] m, optionally a wall.
    Float32List view({
      String? step,
      double dist = 2,
      double delta = 0.18,
      double? wall,
      double pitch = 20,
      double noise = 0,
    }) {
      const cam = 1.3;
      final phi = pitch * pi / 180, c = cos(phi), s = sin(phi);
      final f = tan(30 * pi / 180);
      final rnd = Random(7);
      final d = Float32List(sw * sh);
      for (int r = 0; r < sh; r++) {
        final y = (r / sh - 0.5) * 2 * f;
        final down = y * c + s, forward = c - y * s;
        final horizontal = down > 0 ? cam * forward / down : double.infinity;
        double inv;
        if (step == null || horizontal < dist) {
          inv = max(down / cam, 0.01);
        } else if (step == 'up') {
          inv = dist * down / forward >= cam - delta
              ? forward / dist // riser
              : down / (cam - delta); // platform
        } else {
          inv = max(down / (cam + delta), 0.01); // lower floor beyond edge
        }
        if (wall != null) inv = max(inv, forward / wall);
        for (int x = 0; x < sw; x++) {
          d[r * sw + x] = 3 * inv + 0.5 + noise * (rnd.nextDouble() * 2 - 1);
        }
      }
      return d;
    }

    StepReading? detect(Float32List d) => DepthAnalysis.detectStep(d, sw, sh);

    test('flat floor, tilted or noisy, is not a step', () {
      expect(detect(view()), isNull);
      expect(detect(view(pitch: 40)), isNull);
      expect(detect(view(noise: 0.017)), isNull);
    });

    test('walls and large obstacles are not steps', () {
      for (final w in [1.5, 2.0, 3.0, 5.0]) {
        expect(detect(view(wall: w)), isNull, reason: 'wall $w m');
      }
    });

    test('18 cm step up is found at 1.5–3 m, even with a wall behind', () {
      for (final (dist, wall) in [(1.5, null), (2.0, null), (3.0, null),
          (2.0, 4.0), (1.5, 3.5), (2.0, 2.6)]) {
        final step = detect(view(step: 'up', dist: dist, wall: wall));
        expect(step?.kind, StepKind.up, reason: '$dist m, wall $wall');
      }
      expect(detect(view(step: 'up', dist: 1.5))!.near, isTrue);
      expect(detect(view(step: 'up', dist: 2.5))!.near, isFalse);
      expect(detect(view(step: 'up', noise: 0.017))?.kind, StepKind.up);
      expect(detect(view(step: 'up', pitch: 35))?.kind, StepKind.up);
    });

    test('step down / platform edge is found, even with a wall behind', () {
      for (final (dist, wall) in [(1.5, null), (2.0, null), (3.0, null),
          (2.0, 4.0), (1.5, 3.5)]) {
        final step = detect(view(step: 'down', dist: dist, wall: wall));
        expect(step?.kind, StepKind.down, reason: '$dist m, wall $wall');
      }
    });

    test('known limit: a 10 cm step is below the threshold', () {
      expect(detect(view(step: 'up', delta: 0.10)), isNull);
    });

    test('analyze carries the step reading', () {
      final reading = DepthAnalysis.analyze(view(step: 'up'), sw, sh)!;
      expect(reading.step?.kind, StepKind.up);
      expect(reading.center < DepthAnalysis.caution, isTrue);
    });
  });

  test('step warning: two agreeing readings; down always danger', () {
    final warn = StepWarning();
    const farUp = StepReading(StepKind.up, 0.6);
    const nearUp = StepReading(StepKind.up, 0.8);
    const down = StepReading(StepKind.down, 0.6);
    expect(warn.update(farUp), isNull);
    expect(warn.update(farUp)?.level, AlertLevel.caution);
    expect(warn.update(nearUp)?.level, AlertLevel.danger);
    expect(warn.update(down), isNull); // kind changed: restart
    expect(warn.update(down)?.level, AlertLevel.danger);
    expect(warn.update(null), isNull);
    expect(warn.update(down), isNull);
  });
}
