import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:smart_eye/services/lidar_analysis.dart';
import 'package:smart_eye/services/speech_manager.dart';

import 'sim_driver.dart';
import 'sim_world.dart';
import 'web_tts.dart';

void main() => runApp(const SimApp());

const _ink = Color(0xFF1F2937), _muted = Color(0xFF6B7280);
const _blue = Color(0xFF2563EB),
    _green = Color(0xFF16A34A),
    _red = Color(0xFFDC2626);

class SimApp extends StatelessWidget {
  const SimApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Smart Eye mô phỏng',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      fontFamily: 'DejaVuSans',
      colorSchemeSeed: _blue,
      scaffoldBackgroundColor: const Color(0xFFEEF2F6),
    ),
    home: const SimScreen(),
  );
}

class SimScreen extends StatefulWidget {
  const SimScreen({super.key});
  @override
  State<SimScreen> createState() => _SimScreenState();
}

class _SimScreenState extends State<SimScreen>
    with SingleTickerProviderStateMixin {
  final WebTts _tts = WebTts();
  late final SimDriver _sim = SimDriver(tts: _tts);
  late final Ticker _ticker = createTicker(_onTick);
  final FocusNode _focus = FocusNode();
  Duration? _lastTick;
  bool _running = false;
  bool _started = false;
  ui.Image? _depth;
  Object? _depthOf;

  @override
  void dispose() {
    _ticker.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final last = _lastTick;
    _lastTick = elapsed;
    if (last == null || !_running) return;
    var dt = elapsed - last;
    if (dt > const Duration(milliseconds: 100)) {
      dt = const Duration(milliseconds: 100);
    }
    _sim.advance(dt);
    if (_sim.finished) _running = false;
    final frame = _sim.lastFrame;
    if (frame != null && !identical(frame, _depthOf)) {
      _depthOf = frame;
      _makeDepthImage(frame.depth, frame.confidence);
    }
    setState(() {});
  }

  /// Portrait view of the depth frame: near = warm, far = dark.
  void _makeDepthImage(Float32List depth, Uint8List conf) {
    const w = 96, h = 128; // every 2nd pixel, turned upright
    final px = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final u = (h - 1 - y) * 2, v = x * 2;
        final i = v * Phone.w + u;
        final o = (y * w + x) * 4;
        if (conf[i] == 0) {
          px[o + 3] = 255;
          continue;
        }
        final k = (1 - (depth[i] / Phone.range)).clamp(0.0, 1.0);
        px[o] = (40 + 215 * k).round();
        px[o + 1] = (60 + 120 * k * k).round();
        px[o + 2] = (120 * (1 - k)).round();
        px[o + 3] = 255;
      }
    }
    ui.decodeImageFromPixels(px, w, h, ui.PixelFormat.rgba8888, (img) {
      if (!mounted) return;
      setState(() {
        _depth?.dispose();
        _depth = img;
      });
    });
  }

  void _start() {
    // Browsers only speak after a click: this button is that click.
    _started = true;
    _running = true;
    _sim.reset();
    if (!_ticker.isActive) _ticker.start();
    _focus.requestFocus();
    setState(() {});
  }

  void _restart([Preset? p]) {
    _sim.reset(p);
    _running = _started;
    setState(() {});
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (_sim.auto) return KeyEventResult.ignored;
    final down = e is! KeyUpEvent;
    final k = e.logicalKey;
    double v(bool on, double val) => on ? val : 0;
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.keyW) {
      _sim.manualForward = v(down, 1);
    } else if (k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.keyS) {
      _sim.manualForward = v(down, -1);
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      _sim.manualTurn = v(down, -1);
    } else if (k == LogicalKeyboardKey.arrowRight) {
      _sim.manualTurn = v(down, 1);
    } else if (k == LogicalKeyboardKey.keyA) {
      _sim.manualSide = v(down, -1);
    } else if (k == LogicalKeyboardKey.keyD) {
      _sim.manualSide = v(down, 1);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final map = Card(
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(
        painter: _MapPainter(_sim),
        child: const SizedBox.expand(),
      ),
    );
    final side = _SidePanel(sim: _sim, depth: _depth);
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _toolbar(),
                const SizedBox(height: 8),
                Expanded(
                  child: !_started
                      ? _intro()
                      : wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(flex: 5, child: map),
                            const SizedBox(width: 12),
                            SizedBox(width: 420, child: side),
                          ],
                        )
                      : ListView(
                          children: [
                            SizedBox(height: 460, child: map),
                            const SizedBox(height: 8),
                            SizedBox(height: 760, child: side),
                          ],
                        ),
                ),
                if (_started && !_sim.auto) _manualPad(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar() => Wrap(
    spacing: 12,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      const Text(
        'Smart Eye · mô phỏng không cần iPhone',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: _ink,
        ),
      ),
      DropdownButton<Preset>(
        value: _sim.preset,
        items: [
          for (final p in presets)
            DropdownMenuItem(value: p, child: Text(p.name)),
        ],
        onChanged: (p) => _restart(p),
      ),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Máy chúc ${Phone.pitchDeg.round()}°'),
          SizedBox(
            width: 160,
            child: Slider(
              value: Phone.pitchDeg,
              min: 0,
              max: 45,
              divisions: 9,
              onChanged: (v) => setState(() => Phone.pitchDeg = v),
            ),
          ),
        ],
      ),
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: true, label: Text('Tự đi theo lời app')),
          ButtonSegment(value: false, label: Text('Tự điều khiển')),
        ],
        selected: {_sim.auto},
        onSelectionChanged: (s) {
          _sim.auto = s.first;
          _restart();
        },
      ),
      FilterChip(
        label: const Text('Đọc to'),
        selected: _tts.voiced,
        onSelected: (v) => setState(() => _tts.voiced = v),
      ),
      if (_started) ...[
        IconButton.filledTonal(
          tooltip: _running ? 'Tạm dừng' : 'Chạy tiếp',
          onPressed: () => setState(() => _running = !_running),
          icon: Icon(_running ? Icons.pause : Icons.play_arrow),
        ),
        IconButton.filledTonal(
          tooltip: 'Chạy lại từ đầu',
          onPressed: _restart,
          icon: const Icon(Icons.replay),
        ),
      ],
    ],
  );

  Widget _intro() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Chạy logic thật của app trong một lớp học ảo',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              const Text(
                'Một iPhone ảo đi giữa lối, LiDAR ảo đo khoảng cách tới bàn, ghế, người '
                'và tường. Số đo đi vào đúng code của app (phân tích LiDAR, trạng thái '
                'vòng qua vật, ghi nhớ vật bằng ARKit, chọn câu nói), câu nói được đọc '
                'bằng giọng của trình duyệt. Người ảo làm theo lời app: dừng, bước ngang, '
                'xoay, đi thẳng.',
                style: TextStyle(height: 1.5),
              ),
              const SizedBox(height: 12),
              const Text(
                'Không mô phỏng: nhận diện vật bằng camera (YOLO) và rung.',
                style: TextStyle(color: _muted),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Bắt đầu (bật tiếng)'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _manualPad() {
    Widget hold(IconData icon, String tip, void Function(double) set) =>
        Padding(
          padding: const EdgeInsets.all(4),
          child: Listener(
            onPointerDown: (_) => set(1),
            onPointerUp: (_) => set(0),
            onPointerCancel: (_) => set(0),
            child: IconButton.filled(
              tooltip: tip,
              onPressed: () {},
              icon: Icon(icon),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          hold(Icons.rotate_left, 'Xoay trái (←)', (v) => _sim.manualTurn = -v),
          hold(
            Icons.arrow_back,
            'Bước ngang trái (A)',
            (v) => _sim.manualSide = -v,
          ),
          hold(
            Icons.arrow_upward,
            'Đi tới (↑ / W)',
            (v) => _sim.manualForward = v,
          ),
          hold(
            Icons.arrow_downward,
            'Lùi (↓ / S)',
            (v) => _sim.manualForward = -v,
          ),
          hold(
            Icons.arrow_forward,
            'Bước ngang phải (D)',
            (v) => _sim.manualSide = v,
          ),
          hold(Icons.rotate_right, 'Xoay phải (→)', (v) => _sim.manualTurn = v),
          const SizedBox(width: 12),
          const Text(
            'Giữ nút hoặc phím ↑ ↓ ← → A D',
            style: TextStyle(color: _muted),
          ),
        ],
      ),
    );
  }
}

