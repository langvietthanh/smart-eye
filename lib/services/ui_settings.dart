import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Lựa chọn của người dùng trên màn hình camera, giữ lại giữa các lần mở app.
class UiSettings {
  const UiSettings({this.quiet = false, this.autoDescribe = false});

  final bool quiet;
  final bool autoDescribe;

  Map<String, Object> toJson() => {
    'quiet': quiet,
    'autoDescribe': autoDescribe,
  };

  factory UiSettings.fromJson(Object? json) {
    if (json is! Map) return const UiSettings();
    return UiSettings(
      quiet: json['quiet'] == true,
      autoDescribe: json['autoDescribe'] == true,
    );
  }

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/ui_settings.json');
  }

  /// Lỗi đọc file (chưa có, hỏng) → dùng mặc định, không làm hỏng khởi động.
  static Future<UiSettings> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const UiSettings();
      return UiSettings.fromJson(jsonDecode(await file.readAsString()));
    } catch (e) {
      debugPrint('Không đọc được cài đặt: $e');
      return const UiSettings();
    }
  }

  Future<void> save() async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(toJson()));
    } catch (e) {
      debugPrint('Không lưu được cài đặt: $e');
    }
  }
}
