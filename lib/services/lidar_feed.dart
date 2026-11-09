import 'dart:async';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart'
    show CameraImageData, CameraImageFormat, CameraImagePlane;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'feed_handle.dart';
import 'lidar_analysis.dart';
import 'processing_worker.dart';

/// An open ARKit session. Frames arrive in the sensor's landscape
/// orientation, so they rotate like an Android back camera (sensor 90°).
class LidarHandle implements FeedHandle {
  LidarHandle(this.textureId);

  final int textureId;

  /// ProcessInfo.ThermalState raw value from the latest frame.
  int thermalState = 0;
  DeviceOrientation _orientation = DeviceOrientation.portraitUp;

  static const _orientations = {
    'portraitUp': DeviceOrientation.portraitUp,
    'portraitDown': DeviceOrientation.portraitDown,
    'landscapeLeft': DeviceOrientation.landscapeLeft,
    'landscapeRight': DeviceOrientation.landscapeRight,
  };

  /// True when the orientation changed.
  bool updateOrientation(Object? name) {
    final next = _orientations[name];
    if (next == null || next == _orientation) return false;
    _orientation = next;
    return true;
  }

  @override
  DeviceOrientation get deviceOrientation => _orientation;
  @override
  bool get isInitialized => true;
  @override
  int get frameRotation => (90 - deviceDegrees[_orientation]! + 360) % 360;
}