class _SidePanel extends StatelessWidget {
  const _SidePanel({required this.sim, required this.depth});
  final SimDriver sim;
  final ui.Image? depth;

  @override
  Widget build(BuildContext context) {
    final line = sim.speech.showing.value;
    final danger = line?.priority == SpeechPriority.danger;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          color: line == null
              ? Colors.white
              : danger
              ? const Color(0xFFFEE2E2)
              : const Color(0xFFFEF3C7),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('App đang nói', style: TextStyle(color: _muted)),
                const SizedBox(height: 6),
                Text(
                  line?.text ?? '—',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: _ink,
                  ),
                ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 96,
                  height: 128,
                  child: depth == null
                      ? const ColoredBox(color: Colors.black)
                      : RawImage(image: depth, fit: BoxFit.fill),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DefaultTextStyle.merge(
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: _ink,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Trạng thái: ${sim.phaseLabel}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Text('LiDAR: ${sim.lidarStatus}'),
                        Text('Hướng: ${sim.blockedLabel}'),
                        Text('Người ảo: ${_act(sim.act)}'),
                        Text(
                          'Va chạm: ${sim.collisions.length}',
                          style: TextStyle(
                            color: sim.collisions.isEmpty ? _green : _red,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Text(
                          'Ảnh: độ sâu LiDAR ảo (gần = đỏ)',
                          style: TextStyle(color: _muted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(sim.preset.note, style: const TextStyle(height: 1.4)),
          ),
        ),
        Expanded(
          child: Card(
            child: ListView(
              padding: const EdgeInsets.all(12),
              reverse: true,
              children: [
                for (final h in sim.heard.reversed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '${(h.at.inMilliseconds / 1000).toStringAsFixed(1)}s  ${h.text}',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                const Text('Nhật ký câu nói', style: TextStyle(color: _muted)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static String _act(Act a) => switch (a) {
    Act.walk => 'đang đi',
    Act.slow => 'đi chậm',
    Act.stop => 'đứng yên',
    Act.stepLeft => 'bước ngang trái',
    Act.stepRight => 'bước ngang phải',
    Act.turn => 'đang xoay',
    Act.done => 'đã tới cuối lối',
    Act.blocked => 'đứng yên: lối phía trước bị chặn',
  };
}

class _MapPainter extends CustomPainter {
  _MapPainter(this.sim);
  final SimDriver sim;

  static const _kind = {
    Kind.desk: Color(0xFFB08968),
    Kind.chair: Color(0xFFEA7A1E),
    Kind.person: Color(0xFF64748B),
    Kind.bag: Color(0xFFEA7A1E),
    Kind.wall: Color(0xFFCBC5B8),
    Kind.pillar: Color(0xFF94A3B8),
  };

  @override
  void paint(Canvas canvas, Size size) {
    final p = sim.preset;
    const x0 = -2.4, x1 = 2.4;
    final z0 = -1.2, z1 = p.length + 0.2;
    final scale = min(size.width / (x1 - x0), size.height / (z1 - z0)) * 0.96;
    final ox = size.width / 2,
        oy = size.height - (size.height - (z1 - z0) * scale) / 2;
    Offset at(double x, double z) =>
        Offset(ox + x * scale, oy - (z - z0) * scale);

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFF8FAFC),
    );
    // Original line along the aisle.
    final dash = Paint()
      ..color = _blue.withValues(alpha: 0.6)
      ..strokeWidth = 2;
    for (var z = 0.0; z < p.length; z += 0.4) {
      canvas.drawLine(at(0, z), at(0, z + 0.2), dash);
    }
    for (final b in p.boxes) {
      final r = Rect.fromPoints(at(b.x0, b.z0), at(b.x1, b.z1));
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(3)),
        Paint()..color = _kind[b.kind]!,
      );
    }
    // LiDAR corridor ahead of the phone: 50 cm core, 70 cm outer.
    final yaw = sim.yaw;
    Offset local(double ax, double fwd) => at(
      sim.x + ax * cos(yaw) + fwd * sin(yaw),
      sim.z - ax * sin(yaw) + fwd * cos(yaw),
    );
    // Up to what LiDAR measures ahead (it does not see through things).
    final centre = sim.lastScan?.center;
    final reach = centre is LidarObstacle ? max(centre.distance, 0.25) : 4.0;
    for (final (half, alpha) in [(0.35, 0.10), (0.25, 0.16)]) {
      canvas.drawPath(
        Path()..addPolygon([
          local(-half, 0.2),
          local(half, 0.2),
          local(half, reach),
          local(-half, reach),
        ], true),
        Paint()..color = _blue.withValues(alpha: alpha),
      );
    }
    // Trail, collisions, walker.
    if (sim.trail.length > 1) {
      canvas.drawPoints(
        ui.PointMode.polygon,
        [for (final (x, z) in sim.trail) at(x, z)],
        Paint()
          ..color = _green
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }
    final cross = Paint()
      ..color = _red
      ..strokeWidth = 3;
    for (final (x, z) in sim.collisions) {
      final c = at(x, z);
      canvas.drawLine(c - const Offset(8, 8), c + const Offset(8, 8), cross);
      canvas.drawLine(c - const Offset(8, -8), c + const Offset(8, -8), cross);
    }
    final c = at(sim.x, sim.z);
    canvas.drawCircle(c, SimDriver.bodyRadius * scale, Paint()..color = _ink);
    canvas.drawLine(
      c,
      local(0, 0.45),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 3,
    );
    final tp = TextPainter(
      text: TextSpan(
        text: 'nhìn từ trên xuống · lưới 1 m',
        style: TextStyle(color: _muted.withValues(alpha: 0.9), fontSize: 12),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, const Offset(8, 6));
    tp.dispose();
  }

  @override
  bool shouldRepaint(covariant _MapPainter old) => true;
}
