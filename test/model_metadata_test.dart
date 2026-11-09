import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/models/scene_info.dart';
import 'package:smart_eye/services/detection/model_metadata.dart';
import 'package:smart_eye/utils/label_catalog.dart';

void main() {
  group('ModelMetadata', () {
    test('đọc được tên lớp + kích thước ảnh từ model thật của app', () {
      final bytes = File('assets/models/yolov8n_int8.tflite').readAsBytesSync();
      final meta = ModelMetadata.parse(bytes);
      expect(meta.imageSize, 320);
      expect(meta.names, hasLength(80));
      expect(meta.names!.first, 'person');
      expect(meta.names![3], 'motorcycle');
      // Khớp file nhãn dự phòng
      final labels = File('assets/labels/coco.txt')
          .readAsLinesSync()
          .where((l) => l.trim().isNotEmpty)
          .toList();
      expect(meta.names, labels);
    });

    test('model không có metadata → rỗng, không ném lỗi', () {
      final meta = ModelMetadata.parse(Uint8List.fromList(List.filled(100, 7)));
      expect(meta.names, isNull);
      expect(meta.imageSize, isNull);
    });

    test(
      'model v4 (smart_eye.tflite): 27 lớp, lớp nào cũng có nhóm nguy hiểm',
      () {
        final bytes = File('assets/models/smart_eye.tflite').readAsBytesSync();
        final names = ModelMetadata.parse(bytes).names;
        expect(names, hasLength(27));
        for (final name in names!) {
          expect(
            categoryOf(name),
            isNot(ObjectCategory.other),
            reason: 'categoryOf("$name")',
          );
          expect(isDetectionRelevant(name), isTrue, reason: name);
          expect(labelVi[name], isNotNull, reason: 'labelVi["$name"]');
        }
      },
    );
  });
}
