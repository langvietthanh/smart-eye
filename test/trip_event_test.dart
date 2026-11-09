import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/models/trip.dart';

void main() {
  test('TripEvent.fromJson đọc sự kiện dẫn đường', () {
    final e = TripEvent.fromJson({
      't': '2026-11-09T10:00:00.000',
      'type': 'navigation',
      'text': 'Bắt đầu dẫn tới ghế',
    });
    expect(e.type, TripEventType.navigation);
    expect(e.type.vi, 'Dẫn đường');
    expect(e.text, 'Bắt đầu dẫn tới ghế');
    expect(TripEvent.fromJson(e.toJson()).type, TripEventType.navigation);
  });
}
