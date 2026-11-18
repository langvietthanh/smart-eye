import 'dart:async';
import 'dart:math';

import 'package:smart_eye/models/scene_info.dart';
import 'package:smart_eye/services/depth_alert.dart';
import 'package:smart_eye/services/lidar_analysis.dart';
import 'package:smart_eye/services/path_blockage.dart';
import 'package:smart_eye/services/speech_manager.dart';
import 'package:smart_eye/services/tts_service.dart';
import 'package:smart_eye/services/turn_tracker.dart';
import 'package:smart_eye/services/walk_state.dart';

import 'sim_world.dart';

/// What the simulated walker is doing.
enum Act { walk, slow, stop, stepLeft, stepRight, turn, done, blocked }

/// Forwards to the real voice and tells the walker what was said, exactly
/// when the speech manager actually sends a line out.
class _HeardTts implements TTSService {
  _HeardTts(this._inner, this.onLine);
  final TTSService _inner;
  final void Function(String) onLine;

  @override
  bool get vietnameseAvailable => _inner.vietnameseAvailable;
  @override
  set vietnameseAvailable(bool v) => _inner.vietnameseAvailable = v;
  @override
  bool get isSpeaking => _inner.isSpeaking;
  @override
  Future<void> init() => _inner.init();
  @override
  Future<void> speak(String text) {
    onLine(text);
    return _inner.speak(text);
  }

  @override
  Future<void> stop() => _inner.stop();
}

/// Runs the app's LiDAR pipeline (the same services, in the same order as
/// CameraScreen on feat/arkit-bypass-memory) on frames ray-cast from a
/// virtual room, and moves a walker who follows what the app says.
///
/// Not simulated: YOLO (no camera image), MiDaS, the sight monitor and
/// navigation. Keep this in step with CameraScreen's LiDAR path.
class SimDriver {
  SimDriver({required TTSService tts, DateTime Function()? now, Preset? preset})
    : _now = now ?? DateTime.now,
      preset = preset ?? presets.first {
    // The test constructor is how the sim swaps in the browser's voice.
    // ignore: invalid_use_of_visible_for_testing_member
    speech = SpeechManager.forTesting(tts: _HeardTts(tts, _heard), now: _now);
    _turns.onGravity(0, 9.81, 0);
    _start = _now();
  }

  // Walker model: a careful walker with a cane.
  static const walkSpeed = 0.6, slowSpeed = 0.3; // m/s
  /// Sidesteps go on slowly until "Đi thẳng.", at most this far (m).
  static const stepWidth = 0.8;
  static const turnRate = 35.0; // deg/s while finding a way
  static const bodyRadius = 0.22;
  static const lidarEvery = Duration(milliseconds: 100);

  final DateTime Function() _now;
  late final SpeechManager speech;
  Preset preset;

  // The app's services (CameraScreen fields of the same names).
  final LidarAnalysis _analysis = LidarAnalysis();
  final PathBlockage blockage = PathBlockage();
  final WalkState walk = WalkState();
  final LidarWarning _lidarWarning = LidarWarning();
  final SideStability _sideStability = SideStability();
  final SideLatch _sideLatch = SideLatch();
  final WallLatch _wallLatch = WallLatch();
  final TurnTracker _turns = TurnTracker();
  static const _noSides = (left: SideState.unknown, right: SideState.unknown);
  ({SideState left, SideState right}) _sides = _noSides;
  int _sidesAtMs = -1;
  bool _wall = false;
  bool _frontWarned = false;
  DateTime? _straightAt;
  bool _straightOwed = false;
  static const _straightRepeat = Duration(seconds: 3);
  static const _straightMinGap = Duration(seconds: 3);

  // Walker state.
  double x = 0, z = 0, yaw = 0;
  bool auto = true;
  Act act = Act.walk;
  double _stepLeftToGo = 0;
  bool _stepBack = false; // the next sidestep returns to the old line
  bool _passingHeard = false;
  int _turnSign = -1; // flipped before each new turn: right first
  final List<(double, double)> trail = [];
  final List<(double, double)> collisions = [];
  bool _touching = false;
  final List<({Duration at, String text})> heard = [];
  late DateTime _start;
  DateTime? _lastLidar;

