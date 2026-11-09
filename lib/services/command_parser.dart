import '../models/nav_command.dart';
import '../utils/label_catalog.dart';

class _Entry {
  final String nameVi;
  final Set<String> labels;
  _Entry(this.nameVi, this.labels);
}

class CommandParser {
  static const _from =
      'àáạảãâầấậẩẫăằắặẳẵ'
      'èéẹẻẽêềếệểễ'
      'ìíịỉĩ'
      'òóọỏõôồốộổỗơờớợởỡ'
      'ùúụủũưừứựửữ'
      'ỳýỵỷỹ'
      'đ';
  static const _to =
      'aaaaaaaaaaaaaaaaa'
      'eeeeeeeeeee'
      'iiiii'
      'ooooooooooooooooo'
      'uuuuuuuuuuu'
      'yyyyy'
      'd';
  static final Map<String, String> _foldMap = {
    for (var i = 0; i < _from.length; i++) _from[i]: _to[i],
  };

  static const _stairs = {'stairs up', 'stairs down', 'stairs'};
  static const _verbs = [
    ['di', 'den'],
    ['di', 'toi'],
    ['dan', 'toi'],
    ['dan', 'den'],
    ['den'],
    ['toi'],
    ['tim'],
  ];

  static String fold(String s) {
    final sb = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      sb.write(_foldMap[ch] ?? ch);
    }
    return sb
        .toString()
        .replaceAll(RegExp(r'[̀-ͯ]'), '')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
  }

  static final Map<String, _Entry> _dict = _buildDict();

  static Map<String, _Entry> _buildDict() {
    final d = <String, _Entry>{};
    void add(String nameVi, Iterable<String> labels, [String? key]) {
      final k = key ?? fold(nameVi);
      final e = d.putIfAbsent(k, () => _Entry(nameVi, <String>{}));
      e.labels.addAll(labels);
    }

    labelVi.forEach((en, vi) => add(vi, [en]));
    add('ghế', ['chair'], 'cho ngoi');
    add('bàn', ['dining table'], 'ban an');
    add('cầu thang', _stairs, 'cau thang');
    add('cửa', ['door'], 'cua');
    add('cửa', ['door'], 'cua ra vao');
    return d;
  }

  static Set<String> availableTargets(Iterable<String> modelLabels) => {
    for (final l in modelLabels)
      if (isDetectionRelevant(l) && !ignoredLabels.contains(l)) l,
  };

  static Command parse(String text, Set<String> available) {
    final folded = fold(text);
    if (folded.isEmpty) return Unknown(text);
    final tokens = folded.split(' ');

    if (const {'dung', 'thoi', 'huy'}.contains(tokens.first)) {
      return const Stop();
    }
    if (folded.contains('xung quanh') || folded.startsWith('mo ta')) {
      return const Describe();
    }
    if (folded.contains('tom tat')) return const Recap();

    final padded = ' $folded ';
    _Entry? best;
    var bestKey = '';
    _dict.forEach((k, e) {
      if (k.length > bestKey.length && padded.contains(' $k ')) {
        best = e;
        bestKey = k;
      }
    });
    if (best != null) {
      final hit = best!.labels.intersection(available);
      return hit.isEmpty
          ? UnsupportedTarget(best!.nameVi)
          : NavigateTo(hit, best!.nameVi);
    }

    // Có động từ nhưng không khớp tên nào → trả lại phần sau động từ.
    final words = text
        .split(RegExp(r'\s+'))
        .map(
          (w) => w.replaceAll(
            RegExp(r'^[^\p{L}\p{M}\p{N}]+|[^\p{L}\p{M}\p{N}]+$', unicode: true),
            '',
          ),
        )
        .where((w) => w.isNotEmpty)
        .toList();
    final fw = words.map(fold).toList();
    for (var i = 0; i < fw.length; i++) {
      for (final v in _verbs) {
        if (i + v.length > fw.length) continue;
        var ok = true;
        for (var j = 0; j < v.length; j++) {
          if (fw[i + j] != v[j]) ok = false;
        }
        if (!ok) continue;
        var start = i + v.length;
        if (start < fw.length && (fw[start] == 'cai' || fw[start] == 'cho')) {
          start++;
        }
        if (start >= words.length) return Unknown(text);
        return UnsupportedTarget(words.sublist(start).join(' ').toLowerCase());
      }
    }
    return Unknown(text);
  }

  static List<String> suggestions(Set<String> available) {
    const order = [
      'chair',
      'dining table',
      'bench',
      'person',
      'stairs up',
      'stairs down',
      'stairs',
      'couch',
      'bed',
      'toilet',
      'refrigerator',
      'potted plant',
    ];
    final out = <String>[];
    for (final l in order) {
      if (!available.contains(l)) continue;
      final name = _stairs.contains(l) ? 'cầu thang' : labelVi[l];
      if (name != null && !out.contains(name)) out.add(name);
      if (out.length == 5) break;
    }
    return out;
  }
}
