import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/services/scene_freshness.dart';

void main() {
  testWidgets(
    'scene expires even if the detector never returns another result',
    (tester) async {
      var expirations = 0;
      final freshness = SceneFreshness(onExpired: () => expirations++);
      expect(freshness.accept(Duration.zero), isTrue);
      await tester.pump(const Duration(milliseconds: 749));
      expect(expirations, 0);
      await tester.pump(const Duration(milliseconds: 1));
      expect(expirations, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(expirations, 1);
      freshness.dispose();
    },
  );

  testWidgets('inference age is deducted from the remaining scene lifetime', (
    tester,
  ) async {
    var expirations = 0;
    final freshness = SceneFreshness(onExpired: () => expirations++);
    expect(freshness.accept(const Duration(milliseconds: 600)), isTrue);
    await tester.pump(const Duration(milliseconds: 149));
    expect(expirations, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(expirations, 1);
    freshness.dispose();
  });

  testWidgets('new accepted observation replaces the previous expiry timer', (
    tester,
  ) async {
    var expirations = 0;
    final freshness = SceneFreshness(onExpired: () => expirations++);
    freshness.accept(Duration.zero);
    await tester.pump(const Duration(milliseconds: 400));
    freshness.accept(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 350));
    expect(expirations, 0);
    await tester.pump(const Duration(milliseconds: 100));
    expect(expirations, 1);
    freshness.dispose();
  });

  testWidgets(
    'stale observations immediately expire without refreshing the scene',
    (tester) async {
      for (final age in [
        const Duration(milliseconds: 750),
        const Duration(seconds: 2),
      ]) {
        var expirations = 0;
        final freshness = SceneFreshness(onExpired: () => expirations++);
        freshness.accept(Duration.zero);
        await tester.pump(const Duration(milliseconds: 100));
        expect(freshness.accept(age), isFalse);
        expect(expirations, 1);
        await tester.pump(const Duration(seconds: 1));
        expect(expirations, 1);
        freshness.dispose();
      }
    },
  );

  testWidgets('cancel removes pending expiry and allows a later observation', (
    tester,
  ) async {
    var expirations = 0;
    final freshness = SceneFreshness(onExpired: () => expirations++);
    freshness.accept(Duration.zero);
    freshness.cancel();
    await tester.pump(const Duration(seconds: 1));
    expect(expirations, 0);
    expect(freshness.accept(Duration.zero), isTrue);
    await tester.pump(const Duration(milliseconds: 750));
    expect(expirations, 1);
    freshness.dispose();
  });

  testWidgets(
    'dispose cancels pending expiry and ignores future observations',
    (tester) async {
      var expirations = 0;
      final freshness = SceneFreshness(onExpired: () => expirations++);
      freshness.accept(Duration.zero);
      freshness.dispose();
      expect(freshness.accept(Duration.zero), isFalse);
      expect(freshness.accept(const Duration(seconds: 1)), isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(expirations, 0);
    },
  );

  testWidgets('negative observation age cannot extend configured lifetime', (
    tester,
  ) async {
    var expirations = 0;
    final freshness = SceneFreshness(
      maxAge: const Duration(milliseconds: 200),
      onExpired: () => expirations++,
    );
    expect(freshness.accept(const Duration(milliseconds: -100)), isTrue);
    await tester.pump(const Duration(milliseconds: 200));
    expect(expirations, 1);
    freshness.dispose();
  });
}