  /// Manual controls (held keys / buttons): forward −1..1, turn −1..1,
  /// side −1..1 (+ right).
  double manualForward = 0, manualTurn = 0, manualSide = 0;

  LidarDepthFrame? lastFrame;
  LidarScan? lastScan;
  String lidarStatus = '';

  void reset([Preset? next]) {
    if (next != null) preset = next;
    x = 0;
    z = 0;
    yaw = 0;
    act = auto ? Act.walk : Act.stop;
    _stepLeftToGo = 0;
    _stepBack = false;
    _passingHeard = false;
    trail.clear();
    collisions.clear();
    heard.clear();
    _touching = false;
    _analysis.reset();
    blockage.reset();
    walk.reset();
    _lidarWarning.reset();
    _sideStability.reset();
    _sideLatch.reset();
    _wallLatch.reset();
    _turns.reset();
    _sides = _noSides;
    _sidesAtMs = -1;
    _wall = false;
    _frontWarned = false;
    _straightAt = null;
    _straightOwed = false;
    _lastLidar = null;
    lastFrame = null;
    lastScan = null;
    unawaited(speech.stopAll());
    _start = _now();
  }

  /// Reached the end of the aisle, or told the way on is blocked.
  bool get finished => act == Act.done || act == Act.blocked;

  /// Advances the walker by [dt] and runs LiDAR at ~10 Hz.
  void advance(Duration dt) {
    final s = dt.inMicroseconds / 1e6;
    final yawBefore = yaw;
    if (auto) {
      _autoMove(s);
    } else {
      _manualMove(s);
    }
    final now = _now();
    _turns.onGyro(now, 0, s > 0 ? (yaw - yawBefore) / s : 0, 0);
    if (trail.isEmpty || _dist(trail.last, (x, z)) > 0.05) trail.add((x, z));
    final touching = preset.boxes.any((b) => b.bumps(x, z, bodyRadius));
    if (touching && !_touching) collisions.add((x, z));
    _touching = touching;
    if (preset.finish && z >= preset.length - 1.2 && auto) act = Act.done;
    final last = _lastLidar;
    if (last == null || now.difference(last) >= lidarEvery) {
      _lastLidar = now;
      _lidarTick(now);
    }
  }

  static double _dist((double, double) a, (double, double) b) =>
      sqrt(pow(a.$1 - b.$1, 2) + pow(a.$2 - b.$2, 2));

  void _forward(double m) {
    x += sin(yaw) * m;
    z += cos(yaw) * m;
  }

  void _aside(double m) {
    // + = to the right of the heading
    x += cos(yaw) * m;
    z -= sin(yaw) * m;
  }

  void _manualMove(double s) {
    _forward(manualForward * walkSpeed * s);
    _aside(manualSide * walkSpeed * s);
    yaw += manualTurn * turnRate * pi / 180 * s;
  }

  void _autoMove(double s) {
    switch (act) {
      case Act.walk:
        _forward(walkSpeed * s);
      case Act.slow:
        _forward(slowSpeed * s);
      case Act.stepLeft:
      case Act.stepRight:
        final d = min(_stepLeftToGo, 0.35 * s); // slow, careful side steps
        _aside(act == Act.stepRight ? d : -d);
        _stepLeftToGo -= d;
        if (_stepLeftToGo <= 1e-6) {
          // Never told to stop stepping: carry on if returning, else wait.
          act = _stepBack ? Act.walk : Act.stop;
          _stepBack = false;
        }
      case Act.turn:
        yaw += _turnSign * turnRate * pi / 180 * s;
      case Act.stop:
      case Act.done:
      case Act.blocked:
        break;
    }
  }

