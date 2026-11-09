import 'dart:ui';

import '../models/nav_command.dart';
import '../models/scene_info.dart';
import '../models/tracked_object.dart';
import 'lidar_analysis.dart';

enum NavState { idle, searching, guiding, lost }

enum _StateCue { entry, reacquire, loss }

/// Pure-Dart state machine that turns tracked objects into at most one short
/// Vietnamese spoken cue per frame while the user walks towards a target.
class NavigationGuide {
  // Direction (normalised dx = centre.x - 0.5).
  static const double lateralEnter = 0.22;
  static const double backToStraight = 0.12;
  static const double clockThreshold = 0.15;
  static const Duration holdLateral = Duration(milliseconds: 500);
  static const Duration lateralRepeat = Duration(seconds: 3);

  // Searching / loss timing.
  static const Duration searchReminder = Duration(seconds: 5);
  static const Duration midFrameLossWait = Duration(milliseconds: 1500);
  static const Duration searchTimeout = Duration(seconds: 15);
  static const Duration lostTimeout = Duration(seconds: 15);

  // Arrival.
  static const double arrivalDx = 0.25;
  static const int arrivalUpdates = 2;
  static const double edgeBottom = 0.95;
  static const double edgeHeight = 0.6;
  static const double edgeDx = 0.3;
  static const double sideEdgeLeft = 0.03;
  static const double sideEdgeRight = 0.97;
  static const double lidarArrivalMeters = 1.0;

  NavState _state = NavState.idle;
  Set<String> _labels = const {};
  String _nameVi = '';
  int? _trackId;

  DateTime? _lastSearchCue;

  // Timeout clocks: accumulated update deltas, paused while sight is lost.
  DateTime? _prevNow;
  Duration _searchElapsed = Duration.zero;
  Duration _lostElapsed = Duration.zero;

  // Last visible observation of the locked target (normalised box).
  Rect? _lastBox;
  DistanceLevel _lastLevel = DistanceLevel.far;
  DateTime? _lastSeenAt;

  bool _quiet = false;
  NavCue? _pendingFinal;

  // State-change cue dropped under quiet; replayed once quiet ends if the
  // guide is still in that state.
  _StateCue? _pendingStateCue;
  String? _pendingStateText;
  bool _lossClassified = false;

  // Guiding bookkeeping: only advanced when the matching cue is returned.
  int _announcedLevel = 0;
  bool _lateralSpoken = false;
  DateTime? _lastLateralCue;
  int _lastSpokenSide = 0;
  // Lateral hold timer: when |dx| first exceeded the threshold on this side.
  DateTime? _lateralSince;
  int _lateralSign = 0;
  int _arrivalCount = 0;

  NavState get state => _state;
  bool get isActive => _state != NavState.idle;
  int? get targetTrackId => _trackId;
  String? get targetName => isActive ? _nameVi : null;

  NavCue start(Set<String> labelsEn, String nameVi, DateTime now) {
    final retarget = isActive;
    _labels = labelsEn;
    _nameVi = nameVi;
    _trackId = null;
    _state = NavState.searching;
    _lastSearchCue = now;
    _prevNow = now;
    _searchElapsed = Duration.zero;
    _lostElapsed = Duration.zero;
    _pendingFinal = null;
    _pendingStateCue = null;
    _lossClassified = false;
    _lastBox = null;
    _lastSeenAt = null;
    _resetGuiding();
    return NavCue(
      retarget
          ? 'Đổi sang tìm $_nameVi.'
          : 'Đang tìm $_nameVi. Xoay người chậm.',
    );
  }

  /// Stops guiding. Returns the spoken confirmation when [announce] is true and
  /// a session was active. Any pending final cue is discarded.
  NavCue? cancel({bool announce = true}) {
    _pendingFinal = null;
    if (!isActive) return null;
    _state = NavState.idle;
    _trackId = null;
    _resetGuiding();
    if (!announce) return null;
    return const NavCue(
      'Đã dừng dẫn đường.',
      force: true,
      end: NavEnd.cancelled,
    );
  }

