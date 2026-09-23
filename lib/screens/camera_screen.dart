import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../main.dart';
import '../models/Recognition.dart';
import '../widgets/bounding_box_painter.dart';
import '../services/tts_service.dart';
import '../services/detector_service.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;

  List<Recognition> _recognitions = [];
  bool _isDetecting = false;

  // Trạng thái loading
  bool _modelLoaded = false;
  String _statusText = 'Đang khởi động...';
  bool _hasError = false;

  final TTSService _ttsService = TTSService();
  final DetectorService _detector = DetectorService();

  double _screenWidth = 0;
  double _screenHeight = 0;
  int _rotationDegrees = 90; // Mặc định 90° cho camera Android Portrait
  bool _isMockTest = false;

  @override
  void initState() {
    super.initState();
    // Dùng addPostFrameCallback để UI render trước, rồi mới init
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initAll();
    });
  }

  Future<void> _initAll() async {
    try {
      // 1. TTS init
      if (mounted) setState(() => _statusText = 'Khởi tạo TTS...');
      await _ttsService.init();

      // 2. Load model trong background (tránh block UI thread)
      if (mounted) setState(() => _statusText = 'Đang load model YOLOv8...');
      // compute() chạy trong isolate riêng, không block UI
      await Future.microtask(() => _detector.loadModel());

      if (mounted) {
        setState(() {
          _modelLoaded = true;
          _statusText = 'Đang mở camera...';
        });
      }

      // 3. Khởi động camera
      await _initializeCamera();
    } catch (e, stack) {
      debugPrint('Lỗi khởi tạo: $e\n$stack');
      if (mounted) {
        setState(() {
          _hasError = true;
          _statusText = 'Lỗi: $e';
        });
      }
    }
  }

  Future<void> _initializeCamera() async {
    if (cameras.isEmpty) {
      setState(() => _statusText = 'Không tìm thấy camera trên thiết bị');
      return;
    }

    _controller = CameraController(
      cameras.first,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await _controller!.initialize();
      if (!mounted) return;
      setState(() => _statusText = 'Camera sẵn sàng!');
      _controller!.startImageStream(_onCameraFrame);
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

  void _onCameraFrame(CameraImage image) {
    if (_isDetecting || !_modelLoaded || _isMockTest) return;
    _isDetecting = true;

    final sw = _screenWidth;
    final sh = _screenHeight;
    if (sw == 0 || sh == 0) {
      _isDetecting = false;
      return;
    }

    final results = _detector.detect(
      image: image,
      screenWidth: sw,
      screenHeight: sh,
      rotationDegrees: _rotationDegrees,
    );

    if (mounted) {
      setState(() => _recognitions = results);
      _processWarnings(sw, sh);
    }
    _isDetecting = false;
  }

  void _processWarnings(double screenW, double screenH) {
    for (var rec in _recognitions) {
      if (rec.getAreaRatio(screenW, screenH) > 0.30) {
        _ttsService.speakWarning('Cẩn thận, có ${rec.label} phía trước!');
        break;
      }
    }
  }

  @override
  void dispose() {
    _controller?.stopImageStream();
    _controller?.dispose();
    _detector.dispose();
    _ttsService.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _screenWidth = MediaQuery.of(context).size.width;
    _screenHeight = MediaQuery.of(context).size.height;

    // Loading / Error screen
    if (_controller == null || !_controller!.value.isInitialized) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Icon lỗi hoặc spinner
              if (_hasError)
                const Icon(Icons.error_outline, color: Colors.red, size: 60)
              else
                const CircularProgressIndicator(color: Colors.blue),
              const SizedBox(height: 20),
              // Status text
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  _statusText,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              ),
              // Nút thử lại nếu có lỗi
              if (_hasError) ...[
                const SizedBox(height: 20),
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
              ],
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
          // Layer 1: Camera preview
          CameraPreview(_controller!),

          // Layer 2: Bounding boxes
          CustomPaint(painter: BoundingBoxPainter(_recognitions)),

          // Layer 3: Overlay info
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _badge('SMART EYE', Colors.black54),
                    if (_recognitions.isNotEmpty)
                      _badge('Phát hiện: ${_recognitions.length} vật', Colors.red),
                  ],
                ),
              ),
            ),
          ),

          // Layer 4: Debug status & Nút xoay AI (góc dưới)
          Positioned(
            bottom: 16,
            left: 16,
            right: 16,
            child: SafeArea(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _modelLoaded ? 'YOLOv8n ✓' : 'Đang load...',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),

                  // Nút bấm trợ năng & Test
                  Row(
                    children: [
                      // Nút 🧪 Test UI (Kiểm tra vẽ khung đỏ + đọc TTS ngay lập tức)
                      InkWell(
                        onTap: () {
                          setState(() {
                            _isMockTest = !_isMockTest;
                            if (_isMockTest) {
                              final sw = _screenWidth;
                              final sh = _screenHeight;
                              _recognitions = [
                                Recognition(
                                  2, 'xe ô tô', 0.92,
                                  Rect.fromLTWH(sw * 0.15, sh * 0.25, sw * 0.70, sh * 0.40),
                                ),
                              ];
                              _processWarnings(sw, sh);
                            } else {
                              _recognitions = [];
                            }
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: _isMockTest ? Colors.orange : Colors.grey.withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.bug_report, color: Colors.white, size: 16),
                              const SizedBox(width: 4),
                              Text(
                                _isMockTest ? 'Tắt Test' : '🧪 Test UI',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),

                      // Nút xoay AI
                      InkWell(
                        onTap: () {
                          setState(() {
                            _rotationDegrees = (_rotationDegrees + 90) % 360;
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.blueAccent.withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.screen_rotation, color: Colors.white, size: 16),
                              const SizedBox(width: 4),
                              Text(
                                'Xoay AI: $_rotationDegrees°',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
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
}
