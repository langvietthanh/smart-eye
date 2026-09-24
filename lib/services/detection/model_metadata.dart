import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Metadata Ultralytics nhúng trong file .tflite (file `metadata.json` trong 1 zip nối ở cuối model):
/// tên lớp, kích thước ảnh... Nhờ đó thay model mới (thêm lớp cầu thang, cột điện...) không cần sửa
/// file nhãn — app tự đọc tên lớp từ chính model.
class ModelMetadata {
  final List<String>? names;
  final int? imageSize;
  final String? description;

  const ModelMetadata({this.names, this.imageSize, this.description});

  static const _localHeader = 0x04034b50; // "PK\x03\x04"
  static final _fileName = utf8.encode('metadata.json');

  /// Đọc metadata từ bytes của model. Không có / hỏng → trả về metadata rỗng (không ném lỗi).
  static ModelMetadata parse(Uint8List bytes) {
    try {
      final json = _findMetadataJson(bytes);
      if (json == null) return const ModelMetadata();
      final map = jsonDecode(json) as Map<String, dynamic>;

      List<String>? names;
      final rawNames = map['names'];
      if (rawNames is Map) {
        final entries = rawNames.entries.map((e) => (int.parse('${e.key}'), '${e.value}')).toList()
          ..sort((a, b) => a.$1.compareTo(b.$1));
        // Chỉ nhận khi chỉ số liên tục 0..n-1 — nếu không, thứ tự lớp không đáng tin
        if (entries.indexed.every((e) => e.$1 == e.$2.$1)) names = [for (final e in entries) e.$2];
      } else if (rawNames is List) {
        names = [for (final n in rawNames) '$n'];
      }

      final imgsz = map['imgsz'];
      return ModelMetadata(
        names: names,
        imageSize: imgsz is List && imgsz.isNotEmpty ? (imgsz.first as num).toInt() : (imgsz is num ? imgsz.toInt() : null),
        description: map['description'] as String?,
      );
    } catch (_) {
      return const ModelMetadata();
    }
  }

  /// Tìm local file header của `metadata.json` (quét từ cuối file — zip nằm sau flatbuffer)
  static String? _findMetadataJson(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    for (var i = bytes.length - 30 - _fileName.length; i >= 0; i--) {
      if (data.getUint32(i, Endian.little) != _localHeader) continue;
      final nameLen = data.getUint16(i + 26, Endian.little);
      if (nameLen != _fileName.length) continue;
      if (!_matches(bytes, i + 30, _fileName)) continue;

      final flags = data.getUint16(i + 6, Endian.little);
      final method = data.getUint16(i + 8, Endian.little);
      final size = data.getUint32(i + 18, Endian.little);
      final extraLen = data.getUint16(i + 28, Endian.little);
      if (flags & 0x8 != 0 && size == 0) return null; // Kích thước nằm ở data descriptor — không hỗ trợ
      final start = i + 30 + nameLen + extraLen;
      if (start + size > bytes.length) return null;
      final raw = Uint8List.sublistView(bytes, start, start + size);
      return switch (method) {
        0 => utf8.decode(raw),
        8 => utf8.decode(ZLibDecoder(raw: true).convert(raw)),
        _ => null,
      };
    }
    return null;
  }

  static bool _matches(Uint8List bytes, int offset, List<int> pattern) {
    for (var j = 0; j < pattern.length; j++) {
      if (bytes[offset + j] != pattern[j]) return false;
    }
    return true;
  }
}
