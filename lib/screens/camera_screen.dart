import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../main.dart';
import '../models/Recognition.dart';
import '../models/scene_info.dart';
import '../models/trip.dart';
import '../widgets/bounding_box_painter.dart';
import '../services/caption_builder.dart';
import '../services/detector_service.dart';
import '../services/hazard_engine.dart';
import '../services/history_service.dart';
import '../services/location_service.dart';
import '../services/object_tracker.dart';
import '../services/speech_manager.dart';
import '../services/detection/detector_worker.dart';
import '../services/detection/frame_data.dart';
import '../services/detection/scan_scheduler.dart';
import '../utils/image_utils.dart';
import 'history_screen.dart';

/// Màn hình chính — pipeline mỗi frame:
/// F1 nhận diện (YOLOv8n) → CN5 tracker → F2 rules engine → CN10 Speech Manager → F4 lịch sử.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  /// F3 tự mô tả: tần suất rất thấp, và chỉ khi yên ổn (không có cảnh báo gần đây)
  static const Duration _autoDescribeEvery = Duration(seconds: 45);
  static const Duration _calmAfterAlert = Duration(seconds: 10);

  CameraController? _controller;
  final ScanScheduler _scheduler = ScanScheduler();

  /// Frame mốc khi đang ở chế độ tiết kiệm — so với từng frame mới để phát hiện chuyển động
  Uint8List? _idleSignature;

  /// Thời điểm các lần quét trong 3 giây gần nhất — tính số lần quét/giây cho dòng chẩn đoán
  final List<DateTime> _scanStats = [];

  /// 10 lần quét gần nhất — dòng chẩn đoán hiển thị số TRUNG BÌNH để không nhảy liên tục
  final List<DetectionBatch> _recentBatches = [];

  /// Dòng chẩn đoán đã tính sẵn — chỉ làm mới 2 lần/giây cho dễ đọc
  String _diagText = '';
  DateTime _diagUpdatedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Cách chạy AI người dùng chọn ở nút debug: auto / cpu / gpu (iOS: metal)
  String _backendChoice = 'auto';
  bool _switchingBackend = false;

  // Trạng thái loading
  bool _modelLoaded = false;
  String _statusText = 'Đang khởi động...';
  bool _hasError = false;
  bool _greeted = false;

  final DetectorService _detector = DetectorService();
  final ObjectTracker _tracker = ObjectTracker();
  final HazardEngine _engine = HazardEngine();
  final SpeechManager _speech = SpeechManager.instance;
  final HistoryService _history = HistoryService.instance;
  final LocationService _location = LocationService();

  SceneAssessment _scene = SceneAssessment.empty;

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
    final camera = controller?.description ?? (cameras.isNotEmpty ? cameras.first : null);
    if (camera == null) return 90;
    final auto = ImageUtils.frameRotation(
      isIOS: Platform.isIOS,
      sensorOrientation: camera.sensorOrientation,
      deviceDegrees: _deviceDegrees[controller?.value.deviceOrientation ?? DeviceOrientation.portraitUp]!,
      frontCamera: camera.lensDirection == CameraLensDirection.front,
    );
    return (auto + _debugRotationOffset) % 360;
  }

  /// Chỉ dùng khi debug: webcam của máy ảo Android hay báo sai góc cảm biến → hình bị nghiêng.
  /// Xoay bù cả preview lẫn ảnh vào AI để chúng luôn khớp nhau. Bản release luôn = 0.
  int _debugRotationOffset = 0;

  bool _paused = false;          // Tạm dừng nhận diện (khi mở lịch sử)
  bool _autoDescribe = false;    // F3 mặc định on-demand
  bool _pendingDescribe = false; // Người dùng vừa yêu cầu mô tả → xử lý ở frame kế tiếp
  Timer? _describeFallback;      // Không có frame nào tới kịp → vẫn trả lời
  DateTime _lastDescribeAt = DateTime.now();
  DateTime _lastAlertAt = DateTime.fromMillisecondsSinceEpoch(0);

  // Chế độ giả lập (không cần camera)
  bool _isMockTest = false;
  Timer? _mockTimer;
  DateTime _mockStart = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Dùng addPostFrameCallback để UI render trước, rồi mới init
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initAll();
    });
  }

  Future<void> _initAll() async {
    try {
      // 1. TTS + Speech Manager
      if (mounted) setState(() => _statusText = 'Khởi tạo giọng nói...');
      await _speech.init();

      // 2. Load model
      if (!_modelLoaded) {
        if (mounted) setState(() => _statusText = 'Đang load model YOLOv8...');
        await _detector.loadModel();
        if (mounted) setState(() => _modelLoaded = true);
      }

      // 3. Lịch sử chuyến đi + GPS (không bắt buộc)
      await _history.startTrip();
      _location.onDistance = _history.updateDistance;
      unawaited(_location.start());

      // 4. Khởi động camera
      if (mounted) setState(() => _statusText = 'Đang mở camera...');
      await _initializeCamera();
    } catch (e, stack) {
      debugPrint('Lỗi khởi tạo: $e\n$stack');
      if (mounted) {
        setState(() {
          _hasError = true;
          _statusText = 'Lỗi: $e';
        });
        _speech.say('Không khởi động được Smart Eye.', SpeechPriority.danger);
      }
    }
  }

  Future<void> _initializeCamera() async {
    if (cameras.isEmpty) {
      setState(() => _statusText = 'Không tìm thấy camera trên thiết bị');
      return;
    }

    final controller = CameraController(
      cameras.first,
      ResolutionPreset.medium,
      enableAudio: false,
      // iOS: BGRA 1 lớp (định dạng camera plugin khuyên dùng cho AI trên iOS); Android: YUV_420_888
      imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420,
    );
    _controller = controller;

    try {
      await controller.initialize();
      if (!mounted || _controller != controller) return;
      setState(() => _statusText = 'Camera sẵn sàng!');
      await controller.startImageStream(_onCameraFrame);
      // Màn hình tự khoá = app dừng = mất cảnh báo → giữ sáng suốt lúc đang quét
      unawaited(WakelockPlus.enable());
      if (!_greeted) {
        _greeted = true;
        _speech.say(
          'Smart Eye đã sẵn sàng. Chạm hai lần vào màn hình để nghe xung quanh có gì.',
          SpeechPriority.description,
        );
      }
    } on CameraException catch (e) {
      debugPrint('Lỗi camera: ${e.code} - ${e.description}');
      if (mounted) {
        setState(() {
          _hasError = true;
          _statusText = 'Lỗi camera: ${e.description}';
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (state == AppLifecycleState.paused) _history.flush();

    // Camera phải được giải phóng khi app rời màn hình, mở lại khi quay về.
    // (Lỗi cũ: kiểm tra `_controller == null` trước → khi quay về luôn thoát sớm, camera không bao giờ mở lại
    // sau khi kéo thanh thông báo / hiện hộp thoại xin quyền.)
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      if (controller != null && controller.value.isInitialized) {
        _controller = null;
        controller.dispose();
      }
    } else if (state == AppLifecycleState.resumed && _modelLoaded && controller == null && !_hasError) {
      _scheduler.reset();
      _tracker.reset();
      _initializeCamera();
    }
  }

  // ---------------------------------------------------------------------------
  // Pipeline
  // ---------------------------------------------------------------------------

  /// Camera gửi ~30 frame/giây; bộ điều phối quyết định frame nào được quét và quét vùng nào.
  /// Luồng UI chỉ copy frame (~1 ms), phần nặng chạy ở isolate AI.
  void _onCameraFrame(CameraImage image) {
    if (!_modelLoaded || _isMockTest || _paused || _screenWidth == 0) return;
    if (_scheduler.mode == ScanMode.idle) _watchForMotion(image);
    if (!_scheduler.shouldScan(DateTime.now())) {
      return;
    }
    _idleSignature = null;
    _scan(image, _rotationDegrees);
  }

  /// Chế độ tiết kiệm: so độ sáng 16×16 điểm của từng frame (~0,1 ms, không copy ảnh) với frame mốc —
  /// có chuyển động (VD bàn tay, xe lao vào khung) là quét ngay, không phải chờ hết 1 giây.
  void _watchForMotion(CameraImage image) {
    final frame = FrameData(
      width: image.width,
      height: image.height,
      planes: [for (final p in image.planes) PlaneData(p.bytes, p.bytesPerRow, p.bytesPerPixel)],
    );
    final signature = ImageUtils.lumaSignature(frame, rotationDegrees: _rotationDegrees);
    if (signature == null) return;
    final reference = _idleSignature;
    if (reference == null) {
      _idleSignature = signature;
    } else if (ImageUtils.signatureDiff(signature, reference) > ScanScheduler.stillThreshold * 1.5) {
      _scheduler.wakeUp();
    }
  }

  Future<void> _scan(CameraImage image, int rotation) async {
    try {
      // detect() copy frame ngay (trước lần await đầu tiên) → an toàn dù buffer camera bị tái sử dụng
      final batch = await _detector.detect(image, rotation: rotation);
      if (!mounted || _paused || _isMockTest) {
        _scheduler.onFailed();
        return;
      }
      final screen = Size(_screenWidth, _screenHeight);
      _runPipeline(_detector.toRecognitions(batch, screen), fromCamera: true);
      final now = DateTime.now();
      _scanStats
        ..add(now)
        ..removeWhere((t) => now.difference(t) > const Duration(seconds: 3));
      _recentBatches.add(batch);
      if (_recentBatches.length > 10) _recentBatches.removeAt(0);

      _scheduler.onResult(
        now,
        motion: batch.motion,
        hazard: _scene.alert != null || _scene.objects.any((o) => o.approaching),
        relevantObjects: _scene.objects.any((o) => o.isRelevant),
      );
    } catch (e, stack) {
      debugPrint('Lỗi quét: $e\n$stack');
      _scheduler.onFailed();
    }
  }

  /// [fromCamera]: kết quả từ camera thật (có ảnh ghi nhớ) — false khi giả lập.
  void _runPipeline(List<Recognition> detections, {bool fromCamera = false}) {
    final now = DateTime.now();
    final frame = Size(_screenWidth, _screenHeight);
    final tracks = _tracker.update(detections, frame, now);
    final scene = _engine.assess(tracks, frame);
    setState(() => _scene = scene);

    final alert = scene.alert;
    if (alert != null) {
      _handleAlert(alert, now, fromCamera: fromCamera);
    }

    if (_pendingDescribe) {
      _pendingDescribe = false;
      _describeFallback?.cancel();
      _describe(manual: true, fromCamera: fromCamera);
    } else if (_autoDescribe &&
        now.difference(_lastDescribeAt) >= _autoDescribeEvery &&
        now.difference(_lastAlertAt) >= _calmAfterAlert &&
        !_speech.isBusy) {
      _describe(manual: false, fromCamera: fromCamera);
    }
  }

  void _handleAlert(HazardAlert alert, DateTime now, {required bool fromCamera}) {
    _lastAlertAt = now;
    final isDanger = alert.level == AlertLevel.danger;
    final priority = isDanger ? SpeechPriority.danger : SpeechPriority.caution;
    if (!_speech.canSay(priority, subject: alert.subject)) return; // Đã báo / đang chờ đọc

    // Xin ảnh của frame vừa quét ngay bây giờ (trước lần quét kế tiếp), ghi lịch sử khi câu thực sự được đọc
    final photo = isDanger && fromCamera ? _capturePhoto() : null;
    _speech.say(alert.message, priority, subject: alert.subject, onStart: () {
      if (isDanger) HapticFeedback.heavyImpact();
      _logEvent(isDanger ? TripEventType.danger : TripEventType.caution, alert.message, photo: photo);
    });
  }

  void _describe({required bool manual, bool fromCamera = false}) {
    _lastDescribeAt = DateTime.now();
    // Người dùng chủ động hỏi thì luôn trả lời, kể cả khi đang ở chế độ yên lặng
    if (!_speech.canSay(SpeechPriority.description, force: manual)) return;
    final text = CaptionBuilder.describeScene(_scene);
    final photo = fromCamera ? _capturePhoto() : null;
    _speech.say(text, SpeechPriority.description, force: manual,
        onStart: () => _logEvent(TripEventType.description, text, photo: photo));
  }

  /// Ảnh ghi nhớ (CN12) của frame vừa quét — isolate AI mã hoá JPEG, không chiếm luồng UI
  Future<Uint8List?>? _capturePhoto() => _history.canCaptureMemory() ? _detector.thumbnail() : null;

  Future<void> _logEvent(TripEventType type, String text, {Future<Uint8List?>? photo}) async {
    Uint8List? jpeg;
    try {
      jpeg = await photo;
    } catch (_) {
      // Không có ảnh vẫn ghi sự kiện
    }
    _history.log(type, text, lat: _location.last?.latitude, lng: _location.last?.longitude, jpeg: jpeg);
  }

  // ---------------------------------------------------------------------------
  // Hành động của người dùng
  // ---------------------------------------------------------------------------

  void _requestDescribe() {
    HapticFeedback.selectionClick();
    if (_isMockTest || _controller == null || _paused) {
      _describe(manual: true);
      return;
    }
    _scheduler.wakeUp(); // Quét ngay frame kế tiếp, kể cả khi đang ở chế độ tiết kiệm
    // Làm ở frame kế tiếp để có ảnh ghi nhớ; nếu 0,8 giây không có frame thì trả lời luôn
    _pendingDescribe = true;
    _describeFallback?.cancel();
    _describeFallback = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted || !_pendingDescribe) return;
      _pendingDescribe = false;
      _describe(manual: true);
    });
  }

  void _speakRecap() {
    HapticFeedback.selectionClick();
    final trip = _history.currentTrip;
    if (trip == null) return;
    _speech.say(CaptionBuilder.recap(trip), SpeechPriority.description, force: true);
  }

  void _toggleQuiet() {
    setState(() => _speech.muted = !_speech.muted);
    _speech.say(
      _speech.muted ? 'Chế độ yên lặng. Chỉ báo khi nguy hiểm.' : 'Đã bật lại nhắc nhở.',
      SpeechPriority.description,
      force: true,
    );
  }

  void _toggleAutoDescribe() {
    setState(() => _autoDescribe = !_autoDescribe);
    _lastDescribeAt = DateTime.now();
    _speech.say(
      _autoDescribe ? 'Bật tự động mô tả, khoảng 1 phút 1 lần.' : 'Tắt tự động mô tả.',
      SpeechPriority.description,
      force: true,
    );
  }

  Future<void> _openHistory() async {
    HapticFeedback.selectionClick();
    _paused = true;
    await _speech.stopAll();
    await _history.flush();
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const HistoryScreen()));
    _tracker.reset();
    _scheduler.reset();
    _paused = false;
  }

  // ---------------------------------------------------------------------------
  // Chế độ giả lập: xe máy lao tới → ghế chắn giữa, người bên trái
  // ---------------------------------------------------------------------------

  Future<void> _toggleMock() async {
    setState(() {
      _isMockTest = !_isMockTest;
      _scene = SceneAssessment.empty;
    });
    _tracker.reset();
    _mockTimer?.cancel();
    await _speech.stopAll(); // Bỏ các câu của chế độ cũ đang chờ/đang đọc
    _speech.resetDedupe();
    _speech.say(
      _isMockTest ? 'Bật chế độ giả lập. Dữ liệu không phải từ camera.' : 'Tắt giả lập. Dùng camera thật.',
      SpeechPriority.description,
      force: true,
    );
    if (_isMockTest) {
      _mockStart = DateTime.now();
      _mockTimer = Timer.periodic(const Duration(milliseconds: 150), (_) => _mockTick());
    }
  }

  void _mockTick() {
    if (!mounted || _paused) return;
    final sw = _screenWidth;
    final sh = _screenHeight;
    final t = (DateTime.now().difference(_mockStart).inMilliseconds % 8000) / 1000.0;

    final List<Recognition> recs;
    if (t < 4) {
      // Xe máy phía trước, box cao dần 20% → 75% chiều cao khung
      final h = sh * (0.2 + 0.55 * (t / 4));
      final w = h * 0.6;
      recs = [
        Recognition(3, 'xe máy', 0.9, Rect.fromLTWH((sw - w) / 2, sh * 0.9 - h, w, h), labelEn: 'motorcycle'),
      ];
    } else {
      // Ghế giữa (cách ~2m), người sát bên trái → nên đi chếch sang phải
      recs = [
        Recognition(56, 'ghế', 0.8, Rect.fromLTWH(sw * 0.38, sh * 0.45, sw * 0.26, sh * 0.38), labelEn: 'chair'),
        Recognition(0, 'người', 0.85, Rect.fromLTWH(sw * 0.02, sh * 0.15, sw * 0.28, sh * 0.7), labelEn: 'person'),
      ];
    }
    _runPipeline(recs);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mockTimer?.cancel();
    _describeFallback?.cancel();
    unawaited(WakelockPlus.disable());
    _controller?.dispose();
    _detector.dispose();
    _speech.stopAll();
    _location.stop();
    _history.endTrip();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (_screenWidth != 0 && (size.width != _screenWidth || size.height != _screenHeight)) {
      // Vừa xoay màn hình: toạ độ cũ không còn đúng → theo dõi lại từ đầu
      _tracker.reset();
      _scene = SceneAssessment.empty;
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
                        _initAll();
                      },
                      child: const Text('Thử lại'),
                    ),
                  // Vẫn test được rules + giọng nói khi chưa có camera
                  if (_modelLoaded || _hasError)
                    OutlinedButton(onPressed: _toggleMock, child: const Text('🧪 Test UI')),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final alert = _scene.alert;

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
              child: cameraReady && !_isMockTest
                  ? RotatedBox(quarterTurns: _debugRotationOffset ~/ 90, child: CameraPreview(controller))
                  : const ColoredBox(color: Color(0xFF1A1A2E)),
            ),
          ),

          if (_isMockTest)
            const IgnorePointer(
              child: Center(
                child: Text(
                  'CHẾ ĐỘ GIẢ LẬP\nKhung trên màn hình là dữ liệu giả,\nkhông phải từ camera',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white24, fontSize: 22, fontWeight: FontWeight.bold),
                ),
              ),
            ),

          // Layer 2: Bounding boxes + free-space
          IgnorePointer(
            child: CustomPaint(
              painter: BoundingBoxPainter(_scene, alertSubject: alert?.subject, alertLevel: alert?.level),
            ),
          ),

          // Layer 3: Trạng thái + câu vừa nói
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        _badge(_isMockTest ? 'SMART EYE · TEST' : 'SMART EYE', Colors.black54),
                        const Spacer(),
                        _toggleChip(
                          icon: _speech.muted ? Icons.volume_off : Icons.volume_up,
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
                                    SpeechPriority.danger => BoundingBoxPainter.colorOf(AlertLevel.danger),
                                    SpeechPriority.caution => BoundingBoxPainter.colorOf(AlertLevel.caution),
                                    _ => Colors.black,
                                  }
                                      .withValues(alpha: 0.8),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  line.text,
                                  style: TextStyle(
                                    color: line.priority.index >= SpeechPriority.caution.index
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
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _diagnostics,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      alignment: WrapAlignment.end,
                      children: [
                        if (!kReleaseMode) ...[
                          _smallButton(
                            icon: Icons.memory,
                            label: _switchingBackend ? 'AI: đang đổi...' : 'AI: ${_backendLabel(_backendChoice)}',
                            color: Colors.indigo.withValues(alpha: 0.8),
                            onTap: _switchingBackend ? () {} : _cycleBackend,
                          ),
                        ],
                        if (kDebugMode)
                          _smallButton(
                            icon: Icons.screen_rotation,
                            label: 'Bù xoay $_debugRotationOffset°',
                            color: Colors.blueGrey.withValues(alpha: 0.8),
                            onTap: () => setState(() {
                              _debugRotationOffset = (_debugRotationOffset + 90) % 360;
                              _tracker.reset();
                              _scene = SceneAssessment.empty;
                            }),
                          ),
                        _smallButton(
                          icon: Icons.bug_report,
                          label: _isMockTest ? 'Tắt Test' : '🧪 Test UI',
                          color: _isMockTest ? Colors.orange : Colors.grey.withValues(alpha: 0.8),
                          onTap: _toggleMock,
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _bigButton(Icons.visibility, 'Xung quanh', 'Nghe xung quanh có gì', _requestDescribe),
                        const SizedBox(width: 8),
                        _bigButton(Icons.summarize, 'Tóm tắt', 'Nghe tóm tắt chuyến đi hiện tại', _speakRecap),
                        const SizedBox(width: 8),
                        _bigButton(Icons.history, 'Lịch sử', 'Mở lịch sử các chuyến đi', _openHistory),
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
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
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

  /// Dòng chẩn đoán: cách chạy AI, thời gian từng bước, số lần quét/giây, chế độ, điểm cao nhất
  /// Số liệu là TRUNG BÌNH 10 lần quét gần nhất, làm mới 2 lần/giây → đọc được, không nhấp nháy.
  String get _diagnostics {
    if (_isMockTest) return 'Giả lập · ${_scene.objects.length} vật';
    if (_switchingBackend) return 'Đang đổi cách chạy AI...';
    final now = DateTime.now();
    if (now.difference(_diagUpdatedAt) < const Duration(milliseconds: 500) && _diagText.isNotEmpty) return _diagText;
    _diagUpdatedAt = now;

    final batches = _recentBatches;
    if (batches.isEmpty) return _diagText = _modelLoaded ? 'Đang chờ frame...' : 'Đang nạp AI...';
    double avg(double Function(DetectionBatch) f) => batches.map(f).reduce((a, b) => a + b) / batches.length;
    final last = batches.last;
    final rate = _scanStats.length / 3;
    return _diagText = '${last.backend.toUpperCase()}${last.verifying ? ' (đối chiếu CPU)' : ''} · '
        '${avg((b) => b.totalMs).round()}ms (ảnh ${avg((b) => b.prepMs).round()} · AI ${avg((b) => b.inferMs).round()}) · '
        '${rate.toStringAsFixed(1)} lần/s · ${_scheduler.mode.vi}\n'
        '${_scene.objects.length} vật'
        ' · max ${_detector.labelOf(last.maxClassId)} ${(last.maxScore * 100).round()}%';
  }

  static String _backendLabel(String b) => switch (b) {
        'cpu' => 'CPU',
        'gpu' || 'metal' => 'GPU',
        _ => 'Tự động',
      };

  /// Nút debug: Tự động → CPU → GPU → Tự động... (nạp lại model với cách chạy đã chọn)
  Future<void> _cycleBackend() async {
    final gpu = Platform.isIOS ? 'metal' : 'gpu';
    final next = switch (_backendChoice) { 'auto' => 'cpu', 'cpu' => gpu, _ => 'auto' };
    setState(() {
      _backendChoice = next;
      _switchingBackend = true;
      _modelLoaded = false;
    });
    try {
      await _detector.reload(preferredBackend: next);
    } catch (e) {
      debugPrint('Không đổi được cách chạy AI ($next): $e');
      _speech.say('Máy không chạy được AI bằng ${_backendLabel(next)}.', SpeechPriority.description, force: true);
      _backendChoice = 'auto';
      await _detector.reload();
    }
    _recentBatches.clear();
    _scheduler.reset();
    _tracker.reset();
    if (mounted) {
      setState(() {
        _switchingBackend = false;
        _modelLoaded = true;
      });
    }
  }

  /// Máy chưa có giọng tiếng Việt → TTS sẽ đọc bằng giọng mặc định, khó nghe → hướng dẫn cài
  Widget _voiceMissingBanner() {
    final path = Platform.isIOS
        ? 'Cài đặt → Trợ năng → Nội dung được đọc → Giọng nói → Tiếng Việt'
        : 'Cài đặt → Quản lý chung → Chuyển văn bản thành giọng nói → tải gói Tiếng Việt';
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: Colors.amber, borderRadius: BorderRadius.circular(12)),
      child: Text(
        'Máy chưa có giọng đọc tiếng Việt. Vào: $path',
        style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _smallButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 16),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  /// Nút lớn, tương phản cao — dễ bấm khi không nhìn rõ, có nhãn cho TalkBack
  Widget _bigButton(IconData icon, String label, String semantics, VoidCallback onTap) {
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
                    style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 15),
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