  /// With [quiet], state keeps advancing but ordinary cues are dropped (and not
  /// marked as said); a final cue is held and returned by the first update
  /// with quiet == false. [sightLost] pauses the 15 s timeout clocks.
  NavCue? update({
    required List<TrackedObject> tracks,
    required Size frame,
    LidarReading? lidarCenter,
    bool quiet = false,
    bool sightLost = false,
    required DateTime now,
  }) {
    final prev = _prevNow;
    _prevNow = now;
    _quiet = quiet;
    if (prev != null && !sightLost) {
      final delta = now.difference(prev);
      if (_state == NavState.searching) _searchElapsed += delta;
      if (_state == NavState.lost) _lostElapsed += delta;
    }

    final NavCue? cue;
    switch (_state) {
      case NavState.idle:
        if (quiet) return null;
        cue = _pendingFinal;
        _pendingFinal = null;
        return cue;
      case NavState.searching:
        cue = _updateSearching(tracks, frame, lidarCenter, now);
      case NavState.guiding:
        cue = _updateGuiding(tracks, frame, lidarCenter, now);
      case NavState.lost:
        cue = _updateLost(tracks, frame, lidarCenter, now);
    }
    if (cue != null && cue.end != null && quiet) {
      _pendingFinal = cue;
      return null;
    }
    return cue;
  }

  NavCue? _emit(String text, [void Function()? mark]) {
    if (_quiet) return null;
    mark?.call();
    return NavCue(text);
  }

  NavCue? _updateSearching(
    List<TrackedObject> tracks,
    Size frame,
    LidarReading? lidar,
    DateTime now,
  ) {
    final target = _pickTarget(tracks, frame);
    if (target != null) {
      _trackId = target.id;
      _state = NavState.guiding;
      _resetGuiding();
      final level = _levelOf(target);
      _announcedLevel = _rank(level);
      _observe(target, frame, lidar, now);
      _remember(target, frame, now);
      return _announce(
        _StateCue.entry,
        _statePhrase(_StateCue.entry, target, frame),
      );
    }
    if (_searchElapsed >= searchTimeout) {
      return _end(
        'Không tìm thấy $_nameVi. Đã dừng dẫn đường.',
        NavEnd.notFound,
      );
    }
    if (now.difference(_lastSearchCue!) >= searchReminder) {
      return _emit(
        'Đang tìm $_nameVi. Xoay người chậm.',
        () => _lastSearchCue = now,
      );
    }
    return null;
  }

  NavCue? _updateGuiding(
    List<TrackedObject> tracks,
    Size frame,
    LidarReading? lidar,
    DateTime now,
  ) {
    final target = _lockedTrack(tracks, frame);
    if (target == null) return _classifyLoss(lidar, now);

    _remember(target, frame, now);
    final arrived = _observe(target, frame, lidar, now);
    if (arrived) {
      return _end(
        'Đã tới. ${_capitalized(_nameVi)} ngay trước mặt. Dò bằng gậy.',
        NavEnd.arrived,
      );
    }

    final dx = _norm(target, frame).center.dx - 0.5;
    final level = _rank(_levelOf(target));

    // A dropped state-change cue goes first, rebuilt from the current view.
    final pending = _pendingStateCue;
    if (pending != null && !_quiet) {
      _announcedLevel = level;
      _pendingStateCue = null;
      return NavCue(_statePhrase(pending, target, frame));
    }

    // Distance beats lateral cues.
    if (level > _announcedLevel) {
      return _emit(
        level == _rank(DistanceLevel.near) ? 'Sắp tới.' : 'Gần hơn rồi.',
        () => _announcedLevel = level,
      );
    }

    if (_lateralSince != null &&
        now.difference(_lateralSince!) >= holdLateral &&
        (_lastLateralCue == null ||
            _lateralSign != _lastSpokenSide ||
            now.difference(_lastLateralCue!) >= lateralRepeat)) {
      final sign = _lateralSign;
      return _emit(dx < 0 ? 'Lệch trái.' : 'Lệch phải.', () {
        _lastLateralCue = now;
        _lastSpokenSide = sign;
        _lateralSpoken = true;
      });
    }

    if (_lateralSpoken && dx.abs() < backToStraight) {
      return _emit('Thẳng rồi.', () {
        _lateralSpoken = false;
        _lastLateralCue = null;
        _lastSpokenSide = 0;
      });
    }
    return null;
  }