/// ARKit-backed replacement for [CameraFeed] on iPhones with LiDAR: same
/// lifecycle contract (route + foreground gating, watchdog, one automatic
/// restart), plus metric depth frames.
class LidarFeed extends ValueNotifier<FeedHandle?>
    with WidgetsBindingObserver
    implements FrameSource {
  LidarFeed({
    required this._onFrame,
    required this._onDepth,
    required this._onChanged,
    required this._onError,
    this.frameTimeout = const Duration(seconds: 4),
    this._methods = defaultMethods,
    this._events = defaultEvents,
  }) : super(null) {
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  static const defaultMethods = MethodChannel('smart_eye/lidar');
  static const defaultEvents = EventChannel('smart_eye/lidar/events');

  /// ARKit's raw pixel format of the delivered frames (420f).
  static const rawFormat = 875704422;

  static Future<bool> isSupported([
    MethodChannel methods = defaultMethods,
  ]) async {
    try {
      return await methods.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  final void Function(FeedHandle, CameraImage) _onFrame;
  final void Function(LidarDepthFrame) _onDepth;
  final void Function(FeedHandle?) _onChanged;
  final void Function(Object, StackTrace) _onError;
  final MethodChannel _methods;
  final EventChannel _events;
  final Duration frameTimeout;

  Future<void> _operations = Future.value();
  StreamSubscription<dynamic>? _subscription;
  Timer? _watchdog;
  bool _running = false;
  bool _receivedFrame = false;
  bool _interrupted = false;
  int _automaticRestarts = 0;
  bool _active = false;
  bool _foreground = true;
  bool _failed = false;
  bool _disposed = false;
  Future<void>? _disposal;

  bool get _shouldRun => _active && _foreground && !_failed && !_disposed;

  @override
  Widget buildPreview() => RepaintBoundary(
    child: ValueListenableBuilder<FeedHandle?>(
      valueListenable: this,
      builder: (_, handle, _) => handle is LidarHandle
          ? _LidarPreview(handle: handle, key: ObjectKey(handle))
          : const ColoredBox(color: Color(0xFF000000)),
    ),
  );

  @override
  Future<void> setActive(bool active) {
    if (_active != active) {
      _active = active;
      _failed = false;
      _automaticRestarts = 0;
    }
    return _sync();
  }

  @override
  Future<void> retry() {
    _failed = false;
    _automaticRestarts = 0;
    return _restart();
  }

  Future<void> _sync() => _enqueue(_apply);

  Future<void> _restart() => _enqueue(() async {
    await _stopSession();
    await _apply();
  });

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _operations.then((_) => operation());
    _operations = next.catchError((Object _) {});
    return _operations;
  }

  Future<void> _apply() async {
    if (_shouldRun && !_running) {
      await _startSession();
    } else if (!_shouldRun && _running) {
      await _stopSession();
    }
  }

  Future<void> _startSession() async {
    _subscription ??= _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object error) => _recover('$error'),
    );
    try {
      final id = await _methods.invokeMethod<int>('start');
      if (id == null) {
        throw PlatformException(
          code: 'NoTexture',
          message: 'Không mở được camera',
        );
      }
      if (!_shouldRun) {
        await _methods.invokeMethod<void>('stop');
        return;
      }
      _running = true;
      _interrupted = false;
      _publish(LidarHandle(id));
      _startWatchdog();
    } catch (error, stack) {
      if (_shouldRun) {
        _failed = true;
        _onError(error, stack);
      }
    }
  }

  Future<void> _stopSession() async {
    if (!_running) return;
    _running = false;
    _watchdog?.cancel();
    _watchdog = null;
    _publish(null);
    try {
      await _methods.invokeMethod<void>('stop');
    } catch (error) {
      debugPrint('Không dừng được ARKit: $error');
    }
  }

  void _publish(FeedHandle? handle) {
    if (_disposed) return;
    value = handle;
    _onChanged(handle);
  }

  void _startWatchdog() {
    _receivedFrame = false;
    _watchdog?.cancel();
    _watchdog = Timer.periodic(frameTimeout, (_) {
      if (_shouldRun && _running && !_receivedFrame && !_interrupted) {
        _recover('Camera không trả hình ảnh. Hãy thử mở lại camera.');
      }
      _receivedFrame = false;
    });
  }

  void _recover(String message) {
    if (!_shouldRun) return;
    if (_automaticRestarts++ == 0) {
      unawaited(_restart());
    } else {
      _failed = true;
      unawaited(_sync());
      _onError(
        PlatformException(code: 'CameraUnavailable', message: message),
        StackTrace.current,
      );
    }
  }

  void _onEvent(dynamic event) {
    if (_disposed || event is! Map) return;
    final handle = value;
    if (!_running || handle is! LidarHandle) return;
    switch (event['type']) {
      case 'frame':
        _receivedFrame = true;
        _automaticRestarts = 0;
        if (handle.updateOrientation(event['orientation'])) notifyListeners();
        final thermal = event['thermal'];
        if (thermal is int) handle.thermalState = thermal;
        final image = frameImage(event);
        try {
          if (image != null) _onFrame(handle, image);
        } finally {
          unawaited(
            _methods
                .invokeMethod<void>('ackFrame')
                .catchError((Object e) => debugPrint('ackFrame: $e')),
          );
        }
      case 'depth':
        final frame = depthFrame(event);
        if (frame != null) _onDepth(frame);
      case 'interrupted':
        _interrupted = true;
      case 'resumed':
        _interrupted = false;
        _receivedFrame = true;
      case 'error':
        _recover('${event['message'] ?? 'Lỗi ARKit'}');
    }
  }

  /// Two-plane 420f frame as a camera-plugin image, or null if malformed.
  @visibleForTesting
  static CameraImage? frameImage(Map<dynamic, dynamic> e) {
    final width = e['width'], height = e['height'];
    final y = e['y'], uv = e['uv'];
    final yRow = e['yRow'], uvRow = e['uvRow'];
    if (width is! int ||
        height is! int ||
        y is! Uint8List ||
        uv is! Uint8List ||
        yRow is! int ||
        uvRow is! int ||
        y.length < yRow * height ||
        uv.length < uvRow * (height ~/ 2)) {
      return null;
    }
    return CameraImage.fromPlatformInterface(
      CameraImageData(
        format: const CameraImageFormat(
          ImageFormatGroup.yuv420,
          raw: rawFormat,
        ),
        width: width,
        height: height,
        planes: [
          CameraImagePlane(
            bytes: y,
            bytesPerRow: yRow,
            bytesPerPixel: 1,
            width: width,
            height: height,
          ),
          CameraImagePlane(
            bytes: uv,
            bytesPerRow: uvRow,
            bytesPerPixel: 2,
            width: width ~/ 2,
            height: height ~/ 2,
          ),
        ],
      ),
    );
  }

  @visibleForTesting
  static LidarDepthFrame? depthFrame(Map<dynamic, dynamic> e) {
    final width = e['width'], height = e['height'];
    final depth = e['depth'], confidence = e['confidence'];
    final up = e['up'];
    double? number(Object? v) => v is num ? v.toDouble() : null;
    final fx = number(e['fx']), fy = number(e['fy']);
    final cx = number(e['cx']), cy = number(e['cy']);
    if (width is! int ||
        height is! int ||
        depth is! Uint8List ||
        confidence is! Uint8List ||
        up is! List ||
        up.length != 3 ||
        fx == null ||
        fy == null ||
        cx == null ||
        cy == null ||
        depth.lengthInBytes < width * height * 4 ||
        confidence.length < width * height) {
      return null;
    }
    final ups = up.map(number).toList();
    if (ups.contains(null)) return null;
    // Standard-codec byte arrays need not be 4-byte aligned.
    final aligned = depth.offsetInBytes % 4 == 0
        ? depth
        : Uint8List.fromList(depth);
    return LidarDepthFrame(
      width: width,
      height: height,
      depth: aligned.buffer.asFloat32List(
        aligned.offsetInBytes,
        width * height,
      ),
      confidence: confidence,
      fx: fx,
      fy: fy,
      cx: cx,
      cy: cy,
      upX: ups[0]!,
      upY: ups[1]!,
      upZ: ups[2]!,
      trackingAvailable: e['tracking'] != false,
      thermalState: e['thermal'] is int ? e['thermal'] as int : 0,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _failed = false;
      _automaticRestarts = 0;
    }
    unawaited(_sync());
  }

  @override
  Future<void> dispose() {
    if (_disposed) return _disposal ?? Future.value();
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _watchdog?.cancel();
    final subscription = _subscription;
    _subscription = null;
    super.dispose();
    return _disposal = _enqueue(() async {
      if (_running) {
        _running = false;
        try {
          await _methods.invokeMethod<void>('stop');
        } catch (_) {}
      }
      unawaited(subscription?.cancel());
    });
  }
}

