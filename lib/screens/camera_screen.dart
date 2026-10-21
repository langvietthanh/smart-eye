import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/Recognition.dart';
import '../models/scene_info.dart';
import '../models/trip.dart';
import '../widgets/bounding_box_painter.dart';
import '../widgets/camera_feed_preview.dart';
import '../services/caption_builder.dart';
import '../services/camera_feed.dart';
import '../services/detector_service.dart';
import '../services/hazard_engine.dart';
import '../services/history_service.dart';
import '../services/location_service.dart';
import '../services/object_tracker.dart';
import '../services/scene_freshness.dart';
import '../services/speech_manager.dart';
import '../utils/image_utils.dart';
import 'history_screen.dart';

// A top-level callback prevents compute from capturing the widget, controller,
// detector or any other unsendable platform state.
Uint8List? _encodeMemory(({CameraImage image, int rotation}) request) =>
    ImageUtils.cameraImageToJpeg(
      request.image,
      rotationDegrees: request.rotation,
    );

/// Màn hình chính — pipeline mỗi frame:
/// F1 nhận diện (YOLOv8n) → CN5 tracker → F2 rules engine → CN10 Speech Manager → F4 lịch sử.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  /// F3 tự mô tả: tần suất rất thấp, và chỉ khi yên ổn (không có cảnh báo gần đây)
  static const Duration _autoDescribeEvery = Duration(seconds: 45);
  static const Duration _calmAfterAlert = Duration(seconds: 10);

  CameraController? _controller;
  bool _isDetecting = false;
  late final CameraFeed _cameraFeed;
  bool _foreground = true;
  bool _disposed = false;
  bool _servicesReady = false;
  Future<void>? _initialization;
  Future<void>? _locationStart;
  Future<void> _wakeOperations = Future.value();
  Future<void> _eventWrites = Future.value();
  TripSummary? _trip;
  bool _encodingMemory = false;
  Timer? _diagnosticTimer;
  final ValueNotifier<String> _diagnostics = ValueNotifier('');
  int _diagnosticFrames = 0;
  int _diagnosticAtMs = 0;
  int _frameGeneration = 0;
  int? _lastFrameRotation;
  DeviceOrientation? _lastFrameOrientation;

  // Trạng thái loading
  bool _modelLoaded = false;
  String _statusText = 'Đang khởi động...';
  bool _hasError = false;
  bool _greeted = false;

  final Stopwatch _frameClock = Stopwatch()..start();
  int _lastDetectionMs = -150;
  static const int _minDetectionIntervalMs = 150;
  static const int _maxFrameAgeMs = 750;
  final DateTime _frameEpoch = DateTime.now();

  final DetectorService _detector = DetectorService();
  final ObjectTracker _tracker = ObjectTracker();
  final HazardEngine _engine = HazardEngine();
  late final SceneFreshness _sceneFreshness;
  final SpeechManager _speech = SpeechManager.instance;
  final HistoryService _history = HistoryService.instance;
  final LocationService _location = LocationService();

  SceneAssessment _scene = SceneAssessment.empty;
  final ValueNotifier<SceneAssessment> _sceneNotifier = ValueNotifier(
    SceneAssessment.empty,
  );

  double _screenWidth = 0;
  double _screenHeight = 0;

  static const Map<DeviceOrientation, int> _deviceDegrees = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  /// Góc cần xoay ảnh camera để AI thấy thế giới đứng thẳng — tự tính theo nền tảng, góc cảm biến
  /// và hướng điện thoại (xem [ImageUtils.frameRotation]). Xoay điện thoại thì preview, khung vật,
  /// 3 cột và ảnh đưa vào AI cùng xoay theo màn hình, không cần bấm nút.
  int get _rotationDegrees {
    final controller = _controller;
    final camera = controller?.description;
    if (camera == null) return 90;
    final auto = ImageUtils.frameRotation(
      isIOS: Platform.isIOS,
      sensorOrientation: camera.sensorOrientation,
      deviceDegrees:
          _deviceDegrees[controller?.value.deviceOrientation ??
              DeviceOrientation.portraitUp]!,
      frontCamera: camera.lensDirection == CameraLensDirection.front,
    );
    return (auto + _debugRotationOffset) % 360;
  }

  /// Chỉ dùng khi debug: webcam của máy ảo Android hay báo sai góc cảm biến → hình bị nghiêng.
  /// Xoay bù cả preview lẫn ảnh vào AI để chúng luôn khớp nhau. Bản release luôn = 0.
  final int _debugRotationOffset = 0;

  bool _paused = false; // Tạm dừng nhận diện (khi mở lịch sử)
  bool _autoDescribe = false; // F3 mặc định on-demand
  bool _pendingDescribe =
      false; // Người dùng vừa yêu cầu mô tả → xử lý ở frame kế tiếp
  Timer? _describeFallback; // Không có frame nào tới kịp → vẫn trả lời
  DateTime _lastDescribeAt = DateTime.now();
  DateTime _lastAlertAt = DateTime.fromMillisecondsSinceEpoch(0);

  // Chế độ giả lập (không cần camera)
  bool _isMockTest = false;
  int _modeGeneration = 0;
  Timer? _mockTimer;
  DateTime _mockStart = DateTime.now();

  @override
  void initState() {
    super.initState();
    _sceneFreshness = SceneFreshness(
      onExpired: _expireScene,
      maxAge: const Duration(milliseconds: _maxFrameAgeMs),
    );
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _cameraFeed = CameraFeed(
      onFrame: _onCameraFrame,
      onChanged: _cameraChanged,
      onError: (error, stack) {
        debugPrint('Lỗi camera: $error\n$stack');
        if (mounted && !_disposed && _wantsCamera) {
          setState(() {
            _hasError = true;
            _statusText = 'Lỗi camera: $error';
          });
        }
      },
    );
    // Dùng addPostFrameCallback để UI render trước, rồi mới init
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_disposed) unawaited(_initAll());
    });
  }

  bool get _wantsCamera =>
      !_disposed && _foreground && !_paused && !_isMockTest && _servicesReady;

  Future<void> _initAll() {
    return _initialization ??= _initializeServices().whenComplete(
      () => _initialization = null,
    );
  }

  Future<void> _initializeServices() async {
    try {
      // 1. TTS + Speech Manager
      if (mounted) setState(() => _statusText = 'Khởi tạo giọng nói...');
      await _speech.init();
      if (_disposed) return;

      // 2. Load model
      if (!_modelLoaded) {
        if (mounted) setState(() => _statusText = 'Đang load model YOLOv8...');
        await _detector.loadModel();
        if (_disposed) return;
        if (mounted) setState(() => _modelLoaded = true);
      }

      // 3. Lịch sử chuyến đi + GPS (không bắt buộc)
      await _history.startTrip();
      _trip = _history.currentTrip;
      if (_disposed) return;
      _location.onDistance = (distance) {
        if (!_disposed && identical(_trip, _history.currentTrip)) {
          _history.updateDistance(distance);
        }
      };
      _locationStart ??= _location.start().then<void>((_) {});

      // 4. Khởi động camera
      _servicesReady = true;
      if (mounted) setState(() => _statusText = 'Đang mở camera...');
      await _syncCamera();
    } catch (e, stack) {
      debugPrint('Lỗi khởi tạo: $e\n$stack');
      if (mounted && !_disposed) {
        setState(() {
          _hasError = true;
          _statusText = 'Lỗi: $e';
        });
        _speech.say('Không khởi động được Smart Eye.', SpeechPriority.danger);
      }
    }
  }

  void _cameraChanged(CameraController? controller) {
    _controller = controller;
    _invalidateScene();
    if (mounted && !_disposed) {
      setState(() {
        if (controller != null) {
          _hasError = false;
          _statusText = 'Camera sẵn sàng!';
        }
      });
      if (controller != null && !_greeted) {
        _greeted = true;
        _speech.say(
          'Smart Eye đã sẵn sàng. Chạm hai lần vào màn hình để nghe xung quanh có gì.',
          SpeechPriority.description,
        );
      }
    }
    _syncWakelock();
  }

  Future<void> _syncCamera() {
    _syncWakelock();
    _syncMockTimer();
    _syncDiagnostics();
    return _cameraFeed.setActive(
      !_disposed && !_paused && !_isMockTest && _servicesReady,
    );
  }

  void _syncDiagnostics() {
    if (kReleaseMode || !_wantsCamera) {
      _diagnosticTimer?.cancel();
      _diagnosticTimer = null;
      return;
    }
    if (_diagnosticTimer != null) return;
    _diagnosticFrames = _detector.performance.completedFrames;
    _diagnosticAtMs = _frameClock.elapsedMilliseconds;
    _diagnosticTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = _frameClock.elapsedMilliseconds;
      final metrics = _detector.performance;
      final elapsed = now - _diagnosticAtMs;
      final fps = elapsed > 0
          ? (metrics.completedFrames - _diagnosticFrames) * 1000 / elapsed
          : 0.0;
      _diagnosticFrames = metrics.completedFrames;
      _diagnosticAtMs = now;
      final latency = metrics.endToEnd.snapshot;
      final nativeMs = (metrics.latest?.inferenceUs ?? 0) / 1000;
      var memory = 'n/a';
      try {
        memory =
            '${(ProcessInfo.currentRss / (1024 * 1024)).toStringAsFixed(1)} MiB';
      } catch (_) {
        // RSS is platform-dependent; never present buffer sizes as process RAM.
      }
      _diagnostics.value =
          'AI ${fps.toStringAsFixed(1)} fps · nhận kết quả '
          '${latency.meanMs.toStringAsFixed(0)} ms (p95 ${latency.p95Ms.toStringAsFixed(0)})\n'
          'Model ${nativeMs.toStringAsFixed(0)} ms · RSS $memory';
    });
  }

  void _syncMockTimer() {
    if (!_disposed && _foreground && !_paused && _isMockTest) {
      _mockTimer ??= Timer.periodic(
        const Duration(milliseconds: 150),
        (_) => _mockTick(),
      );
    } else {
      _mockTimer?.cancel();
      _mockTimer = null;
    }
  }

  void _syncWakelock() {
    _wakeOperations = _wakeOperations
        .then(
          (_) => WakelockPlus.toggle(
            enable:
                !_disposed &&
                _foreground &&
                !_paused &&
                (_isMockTest || _controller != null),
          ),
        )
        .catchError((Object e) => debugPrint('Không đổi được wakelock: $e'));
  }

  void _invalidateScene({bool duringBuild = false}) {
    _sceneFreshness.cancel();
    final generation = ++_frameGeneration;
    _tracker.reset();
    _speech.retainAlerts();
    _scene = SceneAssessment.empty;
    _lastFrameRotation = null;
    _lastFrameOrientation = null;
    _pendingDescribe = false;
    _describeFallback?.cancel();
    if (_disposed) return;
    if (duringBuild) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed && generation == _frameGeneration) {
          _sceneNotifier.value = _scene;
        }
      });
    } else {
      _sceneNotifier.value = _scene;
    }
  }

  void _expireScene() {
    if (_disposed) return;
    // Camera frames may still arrive while AI is stalled. Do not let the last
    // accepted scene remain available to manual descriptions indefinitely.
    _tracker.reset();
    _speech.retainAlerts();
    _scene = SceneAssessment.empty;
    _sceneNotifier.value = _scene;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    _foreground = state == AppLifecycleState.resumed;
    _invalidateScene();
    if (!_foreground) {
      unawaited(_speech.stopAll());
      unawaited(_eventWrites.then((_) => _history.flush()));
    }
    unawaited(_syncCamera());
  }

  // ---------------------------------------------------------------------------
  // Pipeline
  // ---------------------------------------------------------------------------

  Future<void> _onCameraFrame(
    CameraController controller,
    CameraImage image,
  ) async {
    if (!_wantsCamera || controller != _controller || !_modelLoaded) return;
    final rotation = _rotationDegrees;
    final orientation = controller.value.deviceOrientation;
    if (_lastFrameRotation != null &&
        (_lastFrameRotation != rotation ||
            _lastFrameOrientation != orientation)) {
      _invalidateScene();
    }
    _lastFrameRotation = rotation;
    _lastFrameOrientation = orientation;
    if (_isDetecting) return;

    final now = _frameClock.elapsedMilliseconds;
    if (now - _lastDetectionMs < _minDetectionIntervalMs) {
      return;
    }

    _isDetecting = true;
    _lastDetectionMs = now;
    final generation = _frameGeneration;
    final capturedAt = _frameEpoch.add(Duration(milliseconds: now));

    // finally: lỗi ở 1 frame không được làm kẹt cờ → nếu kẹt, nhận diện + nút "Xung quanh" chết hẳn
    try {
      final sw = _screenWidth;
      final sh = _screenHeight;
      if (sw == 0 || sh == 0) return;

      final results = await _detector.detect(
        image: image,
        screenWidth: sw,
        screenHeight: sh,
        rotationDegrees: rotation,
      );

      if (!_wantsCamera ||
          !mounted ||
          generation != _frameGeneration ||
          controller != _controller ||
          rotation != _rotationDegrees ||
          orientation != controller.value.deviceOrientation ||
          _frameClock.elapsedMilliseconds - now > _maxFrameAgeMs ||
          sw != _screenWidth ||
          sh != _screenHeight) {
        return;
      }
      _runPipeline(
        results,
        image: image,
        rotation: rotation,
        capturedAt: capturedAt,
        observationAge: Duration(
          milliseconds: _frameClock.elapsedMilliseconds - now,
        ),
      );
    } catch (e, stack) {
      debugPrint('Lỗi xử lý frame: $e\n$stack');
    } finally {
      _isDetecting = false;
    }
  }

  /// Retain the frame and its rotation together for asynchronous memory encoding.
  void _runPipeline(
    List<Recognition> detections, {
    CameraImage? image,
    int rotation = 0,
    DateTime? capturedAt,
    Duration observationAge = Duration.zero,
  }) {
    if (!_sceneFreshness.accept(observationAge)) return;
    final now = DateTime.now();
    final frame = Size(_screenWidth, _screenHeight);
    final tracks = _tracker.update(detections, frame, capturedAt ?? now);
    final scene = _engine.assess(tracks, frame);
    _speech.retainAlerts(
      subject: scene.alert?.subject,
      text: scene.alert?.message,
      priority: switch (scene.alert?.level) {
        AlertLevel.danger => SpeechPriority.danger,
        AlertLevel.caution => SpeechPriority.caution,
        _ => null,
      },
    );
    _scene = scene;
    _sceneNotifier.value = scene;

    final alert = scene.alert;
    if (alert != null) {
      _handleAlert(alert, image, now, rotation);
    }

    if (_pendingDescribe) {
      _pendingDescribe = false;
      _describeFallback?.cancel();
      _describe(image, manual: true, rotation: rotation);
    } else if (_autoDescribe &&
        now.difference(_lastDescribeAt) >= _autoDescribeEvery &&
        now.difference(_lastAlertAt) >= _calmAfterAlert &&
        !_speech.isBusy) {
      _describe(image, manual: false, rotation: rotation);
    }
  }

  void _handleAlert(
    HazardAlert alert,
    CameraImage? image,
    DateTime now,
    int rotation,
  ) {
    _lastAlertAt = now;
    final isDanger = alert.level == AlertLevel.danger;
    final priority = isDanger ? SpeechPriority.danger : SpeechPriority.caution;
    if (!_speech.canSay(priority, subject: alert.subject)) {
      return; // Đã báo / đang chờ đọc
    }

    final jpeg = isDanger ? _captureMemory(image, rotation) : null;
    final log = _eventLogger(
      isDanger ? TripEventType.danger : TripEventType.caution,
      alert.message,
      jpeg: jpeg,
    );
    _speech.say(
      alert.message,
      priority,
      subject: alert.subject,
      onStart: () {
        if (isDanger) HapticFeedback.heavyImpact();
        log();
      },
    );
  }

  void _describe(CameraImage? image, {required bool manual, int rotation = 0}) {
    _lastDescribeAt = DateTime.now();
    // Người dùng chủ động hỏi thì luôn trả lời, kể cả khi đang ở chế độ yên lặng
    if (!_speech.canSay(SpeechPriority.description, force: manual)) return;
    final text = CaptionBuilder.describeScene(_scene);
    final jpeg = _captureMemory(image, rotation);
    _speech.say(
      text,
      SpeechPriority.description,
      force: manual,
      onStart: _eventLogger(TripEventType.description, text, jpeg: jpeg),
    );
  }

  Future<Uint8List?>? _captureMemory(CameraImage? image, int rotation) {
    if (image == null || _encodingMemory || !_history.canCaptureMemory()) {
      return null;
    }
    _encodingMemory = true;
    return compute(_encodeMemory, (
          image: image,
          rotation: rotation,
        ), debugLabel: 'memory-jpeg')
        .catchError((Object error) {
          debugPrint('Không tạo được ảnh ghi nhớ: $error');
          return null;
        })
        .whenComplete(() => _encodingMemory = false);
  }

  VoidCallback _eventLogger(
    TripEventType type,
    String text, {
    Future<Uint8List?>? jpeg,
  }) {
    final trip = _trip;
    return () {
      if (_disposed || trip == null || !identical(trip, _history.currentTrip)) {
        return;
      }
      final location = _location.last;
      // Drain accepted speech events before flush/endTrip, even if their JPEG is
      // still encoding. A completed image can never attach to a different trip.
      _eventWrites = _eventWrites
          .then((_) async {
            final bytes = await jpeg;
            if (!identical(trip, _history.currentTrip)) return;
            _history.log(
              type,
              text,
              lat: location?.latitude,
              lng: location?.longitude,
              jpeg: bytes,
            );
          })
          .catchError(
            (Object error) => debugPrint('Không ghi được sự kiện: $error'),
          );
    };
  }

  // ---------------------------------------------------------------------------
  // Hành động của người dùng
  // ---------------------------------------------------------------------------

  void _requestDescribe() {
    HapticFeedback.selectionClick();
    if (_isMockTest || _controller == null || _paused) {
      _describe(null, manual: true);
      return;
    }
    // Làm ở frame kế tiếp để có ảnh ghi nhớ; nếu 0,8 giây không có frame thì trả lời luôn
    _pendingDescribe = true;
    _describeFallback?.cancel();
    _describeFallback = Timer(const Duration(milliseconds: 800), () {
      if (!mounted || !_pendingDescribe) return;
      _pendingDescribe = false;
      _describe(null, manual: true);
    });
  }

  void _speakRecap() {
    HapticFeedback.selectionClick();
    final trip = _history.currentTrip;
    if (trip == null) return;
    _speech.say(
      CaptionBuilder.recap(trip),
      SpeechPriority.description,
      force: true,
    );
  }

  void _toggleQuiet() {
    setState(() => _speech.muted = !_speech.muted);
    _speech.say(
      _speech.muted
          ? 'Chế độ yên lặng. Chỉ báo khi nguy hiểm.'
          : 'Đã bật lại nhắc nhở.',
      SpeechPriority.description,
      force: true,
    );
  }

  void _toggleAutoDescribe() {
    setState(() => _autoDescribe = !_autoDescribe);
    _lastDescribeAt = DateTime.now();
    _speech.say(
      _autoDescribe
          ? 'Bật tự động mô tả, khoảng 1 phút 1 lần.'
          : 'Tắt tự động mô tả.',
      SpeechPriority.description,
      force: true,
    );
  }

  Future<void> _openHistory() async {
    if (_paused || _disposed) return;
    HapticFeedback.selectionClick();
    _paused = true;
    _invalidateScene();
    await _syncCamera();
    await _speech.stopAll();
    await _eventWrites;
    await _history.flush();
    if (!mounted || _disposed) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const HistoryScreen()),
    );
    if (!mounted || _disposed) return;
    _invalidateScene();
    _paused = false;
    await _syncCamera();
  }

  // ---------------------------------------------------------------------------
  // Chế độ giả lập: xe máy lao tới → ghế chắn giữa, người bên trái
  // ---------------------------------------------------------------------------

  Future<void> _toggleMock() async {
    if (_disposed) return;
    setState(() {
      _isMockTest = !_isMockTest;
    });
    _invalidateScene();
    final modeGeneration = ++_modeGeneration;
    _mockTimer?.cancel();
    _mockTimer = null;
    if (_isMockTest) _mockStart = DateTime.now();
    await _syncCamera();
    await _speech.stopAll(); // Bỏ các câu của chế độ cũ đang chờ/đang đọc
    if (_disposed || modeGeneration != _modeGeneration) return;
    _speech.resetDedupe();
    _speech.say(
      _isMockTest
          ? 'Bật chế độ giả lập. Dữ liệu không phải từ camera.'
          : 'Tắt giả lập. Dùng camera thật.',
      SpeechPriority.description,
      force: true,
    );
  }

  void _mockTick() {
    if (!mounted || _disposed || !_foreground || !_isMockTest || _paused) {
      return;
    }
    final sw = _screenWidth;
    final sh = _screenHeight;
    final t =
        (DateTime.now().difference(_mockStart).inMilliseconds % 8000) / 1000.0;

    final List<Recognition> recs;
    if (t < 4) {
      // Xe máy phía trước, box cao dần 20% → 75% chiều cao khung
      final h = sh * (0.2 + 0.55 * (t / 4));
      final w = h * 0.6;
      recs = [
        Recognition(
          3,
          'xe máy',
          0.9,
          Rect.fromLTWH((sw - w) / 2, sh * 0.9 - h, w, h),
          labelEn: 'motorcycle',
        ),
      ];
    } else {
      // Ghế giữa khung hình, người sát bên trái → cảnh báo chậm lại.
      recs = [
        Recognition(
          56,
          'ghế',
          0.8,
          Rect.fromLTWH(sw * 0.38, sh * 0.45, sw * 0.26, sh * 0.38),
          labelEn: 'chair',
        ),
        Recognition(
          0,
          'người',
          0.85,
          Rect.fromLTWH(sw * 0.02, sh * 0.15, sw * 0.28, sh * 0.7),
          labelEn: 'person',
        ),
      ];
    }
    _runPipeline(recs);
  }

  @override
  void dispose() {
    _disposed = true;
    _diagnosticTimer?.cancel();
    _diagnostics.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _mockTimer?.cancel();
    _describeFallback?.cancel();
    _invalidateScene();
    _sceneFreshness.dispose();
    _frameClock.stop();
    _sceneNotifier.dispose();
    _syncWakelock();
    unawaited(_cameraFeed.dispose());
    unawaited(_disposeServices());
    super.dispose();
  }

  Future<void> _disposeServices() async {
    // Initialization may still be opening a trip or requesting GPS permission.
    // Let it observe _disposed before releasing the resources it owns.
    await _initialization;
    await _cleanup(_speech.stopAll);
    await _cleanup(_detector.dispose);
    await _locationStart;
    await _cleanup(_location.stop);
    await _eventWrites;
    if (_trip != null && identical(_trip, _history.currentTrip)) {
      await _cleanup(() async {
        await _history.endTrip();
      });
    }
  }

  Future<void> _cleanup(Future<void> Function() release) async {
    try {
      await release();
    } catch (error, stack) {
      debugPrint('Lỗi giải phóng tài nguyên: $error\n$stack');
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (_screenWidth != 0 &&
        (size.width != _screenWidth || size.height != _screenHeight)) {
      // Vừa xoay màn hình: toạ độ cũ không còn đúng → theo dõi lại từ đầu
      _invalidateScene(duringBuild: true);
    }
    _screenWidth = size.width;
    _screenHeight = size.height;
    final controller = _controller;
    final cameraReady = controller != null && controller.value.isInitialized;

    // Loading / Error screen
    if (!cameraReady && !_isMockTest) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_hasError)
                const Icon(Icons.error_outline, color: Colors.red, size: 60)
              else
                const CircularProgressIndicator(color: Colors.blue),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  _statusText,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                children: [
                  if (_hasError)
                    ElevatedButton(
                      onPressed: () {
                        setState(() {
                          _hasError = false;
                          _statusText = 'Đang thử lại...';
                        });
                        if (_servicesReady) {
                          unawaited(_cameraFeed.retry());
                        } else {
                          unawaited(_initAll());
                        }
                      },
                      child: const Text('Thử lại'),
                    ),
                  // Vẫn test được rules + giọng nói khi chưa có camera
                  if (_modelLoaded || _hasError)
                    OutlinedButton(
                      onPressed: _toggleMock,
                      child: const Text('🧪 Test UI'),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    // Main camera screen
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Layer 1: Camera preview + cử chỉ (chạm 2 lần = mô tả, giữ lâu = tóm tắt chuyến đi)
          Semantics(
            button: true,
            label: 'Khung camera. Chạm hai lần để nghe xung quanh có gì. Giữ lâu để nghe tóm tắt chuyến đi.',
            onTap: _requestDescribe,
            onLongPress: _speakRecap,
            excludeSemantics: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: _requestDescribe,
              onLongPress: _speakRecap,
              // Chế độ Test: KHÔNG hiện camera thật để không ai nhầm khung giả lập là kết quả nhận diện
              child: RepaintBoundary(
                child: cameraReady && !_isMockTest
                    ? RotatedBox(
                        quarterTurns: _debugRotationOffset ~/ 90,
                        child: CameraFeedPreview(feed: _cameraFeed),
                      )
                    : const ColoredBox(color: Color(0xFF1A1A2E)),
              ),
            ),
          ),

          if (_isMockTest)
            const IgnorePointer(
              child: Center(
                child: Text(
                  'CHẾ ĐỘ GIẢ LẬP\nKhung trên màn hình là dữ liệu giả,\nkhông phải từ camera',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white24,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),

          // Layer 2: Bounding boxes + free-space
          IgnorePointer(
            child: RepaintBoundary(
              child: ValueListenableBuilder<SceneAssessment>(
                valueListenable: _sceneNotifier,
                builder: (_, scene, _) {
                  // Layout changes invalidate immediately, before the deferred
                  // notifier update can clear boxes from the old orientation.
                  final visibleScene = identical(scene, _scene)
                      ? scene
                      : SceneAssessment.empty;
                  return CustomPaint(
                    painter: BoundingBoxPainter(
                      visibleScene,
                      alertSubject: visibleScene.alert?.subject,
                      alertLevel: visibleScene.alert?.level,
                    ),
                  );
                },
              ),
            ),
          ),

          // Layer 3: Trạng thái + câu vừa nói
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        _badge(
                          _isMockTest ? 'SMART EYE · TEST' : 'SMART EYE',
                          Colors.black54,
                        ),
                        const Spacer(),
                        _toggleChip(
                          icon: _speech.muted
                              ? Icons.volume_off
                              : Icons.volume_up,
                          label: _speech.muted ? 'Yên lặng' : 'Đầy đủ',
                          semantics: _speech.muted
                              ? 'Chế độ yên lặng đang bật, chỉ báo nguy hiểm. Chạm để tắt.'
                              : 'Chế độ nhắc đầy đủ. Chạm để chuyển sang yên lặng.',
                          active: _speech.muted,
                          onTap: _toggleQuiet,
                        ),
                        const SizedBox(width: 8),
                        _toggleChip(
                          icon: Icons.record_voice_over,
                          label: _autoDescribe ? 'Tự mô tả' : 'Mô tả khi hỏi',
                          semantics: _autoDescribe
                              ? 'Tự động mô tả đang bật. Chạm để tắt.'
                              : 'Tự động mô tả đang tắt. Chạm để bật.',
                          active: _autoDescribe,
                          onTap: _toggleAutoDescribe,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (!kReleaseMode && !_isMockTest)
                      ExcludeSemantics(
                        child: ValueListenableBuilder<String>(
                          valueListenable: _diagnostics,
                          builder: (_, text, _) => Text(
                            text,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                    if (!_speech.vietnameseAvailable) ...[
                      _voiceMissingBanner(),
                      const SizedBox(height: 8),
                    ],
                    ExcludeSemantics(
                      // Màu theo mức của CHÍNH câu đang nói — không lấy theo cảnh báo của frame hiện tại
                      child: ValueListenableBuilder<SpokenLine?>(
                        valueListenable: _speech.showing,
                        builder: (_, line, _) => line == null
                            ? const SizedBox.shrink()
                            : Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: switch (line.priority) {
                                    SpeechPriority.danger =>
                                      BoundingBoxPainter.colorOf(
                                        AlertLevel.danger,
                                      ),
                                    SpeechPriority.caution =>
                                      BoundingBoxPainter.colorOf(
                                        AlertLevel.caution,
                                      ),
                                    _ => Colors.black,
                                  }.withValues(alpha: 0.8),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  line.text,
                                  style: TextStyle(
                                    color:
                                        line.priority.index >=
                                            SpeechPriority.caution.index
                                        ? Colors.black
                                        : Colors.white,
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Layer 4: Nút debug + 3 nút lớn
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        _bigButton(
                          Icons.visibility,
                          'Xung quanh',
                          'Nghe xung quanh có gì',
                          _requestDescribe,
                        ),
                        const SizedBox(width: 8),
                        _bigButton(
                          Icons.summarize,
                          'Tóm tắt',
                          'Nghe tóm tắt chuyến đi hiện tại',
                          _speakRecap,
                        ),
                        const SizedBox(width: 8),
                        _bigButton(
                          Icons.history,
                          'Lịch sử',
                          'Mở lịch sử các chuyến đi',
                          _openHistory,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 13,
        ),
      ),
    );
  }

  Widget _toggleChip({
    required IconData icon,
    required String label,
    required String semantics,
    required bool active,
    required VoidCallback onTap,
  }) {
    return Semantics(
      button: true,
      label: semantics,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: active ? Colors.amber : Colors.black54,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: active ? Colors.black : Colors.white, size: 18),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: active ? Colors.black : Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Máy chưa có giọng tiếng Việt → TTS sẽ đọc bằng giọng mặc định, khó nghe → hướng dẫn cài
  Widget _voiceMissingBanner() {
    final path = Platform.isIOS
        ? 'Cài đặt → Trợ năng → Nội dung được đọc → Giọng nói → Tiếng Việt'
        : 'Cài đặt → Quản lý chung → Chuyển văn bản thành giọng nói → tải gói Tiếng Việt';
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.amber,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        'Máy chưa có giọng đọc tiếng Việt. Vào: $path',
        style: const TextStyle(
          color: Colors.black,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  /// Nút lớn, tương phản cao — dễ bấm khi không nhìn rõ, có nhãn cho TalkBack
  Widget _bigButton(
    IconData icon,
    String label,
    String semantics,
    VoidCallback onTap,
  ) {
    return Expanded(
      child: Semantics(
        button: true,
        label: semantics,
        excludeSemantics: true,
        child: Material(
          color: Colors.yellow.shade600,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              height: 76,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: Colors.black, size: 30),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