  /// The walker reacts to each line as it is spoken.
  void _heard(String text) {
    heard.add((at: _now().difference(_start), text: text));
    if (!auto || finished) return;
    if (text.startsWith('Phía trước bị chặn')) {
      act = Act.blocked; // stands still; going back is a choice it doesn't make
    } else if (text.startsWith('Bước ngang')) {
      act = text.contains('phải') ? Act.stepRight : Act.stepLeft;
      _stepLeftToGo = stepWidth;
      _stepBack = _passingHeard;
      _passingHeard = false;
    } else if (text.startsWith('Xoay ngược')) {
      _turnSign = -_turnSign;
      act = Act.turn;
    } else if (text.contains('Xoay')) {
      if (act != Act.turn) _turnSign = -_turnSign; // try the other way next
      act = Act.turn;
    } else if (text.startsWith('Dừng lại')) {
      act = Act.stop;
      _passingHeard = false;
    } else if (text.startsWith('Đi thẳng')) {
      if (walk.phase == WalkPhase.passing) _passingHeard = true;
      act = Act.walk; // also ends a sidestep: far enough aside / back
    } else if (text.startsWith('Chậm lại') && act == Act.walk) {
      act = Act.slow;
    }
  }

  int _ms(DateTime t) => t.difference(_start).inMilliseconds;

  // ------------------------------------------------ CameraScreen LiDAR path

  void _lidarTick(DateTime now) {
    final frame = castFrame(preset.boxes, x, z, yaw);
    final scan = _analysis.analyzeScan(frame);
    lastFrame = frame;
    lastScan = scan;
    _wall = _wallLatch.update(scan.center);
    blockage.onDepth(now, scan);
    _handleWalkCue(walk.onScan(now, scan), now);
    _evaluateBlockage(now);
    _onLidarReading(scan.center, now);
  }

  void _evaluateBlockage(DateTime now) {
    _handleWalkCue(
      walk.tick(
        now,
        aheadOpen: blockage.openAhead(now, beyond: WalkState.exitBeyond),
        turning: _turns.turningAt(now),
        turnedDegrees: _turns.degrees,
      ),
      now,
    );
    _onBlockage(blockage.evaluate(now));
    _maybeSayStraight(now);
  }

  void _handleWalkCue(WalkCue? cue, DateTime now) {
    switch (cue) {
      case null:
        return;
      case WalkCue.turnOn:
        if (speech.sayNow(
          turnOnText,
          SpeechPriority.danger,
          subject: 'path:turn',
        )) {
          _turns.reset();
        }
      case WalkCue.turnBack:
        if (speech.sayNow(
          turnBackText,
          SpeechPriority.danger,
          subject: 'path:turn',
        )) {
          _turns.reset();
        }
      case WalkCue.blocked:
        speech.sayNow(blockedText, SpeechPriority.danger, subject: 'path:turn');
      case WalkCue.stepDone:
        speech.sayNow('Đi thẳng.', SpeechPriority.danger, subject: 'path:step');
        _straightAt = now;
      case WalkCue.goStraight:
        speech.dropSubject('path:turn');
        speech.say(
          'Đi thẳng.',
          SpeechPriority.guidance,
          subject: 'path:straight',
        );
        _straightAt = now;
      case WalkCue.findWay:
        _sayFindWay();
      case WalkCue.stepRight:
      case WalkCue.stepLeft:
        speech.sayNow(
          cue == WalkCue.stepRight
              ? 'Bước ngang sang phải.'
              : 'Bước ngang sang trái.',
          SpeechPriority.danger,
          subject: 'path:step',
        );
    }
  }

  void _sayFindWay() {
    final spoken = speech.sayNow(
      findWayText,
      SpeechPriority.danger,
      subject: 'path:findway',
      onStart: _turns.reset,
    );
    if (!spoken) {
      walk.reset();
      return;
    }
    blockage.watchAhead();
  }

