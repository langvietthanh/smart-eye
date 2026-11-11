import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/Recognition.dart';
import '../models/nav_command.dart';
import '../models/scene_info.dart';
import '../models/trip.dart';
import '../widgets/bounding_box_painter.dart';
import '../services/caption_builder.dart';
import '../services/command_parser.dart';
import '../services/camera_feed.dart';
import '../services/depth_alert.dart';
import '../services/depth_analysis.dart';
import '../services/depth_service.dart';
import '../services/feed_handle.dart';
import '../services/detector_service.dart';
import '../services/hazard_engine.dart';
import '../services/lidar_analysis.dart';
import '../services/lidar_feed.dart';
import '../services/history_service.dart';
import '../services/location_service.dart';
import '../services/navigation_guide.dart';
import '../services/object_tracker.dart';
import '../services/path_blockage.dart';
import '../services/proximity_pulse.dart';
import '../services/scene_freshness.dart';
import '../services/sight_monitor.dart';
import '../services/speech_manager.dart';
import '../services/ui_settings.dart';
import '../services/voice_command_service.dart';
import '../utils/image_utils.dart';
import '../utils/label_catalog.dart';
import 'history_screen.dart';

/// Field-test overlay (fps, LiDAR distance, thermal): always in debug builds,
/// and in release builds made with --dart-define=SMART_EYE_DIAGNOSTICS=true.
const bool _diagnosticsEnabled =
    !kReleaseMode || bool.fromEnvironment('SMART_EYE_DIAGNOSTICS');

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

  FeedHandle? _handle;
  bool _isDetecting = false;

  /// Chosen once services are ready: ARKit LiDAR when supported, else the
  /// camera plugin.
  FrameSource? _feed;
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
  final ValueNotifier<bool> _listening = ValueNotifier(false);
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
  final DepthService _depth = DepthService();
  final DepthWarning _depthWarning = DepthWarning();
  final StepWarning _stepWarning = StepWarning();

  /// iPhones with LiDAR measure metres directly; MiDaS is then not loaded.
  bool _useLidar = false;
  static const int _thermalCritical = 3; // ProcessInfo.ThermalState.critical
  final LidarDepthService _lidarDepth = LidarDepthService();
  final LidarWarning _lidarWarning = LidarWarning();

  /// Free/blocked lanes beside the centre obstacle, smoothed; [_sidesAtMs]
  /// is when their depth frame arrived (see [speakableSides]).
  final SideStability _sideStability = SideStability();
  static const _noSides = (left: SideState.unknown, right: SideState.unknown);
  ({SideState left, SideState right}) _sides = _noSides;
  int _sidesAtMs = -1;
  String _lidarStatus = '';
  int _lidarReadings = 0;
  static const int _minDepthIntervalMs = 300;
  int _lastDepthMs = -300;
  double? _boxProximity;
  ({double? proximity, int atMs})? _depthProximity;
  final ObjectTracker _tracker = ObjectTracker();
  final HazardEngine _engine = HazardEngine();
  late final SceneFreshness _sceneFreshness;
  final SpeechManager _speech = SpeechManager.instance;
  final HistoryService _history = HistoryService.instance;
  final LocationService _location = LocationService();
  final SightMonitor _sight = SightMonitor();
  Timer? _sightTimer;
  StreamSubscription<AccelerometerEvent>? _tilt;
  SightProblem? _sightProblem;
  final ProximityPulse _pulse = ProximityPulse(
    onPulse: (strong) =>
        strong ? HapticFeedback.heavyImpact() : HapticFeedback.mediumImpact(),
  );

  SceneAssessment _scene = SceneAssessment.empty;
  final ValueNotifier<SceneAssessment> _sceneNotifier = ValueNotifier(
    SceneAssessment.empty,
  );

  double _screenWidth = 0;
  double _screenHeight = 0;

  /// Góc cần xoay ảnh camera để AI thấy thế giới đứng thẳng — tự tính theo nền tảng, góc cảm biến
  /// và hướng điện thoại (xem [ImageUtils.frameRotation]). Xoay điện thoại thì preview, khung vật,
  /// 3 cột và ảnh đưa vào AI cùng xoay theo màn hình, không cần bấm nút.
  int get _rotationDegrees {
    final handle = _handle;
    if (handle == null) return 90;
    final auto = handle.frameRotation;
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
  final PathBlockage _blockage = PathBlockage();

  /// The trap line actually started for the current trap; caution and depth
  /// warnings stay silent only while this holds.
  bool _trapAnnounced = false;

  // Voice-command navigation: the guide is silent while a danger line was
  // spoken in the last [_navQuietAfterDanger], during a trap or a sight
  // problem, while the microphone is listening, and while an alert is
  // speaking or queued.
  final NavigationGuide _guide = NavigationGuide();
  final VoiceCommandService _voice = VoiceCommandService();
  static const Duration _navQuietAfterDanger = Duration(seconds: 2);
  static const int _lidarCenterMaxAgeMs = 500;
  DateTime _lastDangerAt = DateTime.fromMillisecondsSinceEpoch(0);
  LidarReading? _lidarCenter;
  int _lidarCenterAtMs = -1;

  /// A command is being listened for or dispatched; long presses are ignored.
  bool _commandBusy = false;

  /// The app itself cancelled the current listen (left the screen, camera
  /// stopped): its "no speech" result must not be answered.
  bool _listenCancelledByApp = false;

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
    // Dùng addPostFrameCallback để UI render trước, rồi mới init
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_disposed) unawaited(_initAll());
    });
  }

  void _onFeedError(Object error, StackTrace stack) {
    debugPrint('Lỗi camera: $error\n$stack');
    if (mounted && !_disposed && _wantsCamera) {
      setState(() {
        _hasError = true;
        _statusText = 'Lỗi camera: $error';
      });
    }
  }

  /// The camera backend; created once, before the camera is first opened.
  FrameSource _createFeed() {
    if (_useLidar) {
      return LidarFeed(
        onFrame: _onCameraFrame,
        onDepth: _onLidarDepth,
        onChanged: _cameraChanged,
        onError: _onFeedError,
      );
    }
    return CameraFeed(
      onFrame: (controller, image) =>
          _onCameraFrame(CameraControllerHandle(controller), image),
      onChanged: (controller) => _cameraChanged(
        controller == null ? null : CameraControllerHandle(controller),
      ),
      onError: _onFeedError,
    );
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

      // 2b. Depth is optional: without it walls/doors are not seen, say so.
      // LiDAR (iPhone Pro) gives metres and replaces the MiDaS estimate.
      if (_feed == null && Platform.isIOS && await LidarFeed.isSupported()) {
        try {
          await _lidarDepth.start();
          _useLidar = true;
          _sight.enableDepth(true);
        } catch (e, stack) {
          debugPrint('Không khởi động được LiDAR: $e\n$stack');
        }
        if (_disposed) return;
      }
      if (!_useLidar && !_depth.isLoaded) {
        try {
          await _depth.loadModel();
        } catch (e, stack) {
          debugPrint('Không tải được model độ sâu: $e\n$stack');
          _speech.say(
            'Không tải được cảm biến độ sâu. App sẽ không thấy tường và cửa.',
            SpeechPriority.caution,
          );
        }
        if (_disposed) return;
      }

      // 3. Cài đặt đã lưu + lịch sử chuyến đi + GPS (không bắt buộc)
      final settings = await UiSettings.load();
      if (_disposed) return;
      if (mounted) {
        setState(() {
          _speech.muted = settings.quiet;
          _autoDescribe = settings.autoDescribe;
        });
      }
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
      _feed ??= _createFeed();
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
        _lastDangerAt = DateTime.now();
        _speech.say('Không khởi động được Smart Eye.', SpeechPriority.danger);
      }
    }
  }

  void _cameraChanged(FeedHandle? controller) {
    _handle = controller;
    _invalidateScene();
    if (controller == null) _stopNavigation();
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
    _syncSight();
    _syncMockTimer();
    _syncDiagnostics();
    return _feed?.setActive(
          !_disposed && !_paused && !_isMockTest && _servicesReady,
        ) ??
        Future.value();
  }

  /// Watches for states where the app cannot see the path, so silence is
  /// never mistaken for a clear way ahead.
  void _syncSight() {
    if (_wantsCamera) {
      if (_sightTimer != null) return;
      _sight.start(DateTime.now());
      _tilt =
          accelerometerEventStream(
            samplingPeriod: SensorInterval.normalInterval,
          ).listen(
            (e) => _sight.onAccelerometer(e.x, e.y, e.z),
            onError: (Object e) => debugPrint('Không đọc được độ nghiêng: $e'),
            cancelOnError: true,
          );
      _sightTimer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _checkSight(),
      );
    } else {
      _sightTimer?.cancel();
      _sightTimer = null;
      unawaited(_tilt?.cancel());
      _tilt = null;
      _sight.stop();
      _sightProblem = null;
      _resetBlockage();
      _clearProximity();
    }
  }

  void _checkSight() {
    if (_disposed) return;
    final now = DateTime.now();
    final problem = _sight.check(now);
    final previous = _sightProblem;
    _sightProblem = problem;
    _evaluateBlockage(now);
    if (problem == null) {
      final recovery = sightRecoveryText(previous);
      if (recovery != null) {
        _speech.say(recovery, SpeechPriority.caution);
      }
      return;
    }
    if (problem.isBlind) _clearProximity();
    final message =
        problem == SightProblem.noDepth &&
            (_handle is LidarHandle) &&
            (_handle as LidarHandle).thermalState >= _thermalCritical
        ? 'Máy quá nóng, không đo được khoảng cách. Hãy để máy nguội.'
        : problem.message;
    final priority = problem.stopsUser
        ? SpeechPriority.danger
        : SpeechPriority.caution;
    // Speech cooldown per subject repeats the warning while the problem lasts.
    final subject = 'sight:${problem.name}';
    if (!_speech.canSay(priority, subject: subject)) return;
    if (problem.stopsUser) _lastDangerAt = now;
    _speech.say(
      message,
      priority,
      subject: subject,
      onStart: problem.stopsUser ? HapticFeedback.vibrate : null,
    );
  }

  void _resetBlockage() {
    _blockage.reset();
    _trapAnnounced = false;
  }

  /// Shared by the sight tick, each detection frame and each LiDAR scan:
  /// never evaluates while the latest sight check reports a problem.
  void _evaluateBlockage(DateTime now) {
    final problem = _sightProblem;
    if (problem == null) {
      _onBlockage(_blockage.evaluate(now));
    } else if (problem.isBlind) {
      _resetBlockage();
    } else {
      _blockage.interrupt();
    }
  }

  bool get _showsBothSidesBlocked =>
      _speech.showing.value?.text.endsWith(bothSidesBlocked) ?? false;

  /// Leaving a trap also clears its banner, so a quick re-trap is not mistaken
  /// for a line that was just spoken.
  void _endTrap() {
    _trapAnnounced = false;
    _speech.dropSubject('path:trapped');
    if (_showsBothSidesBlocked) _speech.showing.value = null;
  }

  void _onBlockage(PathEvent? event) {
    const subject = 'path:trapped';
    if (event == PathEvent.cleared) {
      _endTrap();
      _speech.say(
        'Đường đi thông thoáng.',
        SpeechPriority.caution,
        subject: 'path:cleared',
      );
      return;
    }
    if (event == PathEvent.opened) {
      // Facing a single obstacle with a side open: stop "turn slowly" and let
      // the next obstacle alert speak at once, with its verified side clause.
      _endTrap();
      _speech.dropSubject('depth:center');
      return;
    }
    if (!_blockage.trapped) return;
    if (!_trapAnnounced && _showsBothSidesBlocked) {
      // An obstacle alert is saying (or just said) both sides are blocked:
      // one alert, already logged by that alert.
      _trapAnnounced = true;
      return;
    }
    if (!_speech.canSay(SpeechPriority.danger, subject: subject)) return;
    _lastAlertAt = DateTime.now();
    _lastDangerAt = _lastAlertAt;
    if (_trapAnnounced) {
      _speech.say(
        'Vẫn bị chặn. Xoay người chậm.',
        SpeechPriority.danger,
        subject: subject,
      );
      return;
    }
    final log = _eventLogger(TripEventType.danger, trapAlertText);
    _speech.say(
      trapAlertText,
      SpeechPriority.danger,
      subject: subject,
      onStart: () {
        HapticFeedback.heavyImpact();
        // Logged once per trap, by the first trap line that actually starts.
        if (_trapAnnounced || !_blockage.trapped) return;
        _trapAnnounced = true;
        log();
      },
    );
  }

  void _syncDiagnostics() {
    if (!_diagnosticsEnabled || !_wantsCamera) {
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
      final b = _blockage.blocked(DateTime.now());
      _diagnostics.value =
          'AI ${fps.toStringAsFixed(1)} fps · nhận kết quả '
          '${latency.meanMs.toStringAsFixed(0)} ms (p95 ${latency.p95Ms.toStringAsFixed(0)})\n'
          'Model ${nativeMs.toStringAsFixed(0)} ms · RSS $memory'
          '${_useLidar ? '\nLiDAR $_lidarReadings Hz · $_lidarStatus' : ''}'
          '\nHướng: T${b[0] ? '✗' : '✓'} G${b[1] ? '✗' : '✓'} P${b[2] ? '✗' : '✓'}${_blockage.trapped ? ' · kẹt' : ''}';
      _lidarReadings = 0;
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
                (_isMockTest || _handle != null),
          ),
        )
        .catchError((Object e) => debugPrint('Không đổi được wakelock: $e'));
  }

  void _invalidateScene({bool duringBuild = false}) {
    _sceneFreshness.cancel();
    _resetBlockage();
    final generation = ++_frameGeneration;
    _tracker.reset();
    _speech.retainAlerts();
    _scene = SceneAssessment.empty;
    _clearProximity();
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

  void _clearProximity() {
    _boxProximity = null;
    _depthProximity = null;
    _depthWarning.reset();
    _stepWarning.reset();
    _lidarWarning.reset();
    _sideStability.reset();
    _sides = _noSides;
    _pulse.stop();
  }

  void _expireScene() {
    if (_disposed) return;
    // Camera frames may still arrive while AI is stalled. Do not let the last
    // accepted scene remain available to manual descriptions indefinitely.
    _tracker.reset();
    _speech.retainAlerts();
    _scene = SceneAssessment.empty;
    _clearProximity();
    _sceneNotifier.value = _scene;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    _foreground = state == AppLifecycleState.resumed;
    _invalidateScene();
    // Not on inactive: the microphone permission dialog and the notification
    // shade must not end a listen or a guiding session.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _stopNavigation();
    }
    if (!_foreground) {
      unawaited(_speech.stopAll());
      unawaited(_eventWrites.then((_) => _history.flush()));
    }
    unawaited(_syncCamera());
  }

  // ---------------------------------------------------------------------------
  // Pipeline
  // ---------------------------------------------------------------------------

  Future<void> _onCameraFrame(FeedHandle controller, CameraImage image) async {
    if (!_wantsCamera || controller != _handle || !_modelLoaded) return;
    final rotation = _rotationDegrees;
    final orientation = controller.deviceOrientation;
    if (_lastFrameRotation != null &&
        (_lastFrameRotation != rotation ||
            _lastFrameOrientation != orientation)) {
      _invalidateScene();
    }
    _lastFrameRotation = rotation;
    _lastFrameOrientation = orientation;
    _maybeRunDepth(controller, image, rotation);
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
          controller != _handle ||
          rotation != _rotationDegrees ||
          orientation != controller.deviceOrientation ||
          _frameClock.elapsedMilliseconds - now > _maxFrameAgeMs ||
          sw != _screenWidth ||
          sh != _screenHeight) {
        return;
      }
      _sight.onResult(DateTime.now(), _detector.lastMeanLuma);
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

  /// Depth runs in its own isolate at a lower rate than object detection.
  void _maybeRunDepth(FeedHandle controller, CameraImage image, int rotation) {
    if (!_depth.isLoaded || _depth.busy) return;
    final startedAt = _frameClock.elapsedMilliseconds;
    if (startedAt - _lastDepthMs < _minDepthIntervalMs) return;
    _lastDepthMs = startedAt;
    final generation = _frameGeneration;
    unawaited(
      _depth
          .analyze(image, rotation)
          .then((reading) {
            if (reading == null ||
                !_wantsCamera ||
                generation != _frameGeneration ||
                controller != _handle ||
                _frameClock.elapsedMilliseconds - startedAt > _maxFrameAgeMs) {
              return;
            }
            _onDepth(reading);
          })
          .catchError((Object e) => debugPrint('Lỗi xử lý độ sâu: $e')),
    );
  }

  void _onDepth(DepthReading reading) {
    // Dark frames and floor/ceiling views give meaningless depth; the sight
    // monitor already tells the user what to fix.
    if (_sight.check(DateTime.now()) != null) return;
    _depthProximity = (
      proximity: ProximityPulse.fromCloseness(reading.center),
      atMs: _frameClock.elapsedMilliseconds,
    );
    _updatePulse();
    final step = _stepWarning.update(reading.step);
    if (step != null) {
      // A step's raised surface can also read as "closer"; announce the step.
      _announceStep(step.kind, step.level);
      return;
    }
    _announceDepth(_depthWarning.update(reading.center));
  }

  /// LiDAR depth packets arrive ~10 Hz; analysis runs off the UI isolate and
  /// a packet that arrives while it is busy is dropped.
  void _onLidarDepth(LidarDepthFrame frame) {
    if (!_wantsCamera || _lidarDepth.busy) return;
    final handle = _handle;
    final generation = _frameGeneration;
    final startedAt = _frameClock.elapsedMilliseconds;
    unawaited(
      _lidarDepth
          .analyze(frame)
          .then((scan) {
            if (scan == null ||
                !_wantsCamera ||
                generation != _frameGeneration ||
                handle != _handle ||
                _frameClock.elapsedMilliseconds - startedAt > _maxFrameAgeMs) {
              return;
            }
            final now = DateTime.now();
            _lidarCenter = scan.center;
            _lidarCenterAtMs = _frameClock.elapsedMilliseconds;
            _blockage.onDepth(now, scan);
            _evaluateBlockage(now);
            _onLidarReading(
              scan.center,
              thermal: frame.thermalState,
              capturedAtMs: startedAt,
            );
          })
          .catchError((Object e) => debugPrint('Lỗi xử lý LiDAR: $e')),
    );
  }

  void _onLidarReading(
    LidarReading reading, {
    required int thermal,
    required int capturedAtMs,
  }) {
    final now = DateTime.now();
    _lidarReadings++;
    _sight.onDepth(now, known: reading is! LidarUnknown);
    final distance = reading is LidarObstacle ? reading.distance : null;
    _sides = _sideStability.update(reading);
    _sidesAtMs = capturedAtMs;
    _lidarStatus =
        '${switch (reading) {
          LidarObstacle(:final distance) => '${distance.toStringAsFixed(2)} m',
          LidarClear() => 'thông ≤ ${LidarAnalysis.maxForward.toStringAsFixed(0)} m',
          LidarUnknown() => 'không đo được',
        }} · trống: ${sideClause(_sides.left, _sides.right) ?? '—'}'
        ' · nhiệt $thermal';
    // Aiming and blind problems are announced by the sight monitor; a gap in
    // depth itself must not block the next reading from clearing it.
    final problem = _sight.check(now);
    if (problem != null && problem != SightProblem.noDepth) {
      // A badly aimed phone cannot vouch for either side.
      _sideStability.reset();
      _sides = _noSides;
      return;
    }
    _depthProximity = (
      proximity: ProximityPulse.fromDistance(distance),
      atMs: _frameClock.elapsedMilliseconds,
    );
    _updatePulse();
    _announceDepth(
      _lidarWarning.update(reading),
      metres: distance,
      sides: _speakableSides(),
    );
  }

  ({SideState left, SideState right}) _speakableSides() => _useLidar
      ? speakableSides(
          _sides,
          capturedAtMs: _sidesAtMs,
          nowMs: _frameClock.elapsedMilliseconds,
          trapped: _trapAnnounced || _blockage.trapped,
        )
      : _noSides;

  /// Speaks a class-agnostic depth warning unless the detector already names
  /// the obstacle with equal or higher urgency. [metres] and [sides] are
  /// known only with LiDAR.
  void _announceDepth(
    AlertLevel level, {
    double? metres,
    ({SideState left, SideState right}) sides = _noSides,
  }) {
    if (_trapAnnounced) return;
    final text = depthAlertText(
      depthLevel: level,
      detectorLevel: _scene.alert?.level,
      metres: metres,
      left: sides.left,
      right: sides.right,
    );
    if (text == null) return;
    final isDanger = level == AlertLevel.danger;
    final priority = isDanger ? SpeechPriority.danger : SpeechPriority.caution;
    const subject = 'depth:center';
    if (!_speech.canSay(priority, subject: subject)) return;
    _lastAlertAt = DateTime.now();
    if (isDanger) _lastDangerAt = _lastAlertAt;
    final log = _eventLogger(
      isDanger ? TripEventType.danger : TripEventType.caution,
      text,
    );
    _speech.say(
      text,
      priority,
      subject: subject,
      onStart: () {
        if (isDanger) HapticFeedback.heavyImpact();
        log();
      },
    );
  }

  void _announceStep(StepKind kind, AlertLevel level) {
    final isDanger = level == AlertLevel.danger;
    final priority = isDanger ? SpeechPriority.danger : SpeechPriority.caution;
    final subject = 'depth:step:${kind.name}';
    if (!_speech.canSay(priority, subject: subject)) return;
    _lastAlertAt = DateTime.now();
    if (isDanger) _lastDangerAt = _lastAlertAt;
    final text = switch (kind) {
      StepKind.down => 'Dừng lại! Có bậc xuống phía trước. Dò bằng gậy.',
      StepKind.up when isDanger =>
        'Dừng lại! Bậc lên ngay phía trước. Dò bằng gậy.',
      StepKind.up => 'Chú ý, phía trước có bậc lên. Đi chậm lại.',
    };
    final log = _eventLogger(
      isDanger ? TripEventType.danger : TripEventType.caution,
      text,
    );
    _speech.say(
      text,
      priority,
      subject: subject,
      onStart: () {
        // Double pulse: a step feels different from an obstacle.
        HapticFeedback.heavyImpact();
        unawaited(
          Future.delayed(
            const Duration(milliseconds: 180),
            HapticFeedback.heavyImpact,
          ),
        );
        log();
      },
    );
  }

  /// Pulses follow whichever source sees the closer obstacle; a depth reading
  /// older than the scene lifetime no longer counts.
  void _updatePulse() {
    final depth = _depthProximity;
    final depthValue =
        depth != null &&
            _frameClock.elapsedMilliseconds - depth.atMs <= _maxFrameAgeMs
        ? depth.proximity
        : null;
    final box = _boxProximity;
    _pulse.update(
      box == null
          ? depthValue
          : depthValue == null
          ? box
          : (box > depthValue ? box : depthValue),
    );
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
    final filtered = detections
        .where((d) => !ignoredLabels.contains(d.labelEn))
        .toList();
    final now = DateTime.now();
    final frame = Size(_screenWidth, _screenHeight);
    final tracks = _tracker.update(filtered, frame, capturedAt ?? now);
    // Just after arrival the target is right in front of the user: keep it
    // out of warnings so the arrival cue is not cut by a warning about it.
    final scene = _engine.assess(
      tracks,
      frame,
      targetTrackId:
          _guide.targetTrackId ??
          _guide.arrivedTrackId(tracks: tracks, now: now),
    );
    _blockage.onDetections(now, scene.columnLoad);
    _evaluateBlockage(now);
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
    _boxProximity = ProximityPulse.fromOccupancy(
      ProximityPulse.pathOccupancy(scene, frame),
    );
    _updatePulse();

    final alert = scene.alert;
    if (alert != null) {
      _handleAlert(alert, image, now, rotation);
    }

    // Keep updating after the guide ends until a cue held during quiet is out.
    if (_guide.isActive || _guide.hasPendingCue) {
      final cue = _guide.update(
        tracks: tracks,
        frame: frame,
        lidarCenter: _freshLidarCenter(),
        quiet: _navQuiet(now),
        sightLost: _sightProblem != null,
        now: now,
      );
      if (cue != null) _sayNav(cue);
    }

    if (_pendingDescribe) {
      _pendingDescribe = false;
      _describeFallback?.cancel();
      _describe(image, manual: true, rotation: rotation);
    } else if (_autoDescribe &&
        !_guide.isActive &&
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
    if (_trapAnnounced && !isDanger) return;
    final priority = isDanger ? SpeechPriority.danger : SpeechPriority.caution;
    if (!_speech.canSay(priority, subject: alert.subject)) {
      return; // Đã báo / đang chờ đọc
    }
    if (isDanger) _lastDangerAt = now;

    // LiDAR sides: only fresh, never during a trap, only for a centre object.
    final sides = _speakableSides();
    final text = withSideClause(
      alert.message,
      pos: alert.pos,
      left: sides.left,
      right: sides.right,
    );
    final jpeg = isDanger ? _captureMemory(image, rotation) : null;
    final log = _eventLogger(
      isDanger ? TripEventType.danger : TripEventType.caution,
      text,
      jpeg: jpeg,
    );
    _speech.say(
      text,
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
    if (_isMockTest || _handle == null || _paused) {
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

  /// Lệnh giọng nói "tóm tắt": đọc tóm tắt chuyến đi hiện tại.
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
    _saveSettings();
    _speech.say(
      _speech.muted
          ? 'Chế độ yên lặng. Chỉ báo khi nguy hiểm.'
          : 'Đã bật lại nhắc nhở.',
      SpeechPriority.description,
      force: true,
    );
  }

  /// Double tap / long press: listen for one spoken command and dispatch it.
  Future<void> _listenForCommand() async {
    if (_disposed || _commandBusy || _voice.isListening) return;
    _commandBusy = true;
    try {
      await _listenAndDispatch();
    } finally {
      _commandBusy = false;
    }
  }

  Future<void> _listenAndDispatch() async {
    HapticFeedback.mediumImpact();
    SystemSound.play(SystemSoundType.click);
    // Keep the app's own voice out of the microphone. An alert cut here must
    // be able to repeat on the next frame, so its cooldown is cleared.
    await _speech.stopAll();
    _speech.resetDedupe();
    if (_disposed || !_foreground || _paused) return;
    // Spoken cue, finished before the mic opens so it is not transcribed.
    await _speech
        .sayAndWait(
          'Đang nghe. Hãy nói đích đến.',
          SpeechPriority.guidance,
          subject: 'nav',
          force: true,
        )
        .timeout(const Duration(seconds: 3), onTimeout: () => false);
    if (_disposed || !_foreground || _paused) return;
    HapticFeedback.mediumImpact();
    _listening.value = true;
    _listenCancelledByApp = false;
    // Alerts are never muted, so the microphone may hear them: remember every
    // line spoken while listening and strip it from the transcript.
    final echoes = <String>[];
    void recordEcho() {
      final line = _speech.showing.value;
      if (line != null && _voice.isListening) echoes.add(line.text);
    }

    _speech.showing.addListener(recordEcho);
    final VoiceResult result;
    try {
      result = await _voice.listen();
    } finally {
      _speech.showing.removeListener(recordEcho);
      if (!_disposed) _listening.value = false;
    }
    HapticFeedback.lightImpact(); // Mic closed
    // Cancelled because the app left the screen: say nothing.
    if (_listenCancelledByApp || _disposed || !_foreground || _paused) return;
    var text = result.text;
    if (text != null && echoes.isNotEmpty) {
      text = CommandParser.stripEchoes(text, echoes);
      if (text.isEmpty) text = null;
    }
    if (text == null) {
      _sayNavLine(switch (result.error ?? VoiceError.noSpeech) {
        VoiceError.noPermission =>
          'Chưa có quyền dùng micro. Hãy cấp quyền trong cài đặt.',
        VoiceError.unavailable => 'Máy này chưa hỗ trợ lệnh giọng nói.',
        VoiceError.network => 'Cần mạng để nhận lệnh giọng nói.',
        VoiceError.noSpeech => 'Không nghe rõ. Chạm hai lần để nói lại.',
      });
      return;
    }
    final available = CommandParser.availableTargets(_detector.labels);
    switch (CommandParser.parse(text, available)) {
      case NavigateTo(:final labelsEn, :final nameVi):
        // A direct reply to the user: forced like the other command replies.
        _sayNavLine(_guide.start(labelsEn, nameVi, DateTime.now()).text);
        _eventLogger(TripEventType.navigation, 'Bắt đầu dẫn tới $nameVi')();
      case Describe():
        _requestDescribe();
      case Recap():
        _speakRecap();
      case Stop():
        // Speech was already stopped before listening.
        final cue = _guide.cancel();
        if (cue != null) _sayNav(cue);
      case UnsupportedTarget(:final nameVi):
        final names = CommandParser.suggestions(available);
        _sayNavLine(
          names.isEmpty
              ? 'Chưa nhận ra được $nameVi.'
              : 'Chưa nhận ra được $nameVi. Có thể tìm: ${names.join(', ')}.',
        );
      case Unknown():
        _sayNavLine(
          'Chưa hiểu lệnh. Có thể nói: đi đến ghế, xung quanh, tóm tắt, dừng.',
        );
    }
  }

  /// Speaks a guide cue; a session-ending cue is also logged to the trip.
  /// The newest cue wins: a 'nav' line still speaking or queued belongs to a
  /// state the guide has already left, and would make the manager reject this.
  void _sayNav(NavCue cue) {
    _speech.dropSubject('nav');
    _sayNavLine(cue.text, force: cue.force);
    if (cue.end != null) _eventLogger(TripEventType.navigation, cue.text)();
  }

  /// A forced line replaces any guidance still queued or speaking, since the
  /// manager drops a 'nav' line while another 'nav' line is pending.
  void _sayNavLine(String text, {bool force = true}) {
    if (force) _speech.dropSubject('nav');
    _speech.say(text, SpeechPriority.guidance, subject: 'nav', force: force);
  }

  bool _navQuiet(DateTime now) =>
      now.difference(_lastDangerAt) < _navQuietAfterDanger ||
      _trapAnnounced ||
      _blockage.trapped ||
      _sightProblem != null ||
      _voice.isListening ||
      _speech.alertActive;

  LidarReading? _freshLidarCenter() =>
      _useLidar &&
          _frameClock.elapsedMilliseconds - _lidarCenterAtMs <=
              _lidarCenterMaxAgeMs
      ? _lidarCenter
      : null;

  /// Camera stopped or app left the screen: end guiding silently.
  void _stopNavigation() {
    _guide.cancel(announce: false);
    if (_voice.isListening) _listenCancelledByApp = true;
    unawaited(_voice.cancel());
  }

  void _toggleAutoDescribe() {
    setState(() => _autoDescribe = !_autoDescribe);
    _saveSettings();
    _lastDescribeAt = DateTime.now();
    _speech.say(
      _autoDescribe
          ? 'Bật tự động mô tả, khoảng 45 giây một lần.'
          : 'Tắt tự động mô tả.',
      SpeechPriority.description,
      force: true,
    );
  }

  void _saveSettings() {
    UiSettings(quiet: _speech.muted, autoDescribe: _autoDescribe).save();
  }

  /// Mở lịch sử sẽ dừng camera và ngừng cảnh báo → chạm nhầm chỉ nghe hướng dẫn, giữ lâu mới mở.
  void _historyHint() {
    HapticFeedback.selectionClick();
    _speech.say(
      'Giữ lâu để mở lịch sử. Khi mở, app tạm ngừng cảnh báo.',
      SpeechPriority.description,
      force: true,
    );
  }

  Future<void> _openHistory() async {
    if (_paused || _disposed) return;
    HapticFeedback.selectionClick();
    _paused = true;
    _stopNavigation();
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
    _stopNavigation();
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
    _listening.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _mockTimer?.cancel();
    _describeFallback?.cancel();
    _stopNavigation();
    _syncSight();
    _invalidateScene();
    _sceneFreshness.dispose();
    _frameClock.stop();
    _sceneNotifier.dispose();
    _syncWakelock();
    unawaited(_feed?.dispose());
    unawaited(_disposeServices());
    super.dispose();
  }

  Future<void> _disposeServices() async {
    // Initialization may still be opening a trip or requesting GPS permission.
    // Let it observe _disposed before releasing the resources it owns.
    await _initialization;
    await _cleanup(_speech.stopAll);
    await _cleanup(_detector.dispose);
    await _cleanup(_depth.dispose);
    await _cleanup(_lidarDepth.dispose);
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
    final handle = _handle;
    final cameraReady = handle != null && handle.isInitialized;

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
                          unawaited(_feed?.retry());
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
          // Layer 1: Camera preview + cử chỉ (chạm 2 lần hoặc giữ lâu = nói lệnh / đích đến)
          Semantics(
            button: true,
            label:
                'Khung camera. Chạm hai lần để nói đích đến, ví dụ: đi đến ghế.',
            onTap: _listenForCommand,
            onLongPress: _listenForCommand,
            excludeSemantics: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: _listenForCommand,
              onLongPress: _listenForCommand,
              // Chế độ Test: KHÔNG hiện camera thật để không ai nhầm khung giả lập là kết quả nhận diện
              child: RepaintBoundary(
                child: cameraReady && !_isMockTest
                    ? RotatedBox(
                        quarterTurns: _debugRotationOffset ~/ 90,
                        child: _feed?.buildPreview(),
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
                          label: _speech.muted
                              ? 'Nhắc: yên lặng'
                              : 'Nhắc: đầy đủ',
                          semantics: _speech.muted
                              ? 'Chế độ yên lặng đang bật, chỉ báo nguy hiểm. Chạm để tắt.'
                              : 'Chế độ nhắc đầy đủ. Chạm để chuyển sang yên lặng.',
                          active: _speech.muted,
                          onTap: _toggleQuiet,
                        ),
                        const SizedBox(width: 8),
                        _toggleChip(
                          icon: Icons.record_voice_over,
                          label: _autoDescribe
                              ? 'Mô tả: tự động'
                              : 'Mô tả: khi hỏi',
                          semantics: _autoDescribe
                              ? 'Tự động mô tả đang bật. Chạm để tắt.'
                              : 'Tự động mô tả đang tắt. Chạm để bật.',
                          active: _autoDescribe,
                          onTap: _toggleAutoDescribe,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_diagnosticsEnabled && !_isMockTest)
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
                    ExcludeSemantics(
                      child: ValueListenableBuilder<bool>(
                        valueListenable: _listening,
                        builder: (_, on, _) => !on
                            ? const SizedBox.shrink()
                            : Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.blue.shade700,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Row(
                                  children: [
                                    Icon(Icons.mic, color: Colors.white),
                                    SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'Đang nghe… hãy nói đích đến',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 20,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
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
                          Icons.history,
                          'Lịch sử (giữ)',
                          'Lịch sử chuyến đi. Giữ lâu để mở. Khi mở, app tạm ngừng cảnh báo.',
                          _historyHint,
                          onLongPress: _openHistory,
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
    VoidCallback onTap, {
    VoidCallback? onLongPress,
  }) {
    return Expanded(
      child: Semantics(
        button: true,
        label: semantics,
        onTap: onTap,
        onLongPress: onLongPress,
        excludeSemantics: true,
        child: Material(
          color: Colors.yellow.shade600,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
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
