import 'dart:io';

import 'package:flutter/material.dart';

import '../models/trip.dart';
import '../services/caption_builder.dart';
import '../services/history_service.dart';
import '../services/speech_manager.dart';

/// F4 — Dòng thời gian 1 chuyến đi: sự kiện + ảnh ghi nhớ, nghe lại toàn bộ bằng TTS.
class TripDetailScreen extends StatefulWidget {
  final TripSummary trip;

  const TripDetailScreen({super.key, required this.trip});

  @override
  State<TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends State<TripDetailScreen> {
  final HistoryService _history = HistoryService.instance;
  final SpeechManager _speech = SpeechManager.instance;
  List<TripEvent>? _events;
  final Map<String, File> _images = {};
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final events = await _history.loadEvents(widget.trip);
    for (final e in events) {
      if (e.image != null) _images[e.image!] = await _history.imageFile(widget.trip, e.image!);
    }
    if (mounted) setState(() => _events = events);
  }

  static String _clock(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  /// Nghe lại lần lượt: tóm tắt → từng cảnh báo / mô tả kèm giờ
  Future<void> _playAll() async {
    final events = _events;
    if (events == null) return;
    setState(() => _playing = true);

    final lines = [
      CaptionBuilder.recap(widget.trip),
      for (final e in events)
        if (e.type != TripEventType.tripStart && e.type != TripEventType.tripEnd)
          'Lúc ${e.time.hour} giờ ${e.time.minute}: ${e.text}',
    ];
    for (final line in lines) {
      if (!_playing || !mounted) break;
      final ok = await _speech.sayAndWait(line, SpeechPriority.playback, force: true);
      if (!ok) break; // Bị dừng / ngắt
    }
    if (mounted) setState(() => _playing = false);
  }

  Future<void> _stop() async {
    setState(() => _playing = false);
    await _speech.stopAll();
  }

  @override
  void dispose() {
    _playing = false;
    _speech.stopAll();
    super.dispose();
  }

  IconData _icon(TripEventType t) => switch (t) {
        TripEventType.danger => Icons.warning_amber,
        TripEventType.caution => Icons.info_outline,
        TripEventType.description => Icons.visibility,
        TripEventType.tripStart => Icons.play_arrow,
        TripEventType.tripEnd => Icons.stop,
      };

  Color _color(TripEventType t) => switch (t) {
        TripEventType.danger => Colors.redAccent,
        TripEventType.caution => Colors.orangeAccent,
        TripEventType.description => Colors.lightBlueAccent,
        _ => Colors.white70,
      };

  @override
  Widget build(BuildContext context) {
    final events = _events;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Chi tiết chuyến đi'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              CaptionBuilder.recap(widget.trip),
              style: const TextStyle(color: Colors.white, fontSize: 17),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                backgroundColor: _playing ? Colors.redAccent : Colors.yellow.shade600,
                foregroundColor: Colors.black,
              ),
              onPressed: events == null ? null : (_playing ? _stop : _playAll),
              icon: Icon(_playing ? Icons.stop : Icons.play_arrow),
              label: Text(_playing ? 'Dừng nghe' : 'Nghe lại toàn bộ', style: const TextStyle(fontSize: 18)),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: events == null
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: events.length,
                    itemBuilder: (_, i) {
                      final e = events[i];
                      final image = e.image == null ? null : _images[e.image!];
                      return Semantics(
                        label: '${e.type.vi} lúc ${e.time.hour} giờ ${e.time.minute}. ${e.text}',
                        excludeSemantics: true,
                        child: Card(
                          color: Colors.grey.shade900,
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(_icon(e.type), color: _color(e.type)),
                                    const SizedBox(width: 8),
                                    Text(
                                      '${_clock(e.time)} · ${e.type.vi}',
                                      style: TextStyle(color: _color(e.type), fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(e.text, style: const TextStyle(color: Colors.white, fontSize: 16)),
                                if (e.lat != null && e.lng != null)
                                  Text(
                                    'GPS: ${e.lat!.toStringAsFixed(5)}, ${e.lng!.toStringAsFixed(5)}',
                                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                                  ),
                                if (image != null) ...[
                                  const SizedBox(height: 8),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.file(
                                      image,
                                      height: 180,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
