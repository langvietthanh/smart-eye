import 'dart:ui';

import '../models/nav_command.dart';
import '../models/scene_info.dart';
import '../models/tracked_object.dart';
import 'lidar_analysis.dart';

enum NavState { idle, searching, guiding, lost }

/// Pure-Dart state machine that turns tracked objects into at most one short
/// Vietnamese spoken cue per frame while the user walks towards a target.
class NavigationGuide {
  // Direction (normalised dx = centre.x - 0.5).
  static const double lateralEnter = 0.22;
  static const double backToStraight = 0.12;
  static const double clockThreshold = 0.15;
  static const Duration holdLateral = Duration(milliseconds: 500);
  static const Duration lateralRepeat = Duration(seconds: 3);

  // Searching / loss timing (loss ones are used by the loss handling later).
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

  DateTime? _searchStart;
  DateTime? _lastSearchCue;

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
    _labels = labelsEn;
    _nameVi = nameVi;
    _trackId = null;
    _state = NavState.searching;
    _searchStart = now;
    _lastSearchCue = now;
    _resetGuiding();
    return NavCue('Đang tìm $_nameVi. Xoay người chậm.');
  }

  /// Quiet mode, sight loss and cancel are handled in a later task; [quiet]
  /// and [sightLost] are accepted now so callers need not change.
  NavCue? update({
    required List<TrackedObject> tracks,
    required Size frame,
    LidarReading? lidarCenter,
    bool quiet = false,
    bool sightLost = false,
    required DateTime now,
  }) {
    switch (_state) {
      case NavState.idle:
        return null;
      case NavState.searching:
        return _updateSearching(tracks, frame, lidarCenter, now);
      case NavState.guiding:
        return _updateGuiding(tracks, frame, lidarCenter, now);
      case NavState.lost:
        return null;
    }
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
      return NavCue(
        'Thấy $_nameVi ${_entryPhrase(_norm(target, frame), level)}.',
      );
    }
    if (now.difference(_searchStart!) >= searchTimeout) {
      return _end(
        'Không tìm thấy $_nameVi. Đã dừng dẫn đường.',
        NavEnd.notFound,
      );
    }
    if (now.difference(_lastSearchCue!) >= searchReminder) {
      _lastSearchCue = now;
      return NavCue('Đang tìm $_nameVi. Xoay người chậm.');
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
    // Target not visible: no cue yet (loss classification comes later).
    if (target == null) return null;

    final arrived = _observe(target, frame, lidar, now);
    if (arrived) {
      return _end(
        'Đã tới. ${_capitalized(_nameVi)} ngay trước mặt. Dò bằng gậy.',
        NavEnd.arrived,
      );
    }

    final dx = _norm(target, frame).center.dx - 0.5;
    final level = _rank(_levelOf(target));

    // Distance beats lateral cues.
    if (level > _announcedLevel) {
      _announcedLevel = level;
      return NavCue(
        level == _rank(DistanceLevel.near) ? 'Sắp tới.' : 'Gần hơn rồi.',
      );
    }

    if (_lateralSince != null &&
        now.difference(_lateralSince!) >= holdLateral &&
        (_lastLateralCue == null ||
            _lateralSign != _lastSpokenSide ||
            now.difference(_lastLateralCue!) >= lateralRepeat)) {
      _lastLateralCue = now;
      _lastSpokenSide = _lateralSign;
      _lateralSpoken = true;
      return NavCue(dx < 0 ? 'Lệch trái.' : 'Lệch phải.');
    }

    if (_lateralSpoken && dx.abs() < backToStraight) {
      _lateralSpoken = false;
      _lastLateralCue = null;
      _lastSpokenSide = 0;
      return const NavCue('Thẳng rồi.');
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

  String _entryPhrase(Rect box, DistanceLevel level) {
    final dx = box.center.dx - 0.5;
    final dir = dx < -clockThreshold
        ? 'ở hướng 11 giờ'
        : dx > clockThreshold
        ? 'ở hướng 1 giờ'
        : 'ở phía trước';
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
