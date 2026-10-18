import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';

import 'camera_session.dart';

/// Owns the camera's platform lifecycle independently from AI, GPS and speech.
/// Route visibility and OS foreground state must both permit capture.
class CameraFeed extends ValueNotifier<CameraController?>
    with WidgetsBindingObserver {
  CameraFeed({
    required this._onFrame,
    required this._onChanged,
    required this._onError,
    this.frameTimeout = const Duration(seconds: 4),
  }) : super(null) {
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _session = CameraSession(
      open: _open,
      activate: _start,
      close: _close,
      onChanged: _changed,
      onError: (error, stack) {
        if (_shouldRun && error is! _CameraOpenCancelled) {
          _onError(error, stack);
        }
      },
    );
  }

  final void Function(CameraController, CameraImage) _onFrame;
  final void Function(CameraController?) _onChanged;
  final void Function(Object, StackTrace) _onError;
  final Duration frameTimeout;
  late final CameraSession<CameraController> _session;
  Timer? _watchdog;
  bool _receivedFrame = false;
  int _automaticRestarts = 0;
  bool _active = false;
  bool _foreground = true;
  bool _failed = false;
  bool _disposed = false;
  Future<void>? _disposal;

  bool get _shouldRun => _active && _foreground && !_failed && !_disposed;

  Future<void> setActive(bool active) {
    if (_active != active) {
      _active = active;
      _failed = false;
      _automaticRestarts = 0;
    }
    return _session.setActive(_shouldRun);
  }

  Future<void> retry() {
    _failed = false;
    _automaticRestarts = 0;
    _session.setActive(_shouldRun);
    return _session.restart();
  }

  Future<CameraController> _open() async {
    // Enumerate again after settings/permission changes and every resume.
    final cameras = await availableCameras();
    if (!_shouldRun) throw const _CameraOpenCancelled();
    if (cameras.isEmpty) {
      throw CameraException('NoCamera', 'Không tìm thấy camera trên thiết bị');
    }
    final camera = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    final controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isIOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.yuv420,
    );
    try {
      await controller.initialize();
      return controller;
    } catch (_) {
      await _close(controller);
      rethrow;
    }
  }

  Future<void> _start(CameraController controller) async {
    if (!_shouldRun || value != controller) return;
    _receivedFrame = false;
    await controller.startImageStream((image) {
      if (!_shouldRun || value != controller) return;
      _receivedFrame = true;
      _automaticRestarts = 0;
      _onFrame(controller, image);
    });
    if (!_shouldRun || value != controller) return;
    _watchdog = Timer.periodic(frameTimeout, (_) {
      if (_shouldRun && !_receivedFrame) {
        _recover('Camera không trả hình ảnh. Hãy thử mở lại camera.');
      }
      _receivedFrame = false;
    });
  }

  Future<void> _close(CameraController controller) async {
    // camera 0.12.x dispose() does not cancel its image subscription. Cancel it
    // before releasing the native camera so an old stream cannot stop a new one.
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } finally {
      await controller.dispose();
    }
  }

  void _changed(CameraController? controller) {
    value?.removeListener(_cameraValueChanged);
    _watchdog?.cancel();
    _watchdog = null;
    if (_disposed) return;
    value = controller;
    controller?.addListener(_cameraValueChanged);
    _onChanged(controller);
  }

  void _cameraValueChanged() {
    final error = value?.value.errorDescription;
    if (error != null && _shouldRun) _recover(error);
  }

  void _recover(String message) {
    _watchdog?.cancel();
    _watchdog = null;
    if (!_shouldRun) return;
    if (_automaticRestarts++ == 0) {
      unawaited(_session.restart());
    } else {
      _failed = true;
      unawaited(_session.setActive(false));
      _onError(
        CameraException('CameraUnavailable', message),
        StackTrace.current,
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _failed = false;
      _automaticRestarts = 0;
    }
    unawaited(_session.setActive(_shouldRun));
  }

  @override
  Future<void> dispose() {
    if (_disposed) return _disposal ?? Future.value();
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _watchdog?.cancel();
    value?.removeListener(_cameraValueChanged);
    super.dispose();
    return _disposal = _session.dispose();
  }
}

class _CameraOpenCancelled implements Exception {
  const _CameraOpenCancelled();
}
