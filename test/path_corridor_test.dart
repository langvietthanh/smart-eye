import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/models/scene_info.dart';
import 'package:smart_eye/services/visual_proximity.dart';

const frame = Size(400, 800);

/// Box from normalised x [l]..[r], bottom at normalised row [bottom].
Rect box(double l, double r, double bottom, {double height = 0.3}) =>
    Rect.fromLTRB(
      l * frame.width,
      (bottom - height) * frame.height,
      r * frame.width,
      bottom * frame.height,
    );

void main() {
  final path = PathCorridor.typical;

  test('narrows towards the horizon like reversing guides', () {
    final (l1, r1) = path.span(1, 0.35);
    final (l6, r6) = path.span(0.6, 0.35);
    expect(r1 - l1, greaterThan(r6 - l6));
    expect(path.span(path.horizonY, 0.35), (0.5, 0.5));
    // Same x: in the way near the feet, beside the path farther up.
    expect(path.contains(box(0.62, 0.9, 1.0), frame), isTrue);
    expect(path.contains(box(0.62, 0.9, 0.6), frame), isFalse);
  });

  test('a table edge grazing the outer guide is not in the way', () {
    final (_, outer) = path.span(1, 0.35);
    final (_, core) = path.span(1, 0.25);
    final grazer = box((outer + core) / 2, 1.0, 1.0);
    expect(path.contains(grazer, frame), isFalse);
    final (left, right) = path.sides(grazer, frame);
    expect(left, 0);
    expect(right, greaterThan(0));
  });

  test('a thin pole dead ahead is in the way', () {
    expect(path.contains(box(0.49, 0.51, 0.9), frame), isTrue);
    expect(path.posOf(box(0.49, 0.51, 0.9), frame), HPos.center);
  });

  test('position is taken against the corridor core', () {
    expect(path.posOf(box(0.1, 0.4, 0.95), frame), HPos.left);
    expect(path.posOf(box(0.6, 0.9, 0.95), frame), HPos.right);
  });

  test('a level phone puts the horizon mid-frame, tilting down raises it', () {
    final level = PathCorridor.forPitch(0, portrait: true);
    final down = PathCorridor.forPitch(30, portrait: true);
    expect(level.horizonY, closeTo(0.5, 1e-9));
    expect(down.horizonY, lessThan(level.horizonY));
    // Level: a box low in the frame but off-centre is beside the path.
    expect(level.contains(box(0.65, 0.9, 0.75), frame), isFalse);
  });
}