  void _remember(TrackedObject t, Size frame, DateTime now) {
    _lastBox = _norm(t, frame);
    _lastLevel = _levelOf(t);
    _lastSeenAt = now;
    _lossClassified = false;
  }

  /// Locked target is not visible: classify by where it was last seen.
  NavCue? _classifyLoss(LidarReading? lidar, DateTime now) {
    final box = _lastBox;
    final seen = _lastSeenAt;
    if (box == null || seen == null) return null;
    final near = _lastLevel == DistanceLevel.near;
    final dx = box.center.dx - 0.5;

    // Classified once, on the first missing update; later updates only wait.
    if (!_lossClassified) {
      _lossClassified = true;
      final cue = _classifyOnce(box, near, dx, lidar);
      if (cue != null || _state != NavState.guiding) return cue;
    }
    if (now.difference(seen) >= midFrameLossWait) {
      _enterLost();
      return _announce(
        _StateCue.loss,
        'Mất dấu $_nameVi. Đứng yên, xoay người chậm.',
      );
    }
    return null;
  }

  NavCue? _classifyOnce(Rect box, bool near, double dx, LidarReading? lidar) {
    if (near &&
        (box.bottom >= edgeBottom || box.height > edgeHeight) &&
        dx.abs() < edgeDx) {
      return _end(
        '${_capitalized(_nameVi)} ngay trước mặt, rất gần. Dò bằng gậy.',
        NavEnd.arrived,
      );
    }
    if (near &&
        lidar is LidarObstacle &&
        lidar.distance <= lidarArrivalMeters) {
      return _end(
        'Đã tới. ${_capitalized(_nameVi)} ngay trước mặt. Dò bằng gậy.',
        NavEnd.arrived,
      );
    }
    final atLeft = box.left <= sideEdgeLeft;
    final atRight = box.right >= sideEdgeRight;
    if (atLeft || atRight) {
      final left = atLeft && (!atRight || dx < 0);
      _enterLost();
      return _announce(
        _StateCue.loss,
        left
            ? '${_capitalized(_nameVi)} ở bên trái. Xoay trái chậm.'
            : '${_capitalized(_nameVi)} ở bên phải. Xoay phải chậm.',
      );
    }
    return null;
  }

  void _enterLost() {
    _state = NavState.lost;
    _lostElapsed = Duration.zero;
    _resetGuiding();
  }

  NavCue? _updateLost(
    List<TrackedObject> tracks,
    Size frame,
    LidarReading? lidar,
    DateTime now,
  ) {
    final target = _lockedTrack(tracks, frame) ?? _pickTarget(tracks, frame);
    if (target != null) {
      _trackId = target.id;
      _state = NavState.guiding;
      _resetGuiding();
      _announcedLevel = _rank(_levelOf(target));
      _observe(target, frame, lidar, now);
      _remember(target, frame, now);
      return _announce(
        _StateCue.reacquire,
        _statePhrase(_StateCue.reacquire, target, frame),
      );
    }
    final pending = _pendingStateText;
    if (_pendingStateCue == _StateCue.loss && pending != null && !_quiet) {
      _pendingStateCue = null;
      return NavCue(pending);
    }
    if (_lostElapsed >= lostTimeout) {
      return _end(
        'Không tìm lại được $_nameVi. Đã dừng dẫn đường.',
        NavEnd.lostTimeout,
      );
    }
    return null;
  }

