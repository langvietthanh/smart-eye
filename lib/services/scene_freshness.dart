import 'dart:async';

/// Expires a scene using the observation's remaining lifetime, independently of
/// whether the camera or detector produces another result.
class SceneFreshness {
  SceneFreshness({
    required this._onExpired,
    this.maxAge = const Duration(milliseconds: 750),
  }) : assert(maxAge > Duration.zero);

  final void Function() _onExpired;
  final Duration maxAge;
  Timer? _expiry;
  bool _disposed = false;

  /// Returns false for an already stale observation and expires the old scene
  /// immediately. Negative ages are clamped to zero and cannot extend lifetime
  /// beyond [maxAge]. A new accepted observation replaces the previous timer.
  bool accept(Duration observationAge) {
    if (_disposed) return false;
    cancel();
    if (observationAge >= maxAge) {
      _onExpired();
      return false;
    }
    final age = observationAge.isNegative ? Duration.zero : observationAge;
    _expiry = Timer(maxAge - age, () {
      _expiry = null;
      if (!_disposed) _onExpired();
    });
    return true;
  }

  /// Stops tracking the current scene without expiring it or closing this guard.
  void cancel() {
    _expiry?.cancel();
    _expiry = null;
  }

  void dispose() {
    _disposed = true;
    cancel();
  }
}
