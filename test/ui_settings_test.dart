import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/services/ui_settings.dart';

void main() {
  test('round-trips both toggles', () {
    const s = UiSettings(quiet: true, autoDescribe: true);
    final back = UiSettings.fromJson(s.toJson());
    expect(back.quiet, isTrue);
    expect(back.autoDescribe, isTrue);
  });

  test('malformed data falls back to defaults', () {
    for (final json in [null, 'x', 42, {'quiet': 'yes'}]) {
      final s = UiSettings.fromJson(json);
      expect(s.quiet, isFalse);
      expect(s.autoDescribe, isFalse);
    }
  });
}