class _LidarPreview extends StatelessWidget {
  const _LidarPreview({super.key, required this.handle});
  final LidarHandle handle;

  @override
  Widget build(BuildContext context) {
    final turns = handle.frameRotation ~/ 90;
    return Center(
      child: AspectRatio(
        aspectRatio: turns.isOdd ? 3 / 4 : 4 / 3,
        child: RotatedBox(
          quarterTurns: turns,
          child: Texture(textureId: handle.textureId),
        ),
      ),
    );
  }
}

/// Runs [LidarAnalysis] in a background isolate; its floor estimate lives
/// there for the worker's lifetime.
class LidarDepthService {
  ProcessingWorker<LidarDepthFrame, LidarScan>? _worker;
  Future<void>? _starting;
  bool _busy = false;
  bool _disposed = false;

  bool get busy => _busy;

  Future<void> start() =>
      _starting ??= ProcessingWorker.start(_LidarProcessor())
          .then((worker) async {
            if (_disposed) {
              await worker.close();
            } else {
              _worker = worker;
            }
          });

  /// Null while starting, busy or disposed: callers drop the frame.
  Future<LidarScan?> analyze(LidarDepthFrame frame) async {
    final worker = _worker;
    if (_disposed || worker == null || _busy) return null;
    _busy = true;
    try {
      final scan = await worker.run(frame);
      return _disposed ? null : scan;
    } finally {
      _busy = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    try {
      await _starting;
    } catch (_) {}
    final worker = _worker;
    _worker = null;
    await worker?.close();
  }
}

class _LidarProcessor implements IsolateProcessor<LidarDepthFrame, LidarScan> {
  final _analysis = LidarAnalysis();

  @override
  void initialize() {}

  @override
  LidarScan process(LidarDepthFrame frame) => _analysis.analyzeScan(frame);

  @override
  void dispose() {}
}
