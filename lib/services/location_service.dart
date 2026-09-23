import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// GPS cho F4: gắn toạ độ vào sự kiện + cộng dồn quãng đường cho recap.
/// Không bắt buộc — thiếu quyền / tắt GPS thì app vẫn chạy bình thường.
class LocationService {
  /// Bỏ qua điểm có sai số lớn hơn mức này khi cộng quãng đường
  static const double _maxAccuracy = 30;

  /// Bỏ qua bước nhảy bất thường (GPS drift)
  static const double _maxJump = 100;

  StreamSubscription<Position>? _sub;
  Position? _lastGood;
  Position? last;
  double distanceMeters = 0;

  /// Gọi mỗi khi quãng đường thay đổi
  void Function(double meters)? onDistance;

  Future<bool> start() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        return false;
      }
      _sub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5),
      ).listen(_onPosition, onError: (Object e) => debugPrint('GPS lỗi: $e'));
      return true;
    } catch (e) {
      debugPrint('Không bật được GPS: $e');
      return false;
    }
  }

  void _onPosition(Position p) {
    last = p;
    if (p.accuracy > _maxAccuracy) return;
    final prev = _lastGood;
    if (prev != null) {
      final d = Geolocator.distanceBetween(prev.latitude, prev.longitude, p.latitude, p.longitude);
      if (d <= _maxJump) {
        distanceMeters += d;
        onDistance?.call(distanceMeters);
      }
    }
    _lastGood = p;
  }

  void reset() {
    distanceMeters = 0;
    _lastGood = null;
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }
}
