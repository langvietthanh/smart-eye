import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/models/Recognition.dart';
import 'package:smart_eye/models/scene_info.dart';
import 'package:smart_eye/services/hazard_engine.dart';
import 'package:smart_eye/services/object_tracker.dart';
import 'package:smart_eye/utils/label_catalog.dart';
import 'package:yaml/yaml.dart';

/// training/classes.yaml là nguồn thứ tự lớp khi train; app đọc tên lớp từ metadata model.
/// Test này bảo đảm mọi lớp sẽ train đều được app hiểu: có tên tiếng Việt và đúng nhóm nguy hiểm.
void main() {
  final classes = (loadYaml(File('training/classes.yaml').readAsStringSync())['classes'] as YamlList)
      .cast<YamlMap>()
      .toList();

  test('tên lớp không trùng, alias không trỏ tới 2 lớp khác nhau', () {
    final names = classes.map((c) => c['name'] as String).toList();
    expect(names.toSet(), hasLength(names.length));
    final owner = <String, String>{};
    for (final c in classes) {
      for (final a in [c['name'], ...(c['aliases'] as YamlList)]) {
        final key = (a as String).toLowerCase();
        expect(owner.putIfAbsent(key, () => c['name'] as String), c['name'], reason: 'alias "$key" bị trùng');
      }
    }
  });

  for (final c in classes) {
    final name = c['name'] as String;
    test('lớp "$name": tên tiếng Việt + nhóm nguy hiểm khớp label_catalog.dart', () {
      expect(labelVi[name], c['vi'], reason: 'labelVi["$name"]');
      expect(categoryOf(name).name, c['category'], reason: 'categoryOf("$name")');
    });
  }

  group('Rules cho lớp mới', () {
    const frame = Size(400, 800);

    SceneAssessment run(String en, String vi, double heightRatio) {
      final tracker = ObjectTracker();
      final engine = HazardEngine();
      final h = frame.height * heightRatio;
      final box = Rect.fromLTWH(150, frame.height * 0.95 - h, 100, h);
      var scene = SceneAssessment.empty;
      for (var i = 0; i < 4; i++) {
        scene = engine.assess(tracker.update([Recognition(0, vi, 0.9, box, labelEn: en)], frame, DateTime(2026)), frame);
      }
      return scene;
    }

    test('cột điện rất gần phía trước → Dừng lại', () {
      final alert = run('pole', 'cột', 0.7).alert!;
      expect(alert.level, AlertLevel.danger);
      expect(alert.message, startsWith('Dừng lại! Cột phía trước'));
    });

    test('ổ gà phía trước (chưa xa) → Dừng lại', () {
      expect(run('pothole', 'ổ gà', 0.35).alert?.level, AlertLevel.danger);
    });

    test('mép vỉa hè chỉ nhắc chú ý, không hô dừng lại', () {
      expect(run('curb', 'mép vỉa hè', 0.7).alert?.level, AlertLevel.caution);
      expect(run('curb', 'mép vỉa hè', 0.1).alert, isNull);
    });

    test('cầu thang đi xuống phía trước → Dừng lại, nói rõ hướng', () {
      expect(run('stairs down', 'cầu thang đi xuống', 0.35).alert!.message,
          startsWith('Dừng lại! Có cầu thang đi xuống phía trước!'));
    });
  });
}
