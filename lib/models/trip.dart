/// Loại sự kiện ghi vào lịch sử chuyến đi (F4)
enum TripEventType { tripStart, tripEnd, danger, caution, description }

extension TripEventTypeText on TripEventType {
  String get vi => switch (this) {
        TripEventType.tripStart => 'Bắt đầu',
        TripEventType.tripEnd => 'Kết thúc',
        TripEventType.danger => 'Nguy hiểm',
        TripEventType.caution => 'Chú ý',
        TripEventType.description => 'Mô tả',
      };
}

/// 1 dòng trong events.jsonl (CN11)
class TripEvent {
  final DateTime time;
  final TripEventType type;
  final String text;
  final double? lat;
  final double? lng;

  /// Tên file ảnh thumbnail tương đối trong thư mục chuyến đi (CN12), nếu có
  final String? image;

  const TripEvent({
    required this.time,
    required this.type,
    required this.text,
    this.lat,
    this.lng,
    this.image,
  });

  Map<String, dynamic> toJson() => {
        't': time.toIso8601String(),
        'type': type.name,
        'text': text,
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
        if (image != null) 'img': image,
      };

  factory TripEvent.fromJson(Map<String, dynamic> j) => TripEvent(
        time: DateTime.parse(j['t'] as String),
        type: TripEventType.values.firstWhere((e) => e.name == j['type'],
            orElse: () => TripEventType.description),
        text: j['text'] as String? ?? '',
        lat: (j['lat'] as num?)?.toDouble(),
        lng: (j['lng'] as num?)?.toDouble(),
        image: j['img'] as String?,
      );
}

/// Thông tin tổng hợp 1 chuyến đi — lưu ở meta.json
class TripSummary {
  final String id;
  final DateTime startTime;
  DateTime lastActivity;
  DateTime? endTime;
  double distanceMeters;
  int dangerCount;
  int cautionCount;
  int descriptionCount;
  int memoryCount;

  TripSummary({
    required this.id,
    required this.startTime,
    DateTime? lastActivity,
    this.endTime,
    this.distanceMeters = 0,
    this.dangerCount = 0,
    this.cautionCount = 0,
    this.descriptionCount = 0,
    this.memoryCount = 0,
  }) : lastActivity = lastActivity ?? startTime;

  Duration get duration => (endTime ?? lastActivity).difference(startTime);

  Map<String, dynamic> toJson() => {
        'id': id,
        'start': startTime.toIso8601String(),
        'last': lastActivity.toIso8601String(),
        if (endTime != null) 'end': endTime!.toIso8601String(),
        'distance': distanceMeters,
        'danger': dangerCount,
        'caution': cautionCount,
        'description': descriptionCount,
        'memory': memoryCount,
      };

  factory TripSummary.fromJson(Map<String, dynamic> j) => TripSummary(
        id: j['id'] as String,
        startTime: DateTime.parse(j['start'] as String),
        lastActivity: DateTime.tryParse(j['last'] as String? ?? ''),
        endTime: DateTime.tryParse(j['end'] as String? ?? ''),
        distanceMeters: (j['distance'] as num?)?.toDouble() ?? 0,
        dangerCount: j['danger'] as int? ?? 0,
        cautionCount: j['caution'] as int? ?? 0,
        descriptionCount: j['description'] as int? ?? 0,
        memoryCount: j['memory'] as int? ?? 0,
      );
}
