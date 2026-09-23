import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/trip.dart';

/// F4 — Lưu lịch sử chuyến đi on-device, riêng tư, không cần mạng.
///
/// Cấu trúc: `<documents>/trips/<id>/meta.json`, `events.jsonl` (CN11), `frames/*.jpg` (CN12).
/// Tự dọn dẹp để không tốn dung lượng: giữ tối đa [maxTrips] chuyến, xoá chuyến cũ hơn [maxAge],
/// mỗi chuyến tối đa [maxFramesPerTrip] ảnh, cách nhau ít nhất [memoryInterval].
class HistoryService {
  static final HistoryService instance = HistoryService._();
  HistoryService._();

  static const int maxTrips = 20;
  static const Duration maxAge = Duration(days: 30);
  static const int maxFramesPerTrip = 40;
  static const Duration memoryInterval = Duration(seconds: 15);

  Directory? _root;
  TripSummary? _current;
  Directory? _currentDir;
  DateTime _lastMemory = DateTime.fromMillisecondsSinceEpoch(0);

  /// Ghi file tuần tự để các dòng JSONL không chen nhau
  Future<void> _writes = Future.value();

  TripSummary? get currentTrip => _current;

  Future<Directory> _rootDir() async {
    if (_root != null) return _root!;
    final docs = await getApplicationDocumentsDirectory();
    _root = Directory('${docs.path}${Platform.pathSeparator}trips');
    await _root!.create(recursive: true);
    return _root!;
  }

  Directory _dirOf(Directory root, String id) => Directory('${root.path}${Platform.pathSeparator}$id');

  // ---------------------------------------------------------------------------
  // Ghi
  // ---------------------------------------------------------------------------

  Future<void> startTrip() async {
    if (_current != null) return;
    final root = await _rootDir();
    await _cleanup(root);

    final now = DateTime.now();
    final id = _idOf(now);
    _currentDir = _dirOf(root, id);
    await Directory('${_currentDir!.path}${Platform.pathSeparator}frames').create(recursive: true);
    _current = TripSummary(id: id, startTime: now);
    log(TripEventType.tripStart, 'Bắt đầu chuyến đi');
  }

  /// Ghi 1 sự kiện. [jpeg]: ảnh thumbnail đính kèm (chỉ lưu nếu còn hạn mức).
  void log(TripEventType type, String text, {double? lat, double? lng, Uint8List? jpeg}) {
    final trip = _current;
    final dir = _currentDir;
    if (trip == null || dir == null) return;

    final now = DateTime.now();
    trip.lastActivity = now;
    switch (type) {
      case TripEventType.danger:
        trip.dangerCount++;
      case TripEventType.caution:
        trip.cautionCount++;
      case TripEventType.description:
        trip.descriptionCount++;
      default:
        break;
    }

    String? image;
    if (jpeg != null && trip.memoryCount < maxFramesPerTrip) {
      image = 'frames/${now.millisecondsSinceEpoch}.jpg';
      trip.memoryCount++;
      _lastMemory = now;
    }

    final event = TripEvent(time: now, type: type, text: text, lat: lat, lng: lng, image: image);
    final meta = jsonEncode(trip.toJson());
    _enqueue(() async {
      if (image != null && jpeg != null) {
        await File('${dir.path}/$image').writeAsBytes(jpeg);
      }
      await File('${dir.path}/events.jsonl')
          .writeAsString('${jsonEncode(event.toJson())}\n', mode: FileMode.append, flush: true);
      await File('${dir.path}/meta.json').writeAsString(meta);
    });
  }

  /// Có nên chụp ảnh ghi nhớ lúc này không (tránh lưu dồn dập)
  bool canCaptureMemory() =>
      _current != null &&
      _current!.memoryCount < maxFramesPerTrip &&
      DateTime.now().difference(_lastMemory) >= memoryInterval;

  void updateDistance(double meters) => _current?.distanceMeters = meters;

  /// Lưu meta hiện tại (gọi khi app vào nền)
  Future<void> flush() {
    final trip = _current;
    final dir = _currentDir;
    if (trip == null || dir == null) return _writes;
    final meta = jsonEncode(trip.toJson());
    _enqueue(() => File('${dir.path}/meta.json').writeAsString(meta));
    return _writes;
  }

  Future<TripSummary?> endTrip() async {
    final trip = _current;
    if (trip == null) return null;
    log(TripEventType.tripEnd, 'Kết thúc chuyến đi');
    trip.endTime = DateTime.now();
    await flush();
    _current = null;
    _currentDir = null;
    return trip;
  }

  void _enqueue(Future<void> Function() job) {
    _writes = _writes.then((_) => job()).catchError((Object e) {
      debugPrint('HistoryService lỗi ghi: $e');
    });
  }

  // ---------------------------------------------------------------------------
  // Đọc
  // ---------------------------------------------------------------------------

  /// Danh sách chuyến đi, mới nhất trước (bao gồm cả chuyến đang diễn ra)
  Future<List<TripSummary>> listTrips() async {
    await _writes;
    final root = await _rootDir();
    final trips = <TripSummary>[];
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final meta = File('${entity.path}/meta.json');
      if (!await meta.exists()) continue;
      try {
        trips.add(TripSummary.fromJson(jsonDecode(await meta.readAsString()) as Map<String, dynamic>));
      } catch (e) {
        debugPrint('Bỏ qua meta hỏng ${meta.path}: $e');
      }
    }
    // Chuyến đang chạy: dùng số liệu mới nhất trong bộ nhớ
    final current = _current;
    if (current != null) {
      trips.removeWhere((t) => t.id == current.id);
      trips.add(current);
    }
    trips.sort((a, b) => b.startTime.compareTo(a.startTime));
    return trips;
  }

  Future<List<TripEvent>> loadEvents(TripSummary trip) async {
    await _writes;
    final file = File('${_dirOf(await _rootDir(), trip.id).path}/events.jsonl');
    if (!await file.exists()) return [];
    final events = <TripEvent>[];
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      try {
        events.add(TripEvent.fromJson(jsonDecode(line) as Map<String, dynamic>));
      } catch (_) {
        // Dòng cuối có thể bị cắt nếu app bị tắt đột ngột → bỏ qua
      }
    }
    return events;
  }

  Future<File> imageFile(TripSummary trip, String relative) async =>
      File('${_dirOf(await _rootDir(), trip.id).path}/$relative');

  Future<void> deleteTrip(TripSummary trip) async {
    if (trip.id == _current?.id) return; // Không xoá chuyến đang chạy
    final dir = _dirOf(await _rootDir(), trip.id);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  // ---------------------------------------------------------------------------
  // Dọn dẹp
  // ---------------------------------------------------------------------------

  Future<void> _cleanup(Directory root) async {
    try {
      final dirs = await root.list().where((e) => e is Directory).cast<Directory>().toList();
      // id dạng yyyyMMdd_HHmmss → sắp xếp chuỗi = sắp xếp thời gian, mới nhất trước
      dirs.sort((a, b) => b.path.compareTo(a.path));
      final cutoff = _idOf(DateTime.now().subtract(maxAge));
      for (int i = 0; i < dirs.length; i++) {
        final id = dirs[i].uri.pathSegments.lastWhere((s) => s.isNotEmpty);
        // Chừa 1 chỗ cho chuyến sắp tạo
        if (i >= maxTrips - 1 || id.compareTo(cutoff) < 0) {
          await dirs[i].delete(recursive: true);
        }
      }
    } catch (e) {
      debugPrint('HistoryService lỗi dọn dẹp: $e');
    }
  }

  static String _idOf(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }
}
