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
}