  /// Updates per-frame counters (lateral hold, arrival). Returns true when the
  /// arrival condition has held for [arrivalUpdates] consecutive updates.
  bool _observe(
    TrackedObject target,
    Size frame,
    LidarReading? lidar,
    DateTime now,
  ) {
    final dx = _norm(target, frame).center.dx - 0.5;

    if (dx.abs() > lateralEnter) {
      final sign = dx < 0 ? -1 : 1;
      if (_lateralSince == null || sign != _lateralSign) {
        _lateralSince = now;
        _lateralSign = sign;
      }
    } else {
      _lateralSince = null;
      _lateralSign = 0;
    }

    final near = _levelOf(target) == DistanceLevel.near;
    final lidarOk = switch (lidar) {
      LidarObstacle(:final distance) => distance <= lidarArrivalMeters,
      LidarClear() => false,
      LidarUnknown() || null => true,
    };
    if (near && dx.abs() < arrivalDx && lidarOk) {
      _arrivalCount++;
    } else {
      _arrivalCount = 0;
    }
    return _arrivalCount >= arrivalUpdates;
  }

  NavCue _end(String text, NavEnd end) {
    _state = NavState.idle;
    _trackId = null;
    _resetGuiding();
    return NavCue(text, force: true, end: end);
  }

  void _resetGuiding() {
    _pendingStateCue = null;
    _announcedLevel = 0;
    _lateralSpoken = false;
    _lastLateralCue = null;
    _lastSpokenSide = 0;
    _lateralSince = null;
    _lateralSign = 0;
    _arrivalCount = 0;
  }

  bool _visible(TrackedObject t) =>
      t.confirmed && t.misses == 0 && _labels.contains(t.labelEn);

  /// Nearest visible target: the tallest box relative to the frame.
  TrackedObject? _pickTarget(List<TrackedObject> tracks, Size frame) {
    if (frame.width <= 0 || frame.height <= 0) return null;
    TrackedObject? best;
    for (final t in tracks) {
      if (!_visible(t)) continue;
      if (best == null || t.observedBox.height > best.observedBox.height) {
        best = t;
      }
    }
    return best;
  }

  TrackedObject? _lockedTrack(List<TrackedObject> tracks, Size frame) {
    if (frame.width <= 0 || frame.height <= 0) return null;
    for (final t in tracks) {
      if (t.id == _trackId && _visible(t)) return t;
    }
    return null;
  }

  Rect _norm(TrackedObject t, Size frame) {
    final b = t.observedBox;
    return Rect.fromLTRB(
      b.left / frame.width,
      b.top / frame.height,
      b.right / frame.width,
      b.bottom / frame.height,
    );
  }

  DistanceLevel _levelOf(TrackedObject t) =>
      t.distanceLevel ?? DistanceLevel.far;

  /// Closeness rank: far 0, medium 1, near 2 (enum order is near-first).
  static int _rank(DistanceLevel l) => switch (l) {
    DistanceLevel.far => 0,
    DistanceLevel.medium => 1,
    DistanceLevel.near => 2,
  };

  /// Cue announcing a state change. Under quiet it is remembered (for entry
  /// and reacquire it is rebuilt from the current view when replayed).
  NavCue? _announce(_StateCue kind, String text) {
    if (_quiet) {
      _pendingStateCue = kind;
      _pendingStateText = text;
      return null;
    }
    _pendingStateCue = null;
    return NavCue(text);
  }

  String _statePhrase(_StateCue kind, TrackedObject target, Size frame) {
    final box = _norm(target, frame);
    return switch (kind) {
      _StateCue.entry =>
        'Thấy $_nameVi ${_entryPhrase(box, _levelOf(target))}.',
      _StateCue.reacquire => 'Thấy lại $_nameVi, ${_direction(box)}.',
      _StateCue.loss => _pendingStateText ?? '',
    };
  }

  String _direction(Rect box) {
    final dx = box.center.dx - 0.5;
    return dx < -clockThreshold
        ? 'hướng 11 giờ'
        : dx > clockThreshold
        ? 'hướng 1 giờ'
        : 'phía trước';
  }

  String _entryPhrase(Rect box, DistanceLevel level) {
    final dir = 'ở ${_direction(box)}';
    final dist = switch (level) {
      DistanceLevel.far => 'còn xa',
      DistanceLevel.medium => 'khá gần',
      DistanceLevel.near => 'rất gần',
    };
    return '$dir, $dist';
  }

  String _capitalized(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
