import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
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
  bool _isDetecting = false;

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

  /// Góc cần xoay ảnh camera để AI thấy thế giới đứng thẳng — tự tính theo góc cảm biến + hướng
  /// điện thoại (công thức mẫu của Google ML Kit). Xoay điện thoại thì preview, khung vật, 3 cột
  /// và ảnh đưa vào AI cùng xoay theo màn hình, không cần bấm nút.
  int get _rotationDegrees {
    final controller = _controller;
    final camera = controller?.description ?? (cameras.isNotEmpty ? cameras.first : null);
    if (camera == null) return 90;
    final device = _deviceDegrees[controller?.value.deviceOrientation ?? DeviceOrientation.portraitUp]!;
    return camera.lensDirection == CameraLensDirection.front
        ? (camera.sensorOrientation + device) % 360
        : (camera.sensorOrientation - device + 360) % 360;
  }

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
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    _controller = controller;

    try {
      await controller.initialize();
      if (!mounted || _controller != controller) return;
      setState(() => _statusText = 'Camera sẵn sàng!');
      await controller.startImageStream(_onCameraFrame);
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
    if (controller == null || !controller.value.isInitialized) return;

    // Camera phải được giải phóng khi app rời màn hình, mở lại khi quay về
    if (state == AppLifecycleState.inactive) {
      _controller = null;
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  // ---------------------------------------------------------------------------
  // Pipeline
  // ---------------------------------------------------------------------------

  void _onCameraFrame(CameraImage image) {
    if (_isDetecting || !_modelLoaded || _isMockTest || _paused) return;
    _isDetecting = true;

    // finally: lỗi ở 1 frame không được làm kẹt cờ → nếu kẹt, nhận diện + nút "Xung quanh" chết hẳn
    try {
      final sw = _screenWidth;
      final sh = _screenHeight;
      if (sw == 0 || sh == 0) return;

      final results = _detector.detect(
        image: image,
        screenWidth: sw,
        screenHeight: sh,
        rotationDegrees: _rotationDegrees,
      );

      if (mounted) _runPipeline(results, image: image);
    } catch (e, stack) {
      debugPrint('Lỗi xử lý frame: $e\n$stack');
    } finally {
      _isDetecting = false;
    }
  }

  /// [image] chỉ hợp lệ trong lúc xử lý frame — dùng để chụp ảnh ghi nhớ (CN12)
  void _runPipeline(List<Recognition> detections, {CameraImage? image}) {
    final now = DateTime.now();
    final frame = Size(_screenWidth, _screenHeight);
    final tracks = _tracker.update(detections, frame, now);
    final scene = _engine.assess(tracks, frame);
    setState(() => _scene = scene);

    final alert = scene.alert;
    if (alert != null) {
      _handleAlert(alert, image, now);
    }

    if (_pendingDescribe) {
      _pendingDescribe = false;
      _describeFallback?.cancel();
      _describe(image, manual: true);
    } else if (_autoDescribe &&
        now.difference(_lastDescribeAt) >= _autoDescribeEvery &&
        now.difference(_lastAlertAt) >= _calmAfterAlert &&
        !_speech.isBusy) {
      _describe(image, manual: false);
    }
  }

  void _handleAlert(HazardAlert alert, CameraImage? image, DateTime now) {
    _lastAlertAt = now;
    final isDanger = alert.level == AlertLevel.danger;
    final priority = isDanger ? SpeechPriority.danger : SpeechPriority.caution;
    if (!_speech.canSay(priority, subject: alert.subject)) return; // Đã báo / đang chờ đọc

    // Ảnh chỉ hợp lệ trong frame hiện tại → chụp ngay, ghi lịch sử khi câu thực sự được đọc
    final jpeg = isDanger ? _captureMemory(image) : null;
    _speech.say(alert.message, priority, subject: alert.subject, onStart: () {
      if (isDanger) HapticFeedback.heavyImpact();
      _logEvent(isDanger ? TripEventType.danger : TripEventType.caution, alert.message, jpeg: jpeg);
    });
  }

  void _describe(CameraImage? image, {required bool manual}) {
    _lastDescribeAt = DateTime.now();
    // Người dùng chủ động hỏi thì luôn trả lời, kể cả khi đang ở chế độ yên lặng
    if (!_speech.canSay(SpeechPriority.description, force: manual)) return;
    final text = CaptionBuilder.describeScene(_scene);
    final jpeg = _captureMemory(image);
    _speech.say(text, SpeechPriority.description, force: manual,
        onStart: () => _logEvent(TripEventType.description, text, jpeg: jpeg));
  }

  Uint8List? _captureMemory(CameraImage? image) {
    if (image == null || !_history.canCaptureMemory()) return null;
    return ImageUtils.cameraImageToJpeg(image, rotationDegrees: _rotationDegrees);
  }

  void _logEvent(TripEventType type, String text, {Uint8List? jpeg}) {
    _history.log(type, text, lat: _location.last?.latitude, lng: _location.last?.longitude, jpeg: jpeg);
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
                  ? CameraPreview(controller)
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
                    Row(
                      children: [
                        // Chữ thông số co giãn trong phần còn lại → nút Test luôn đứng yên một chỗ
                        Expanded(
                          child: Text(
                            _isMockTest
                                ? 'Giả lập · ${_scene.objects.length} vật'
                                : '${_detector.lastFrameMs}ms · ${_scene.objects.length} vật · max '
                                    '${_detector.lastMaxLabel} ${(_detector.lastMaxScore * 100).round()}%',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white54, fontSize: 12),
                          ),
                        ),
                        const SizedBox(width: 8),
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
