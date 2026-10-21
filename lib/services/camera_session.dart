/// Serializes camera initialization and disposal, including lifecycle changes
/// received while a platform operation is still in progress.
class CameraSession<T extends Object> {
  CameraSession({
    required this._open,
    required this._close,
    required this._onChanged,
    required this._onError,
    this._activate,
  });

  final Future<T> Function() _open;
  final Future<void> Function(T) _close;
  final void Function(T?) _onChanged;
  final void Function(Object, StackTrace) _onError;
  final Future<void> Function(T)? _activate;
  Future<void> _operations = Future.value();
  T? _resource;
  bool _active = false;
  bool _disposed = false;
  int _generation = 0;
  int _resourceGeneration = -1;

  Future<void> setActive(bool active) {
    if (_disposed) return _operations;
    if (_active != active) {
      _active = active;
      _generation++;
    }
    return _enqueue();
  }

  Future<void> dispose() {
    if (_disposed) return _operations;
    _disposed = true;
    _active = false;
    _generation++;
    return _enqueue();
  }

  /// Replace a failed/stalled camera even if the screen is still active.
  Future<void> restart() {
    if (_disposed) return _operations;
    _generation++;
    return _enqueue();
  }

  Future<void> _enqueue() {
    _operations = _operations
        .then((_) => _reconcile())
        .catchError((Object error, StackTrace stack) => _onError(error, stack));
    return _operations;
  }

  Future<void> _reconcile() async {
    if (!_active || (_resource != null && _resourceGeneration != _generation)) {
      final resource = _resource;
      _resource = null;
      if (resource != null) {
        _onChanged(null);
        await _close(resource);
      }
      if (!_active) return;
    }
    if (_resource != null) return;

    final generation = _generation;
    final resource = await _open();
    // A quick background/resume cycle still invalidates the old initialization.
    if (!_active || generation != _generation) {
      await _close(resource);
      return;
    }
    _resource = resource;
    _resourceGeneration = generation;
    _onChanged(resource);
    try {
      // Publish the initialized controller before subscribing to camera frames.
      // The very first frame therefore belongs to the current controller.
      if (_active && generation == _generation) await _activate?.call(resource);
    } catch (_) {
      _resource = null;
      _onChanged(null);
      await _close(resource);
      rethrow;
    }
  }
}