  void _sayStop() {
    if (!speech.sayNow(
      'Dừng lại!',
      SpeechPriority.danger,
      subject: 'path:stop',
    )) {
      walk.reset();
    }
  }

  void _onBlockage(PathEvent? event) {
    if (event == PathEvent.cleared) {
      speech.dropSubject('depth:center');
      _frontWarned = true;
    }
  }

  void _maybeSayStraight(DateTime now) {
    if (!blockage.aheadOpenSettled(now)) {
      _straightOwed = true;
      return;
    }
    if (walk.phase != WalkPhase.straight || speech.isBusy) return;
    final last = _straightAt;
    final since = last == null ? null : now.difference(last);
    final due =
        since == null ||
        since >= _straightRepeat ||
        ((_frontWarned || _straightOwed) && since >= _straightMinGap);
    if (!due) return;
    if (speech.say(
      'Đi thẳng.',
      SpeechPriority.guidance,
      subject: 'path:straight',
    )) {
      _straightAt = now;
      _straightOwed = false;
      _frontWarned = false;
    }
  }

  void _onLidarReading(LidarReading reading, DateTime now) {
    _sides = _sideLatch.update(reading, _sideStability.update(reading));
    _sidesAtMs = _ms(now);
    lidarStatus = switch (reading) {
      LidarObstacle(
        :final distance,
        :final wall,
        :final leftGap,
        :final rightGap,
      ) =>
        '${distance.toStringAsFixed(2)} m${wall ? ' · tường' : ''}'
            ' · khe T ${(leftGap * 100).round()} cm, P ${(rightGap * 100).round()} cm',
      LidarClear() =>
        'thông ≤ ${LidarAnalysis.maxForward.toStringAsFixed(0)} m',
      LidarUnknown() => 'không đo được',
    };
    _announceDepth(
      _lidarWarning.update(reading, now, wall: _wall),
      now,
      sides: speakableSides(
        _sides,
        capturedAtMs: _sidesAtMs,
        nowMs: _ms(now),
        findingWay: walk.phase != WalkPhase.straight,
      ),
    );
  }

  void _announceDepth(
    AlertLevel level,
    DateTime now, {
    ({SideState left, SideState right}) sides = _noSides,
  }) {
    final isDanger = level == AlertLevel.danger;
    if (walk.phase != WalkPhase.straight &&
        !(isDanger && walk.phase == WalkPhase.passing)) {
      return;
    }
    if (isDanger) {
      switch (walk.onDanger(
        wall: _wall,
        sideOpen: sideClause(sides.left, sides.right) != null,
        canBypass: true,
      )) {
        case DangerAction.findWay:
          _sayFindWay();
          return;
        case DangerAction.stop:
          _sayStop();
          return;
        case DangerAction.none:
          if (walk.phase != WalkPhase.straight) return;
      }
    }
    // With LiDAR the side is picked after stopping ("Bước ngang sang …").
    final text = depthAlertText(depthLevel: level);
    if (text == null) return;
    if (!isDanger && blockage.aheadOpenSettled(now)) return;
    final priority = isDanger ? SpeechPriority.danger : SpeechPriority.caution;
    const subject = 'depth:center';
    if (!speech.canSay(priority, subject: subject)) return;
    speech.say(
      text,
      priority,
      subject: subject,
      onStart: () {
        if (!blockage.aheadOpenSettled(_now())) _frontWarned = true;
      },
    );
    blockage.watchAhead();
  }

  String get phaseLabel => switch (walk.phase) {
    WalkPhase.straight => 'đi thẳng',
    WalkPhase.findWay => 'tìm lối',
    WalkPhase.collect => 'vòng qua: gom khung',
    WalkPhase.sidestep => 'vòng qua: bước ngang',
    WalkPhase.passing => 'vòng qua: đi qua',
  };

  String get blockedLabel {
    final b = blockage.blocked(_now());
    String m(bool v) => v ? '✗' : '✓';
    return 'T${m(b[0])} G${m(b[1])} P${m(b[2])}';
  }
}
