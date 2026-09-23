import 'package:flutter/material.dart';

import '../models/trip.dart';
import '../services/caption_builder.dart';
import '../services/history_service.dart';
import '../services/speech_manager.dart';
import 'trip_detail_screen.dart';

/// F4 — Danh sách chuyến đi đã lưu, nghe tóm tắt (recap) từng chuyến.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final HistoryService _history = HistoryService.instance;
  final SpeechManager _speech = SpeechManager.instance;
  List<TripSummary>? _trips;

  @override
  void initState() {
    super.initState();
    _load(announce: true);
  }

  Future<void> _load({bool announce = false}) async {
    final trips = await _history.listTrips();
    if (!mounted) return;
    setState(() => _trips = trips);
    if (announce) {
      _speech.say(
        trips.isEmpty
            ? 'Chưa có chuyến đi nào được lưu.'
            : 'Có ${trips.length} chuyến đi. Gần nhất: ${CaptionBuilder.recap(trips.first)}',
        SpeechPriority.playback,
        force: true,
      );
    }
  }

  Future<void> _delete(TripSummary trip) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xoá chuyến đi?'),
        content: Text('Xoá toàn bộ sự kiện và ảnh của chuyến ${_title(trip)}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Xoá')),
        ],
      ),
    );
    if (ok != true) return;
    await _history.deleteTrip(trip);
    _speech.say('Đã xoá chuyến đi.', SpeechPriority.playback, force: true);
    _load();
  }

  @override
  void dispose() {
    _speech.stopAll();
    super.dispose();
  }

  static String _title(TripSummary t) {
    String two(int n) => n.toString().padLeft(2, '0');
    final s = t.startTime;
    return '${two(s.hour)}:${two(s.minute)} · ${s.day}/${s.month}/${s.year}';
  }

  @override
  Widget build(BuildContext context) {
    final trips = _trips;
    final currentId = _history.currentTrip?.id;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Lịch sử chuyến đi'),
      ),
      body: trips == null
          ? const Center(child: CircularProgressIndicator())
          : trips.isEmpty
              ? const Center(
                  child: Text('Chưa có chuyến đi nào', style: TextStyle(color: Colors.white70, fontSize: 18)),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: trips.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (_, i) {
                    final trip = trips[i];
                    final recap = CaptionBuilder.recap(trip);
                    final isCurrent = trip.id == currentId;
                    return Card(
                      color: Colors.grey.shade900,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_title(trip)}${isCurrent ? '  (đang diễn ra)' : ''}',
                              style: const TextStyle(color: Colors.yellow, fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 6),
                            Text(recap, style: const TextStyle(color: Colors.white, fontSize: 16)),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: FilledButton.icon(
                                    style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
                                    onPressed: () => _speech.say(recap, SpeechPriority.playback, force: true),
                                    icon: const Icon(Icons.volume_up),
                                    label: const Text('Nghe tóm tắt'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      minimumSize: const Size(0, 52),
                                      foregroundColor: Colors.white,
                                    ),
                                    onPressed: () async {
                                      await _speech.stopAll();
                                      if (!context.mounted) return;
                                      await Navigator.push(
                                        context,
                                        MaterialPageRoute(builder: (_) => TripDetailScreen(trip: trip)),
                                      );
                                    },
                                    icon: const Icon(Icons.list),
                                    label: const Text('Chi tiết'),
                                  ),
                                ),
                                if (!isCurrent)
                                  IconButton(
                                    tooltip: 'Xoá chuyến đi',
                                    onPressed: () => _delete(trip),
                                    icon: const Icon(Icons.delete_outline, color: Colors.white70),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
