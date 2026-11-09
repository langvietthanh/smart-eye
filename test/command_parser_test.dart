import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye/models/nav_command.dart';
import 'package:smart_eye/services/command_parser.dart';

Command parse(String t, Set<String> a) => CommandParser.parse(t, a);

Matcher navigateTo(Set<String> labels) =>
    isA<NavigateTo>().having((c) => c.labelsEn, 'labelsEn', labels);

void main() {
  final v4 = {
    'chair',
    'dining table',
    'bench',
    'person',
    'stairs up',
    'stairs down',
    'motorcycle',
  };
  final coco = {
    'chair',
    'dining table',
    'bench',
    'person',
    'motorcycle',
    'motorbike',
  };

  test('fold strips diacritics', () {
    expect(CommandParser.fold('Đi ĐẾN cái Ghế.'), 'di den cai ghe');
  });

  test('navigate commands', () {
    expect(
      parse('đi đến ghế', v4),
      isA<NavigateTo>()
          .having((c) => c.labelsEn, 'l', {'chair'})
          .having((c) => c.nameVi, 'n', 'ghế'),
    );
    expect(parse('Đi tới cái ghế.', v4), navigateTo({'chair'}));
    expect(parse('ờ tìm cái bàn đi', v4), navigateTo({'dining table'}));
    expect(parse('di den ghe', v4), navigateTo({'chair'}));
    expect(parse('tìm chỗ ngồi', v4), navigateTo({'chair'}));
    expect(parse('đi đến ghế băng', v4), navigateTo({'bench'}));
    expect(
      parse('đi đến cầu thang', v4),
      navigateTo({'stairs up', 'stairs down'}),
    );
    expect(parse('tới xe máy', coco), navigateTo({'motorcycle', 'motorbike'}));
    expect(parse('ghế', v4), navigateTo({'chair'}));
  });

  test('other commands', () {
    expect(parse('dừng lại', v4), isA<Stop>());
    expect(parse('thôi', v4), isA<Stop>());
    expect(parse('xung quanh có gì', v4), isA<Describe>());
    expect(parse('tóm tắt', v4), isA<Recap>());
    expect(
      parse('đi đến cửa', v4),
      isA<UnsupportedTarget>().having((c) => c.nameVi, 'n', 'cửa'),
    );
    expect(
      parse('đi đến tủ lạnh', {'chair'}),
      isA<UnsupportedTarget>().having((c) => c.nameVi, 'n', 'tủ lạnh'),
    );
    expect(parse('hôm nay trời đẹp', v4), isA<Unknown>());
    expect(parse('', v4), isA<Unknown>());
  });

  test('unknown name after verb is unsupported', () {
    expect(
      parse('đi đến cái đàn piano', v4),
      isA<UnsupportedTarget>().having((c) => c.nameVi, 'n', 'đàn piano'),
    );
  });

  test('availableTargets and suggestions', () {
    expect(
      CommandParser.availableTargets(['chair', 'cup', 'elephant', 'person']),
      {'chair', 'person'},
    );
    expect(CommandParser.suggestions(v4), [
      'ghế',
      'bàn',
      'ghế băng',
      'người',
      'cầu thang',
    ]);
  });
}
