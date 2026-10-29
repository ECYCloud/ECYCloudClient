import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/logger.dart';

class NodeLabels {
  NodeLabels._();

  static Map<String, String> _regions = const <String, String>{};
  static Map<String, String> _nodeNames = const <String, String>{};
  static Map<String, String> _groupNames = const <String, String>{};

  // 面板下发的取词正则不可信：可能是嵌套量词等灾难性回溯模式，一次匹配就能把界面
  // isolate 卡死几十秒（见安全审计 AUD-24）。因此绝不在界面 isolate 上同步跑它——
  // 由 warmRegions 在后台 isolate 内带硬超时预跑，region() 只读缓存。
  static String _flagRegexRaw = '';
  static bool _regexReady = false;
  static final Map<String, String> _regionCache = <String, String>{};
  static int _epoch = 0;

  // 单个名字截断到此长度再喂正则：取词只认前缀里的地区关键词，正常节点名远短于此，
  // 又能给后台 isolate 的良性匹配设一个上界
  static const int _maxSubjectLength = 128;
  static const Duration _warmBudget = Duration(seconds: 2);

  static Future<void> load() async {
    try {
      final Map<String, dynamic> raw = jsonDecode(
        await rootBundle.loadString('assets/regions.json'),
      ) as Map<String, dynamic>;

      final Map<String, String> regions = <String, String>{
        for (final MapEntry<String, dynamic> entry in raw.entries)
          if (!entry.key.startsWith('_') && entry.value is String)
            entry.key: entry.value as String,
      };

      final RegExp iso = RegExp(r'^[A-Z]{2}$');
      for (final String code in regions.values.toList(growable: false)) {
        if (iso.hasMatch(code)) {
          regions.putIfAbsent(code, () => code);
        }
      }

      _regions = regions;
    } on Object catch (e) {
      Logger.instance.warn('assets', '地区映射表缺失，节点不显示旗帜：$e');
    }
  }

  static void configure(
    String flagRegex, [
    Map<String, String> nodeLabels = const <String, String>{},
    Map<String, String> groupLabels = const <String, String>{},
  ]) {
    _nodeNames = nodeLabels;
    _groupNames = groupLabels;
    _flagRegexRaw = flagRegex.trim();
    _regionCache.clear();
    _regexReady = false;
    _epoch++;
  }

  /// 在后台 isolate 内预跑取词正则，把 names 解析出的地区码填进缓存。带硬超时并强杀
  /// isolate：遇到灾难性回溯的正则不会拖住界面，只是这一轮不显示旗帜。仅由控制器在
  /// 装配 / 拉到节点列表后 await 调用。
  static Future<void> warmRegions(Iterable<String> names) async {
    if (_flagRegexRaw.isEmpty) {
      _regexReady = false;
      return;
    }
    final Set<String> subjects = <String>{};
    for (final String raw in names) {
      final String name = _resolveName(raw);
      if (name.isEmpty || _regionCache.containsKey(name)) {
        continue;
      }
      // 自带国旗 emoji 的名字走纯字符运算，不必过正则
      if (_fromEmoji(name) != null) {
        continue;
      }
      subjects.add(
        name.length > _maxSubjectLength
            ? name.substring(0, _maxSubjectLength)
            : name,
      );
    }
    if (subjects.isEmpty) {
      return;
    }

    await _runWarm(_epoch, _flagRegexRaw, subjects, _regions);
  }

  static Future<void> _runWarm(
    int epoch,
    String rawRegex,
    Set<String> subjects,
    Map<String, String> regions,
  ) async {
    final ReceivePort reply = ReceivePort();
    final Isolate isolate = await Isolate.spawn(_warmMain, (
      rawRegex,
      subjects.toList(growable: false),
      regions,
      reply.sendPort,
    ));
    try {
      final Object? msg = await reply.first.timeout(_warmBudget);
      // 期间又 configure 过（切换账户/刷新配置）就丢弃这批结果，别写进新会话
      if (epoch != _epoch) {
        return;
      }
      if (msg is Map) {
        _regionCache.addAll(msg.cast<String, String>());
        _regexReady = true;
      } else {
        _regexReady = false;
        Logger.instance.warn('assets', '面板下发的取词正则无法使用：$msg');
      }
    } on TimeoutException {
      if (epoch == _epoch) {
        _regexReady = false;
        Logger.instance.warn('assets', '面板下发的取词正则匹配超时，本轮不显示旗帜');
      }
    } on Object catch (e) {
      if (epoch == _epoch) {
        _regexReady = false;
        Logger.instance.warn('assets', '面板下发的取词正则预处理失败：$e');
      }
    } finally {
      isolate.kill(priority: Isolate.immediate);
      reply.close();
    }
  }

  static void _warmMain(
    (String, List<String>, Map<String, String>, SendPort) args,
  ) {
    final (
      String rawRegex,
      List<String> subjects,
      Map<String, String> regions,
      SendPort reply,
    ) = args;
    try {
      final RegExp words = _compile(rawRegex);
      final Map<String, String> out = <String, String>{};
      for (final String subject in subjects) {
        for (final RegExpMatch match in words.allMatches(subject)) {
          final String? code = regions[match[0]];
          if (code != null) {
            out[subject] = code.toLowerCase();
            break;
          }
        }
      }
      reply.send(out);
    } on Object catch (e) {
      reply.send('$e');
    }
  }

  static String? region(String tagOrName) {
    final String name = _resolveName(tagOrName);
    final String? emoji = _fromEmoji(name);
    if (emoji != null) {
      return emoji;
    }
    if (!_regexReady) {
      return null;
    }
    final String subject = name.length > _maxSubjectLength
        ? name.substring(0, _maxSubjectLength)
        : name;
    return _regionCache[subject];
  }

  static String _resolveName(String tagOrName) =>
      _nodeNames[tagOrName] ?? tagOrName;

  static int compareName(String a, String b) {
    final List<int> left = utf8.encode(_resolveName(a));
    final List<int> right = utf8.encode(_resolveName(b));
    final int n = left.length < right.length ? left.length : right.length;
    for (int i = 0; i < n; i++) {
      if (left[i] != right[i]) {
        return left[i] - right[i];
      }
    }
    return left.length - right.length;
  }

  static String? _fromEmoji(String name) {
    final RegExpMatch? match = _flag.firstMatch(name);
    if (match == null) {
      return null;
    }

    const int base = 0x1F1E6;
    final List<int> runes = match[0]!.runes.toList(growable: false);
    return String.fromCharCodes(<int>[
      0x61 + runes[0] - base,
      0x61 + runes[1] - base,
    ]);
  }

  static final RegExp _flag = RegExp(
    r'[\u{1F1E6}-\u{1F1FF}]{2}\uFE0F?',
    unicode: true,
  );

  static final RegExp _nodeIdTag = RegExp(r'^node-\d+$');
  static final RegExp _nodeIdInText = RegExp(r'(?<![\w-])node-\d+(?![\w-])');

  static bool _isNodeIdTag(String name) => _nodeIdTag.hasMatch(name);

  static int? officialId(String name) {
    if (!_isNodeIdTag(name)) {
      return null;
    }
    return int.tryParse(name.substring(5));
  }

  static String displayName(String tagOrName) {
    final String name = _groupNames[tagOrName] ?? _resolveName(tagOrName);
    if (_isNodeIdTag(name)) {
      return '';
    }
    final String stripped = name.replaceAll(_flag, '').trim();
    return stripped.isEmpty ? name : stripped;
  }

  static String originalName(String tagOrName) {
    final String name = _resolveName(tagOrName);
    return _isNodeIdTag(name) ? '' : name;
  }

  // 日志页每渲染一行就调一次 annotateText。不缓存的话每次都要重排整张标签表、
  // 再为每个节点重新编译一个正则，滚动时每帧上千次编译，帧预算直接吃光
  static int _labelEpoch = -1;
  static List<MapEntry<String, String>> _labels =
      const <MapEntry<String, String>>[];
  static List<(RegExp, String)> _labelPatterns = const <(RegExp, String)>[];

  // 每条正文要过全部节点的正则，日志页筛选与滚动会反复替换同一批正文；上限对齐日志环形缓冲
  static final Map<String, String> _annotated = <String, String>{};
  static const int _annotatedLimit = 4096;

  static void _ensureLabels() {
    if (_labelEpoch == _epoch) {
      return;
    }
    _labelEpoch = _epoch;
    _annotated.clear();
    _labels =
        <MapEntry<String, String>>[
          for (final String id in <String>{
            ..._nodeNames.keys,
            ..._groupNames.keys,
          })
            if (displayName(id) case final String label when label != id)
              MapEntry<String, String>(id, label),
        ]..sort(
          (MapEntry<String, String> a, MapEntry<String, String> b) =>
              b.key.length.compareTo(a.key.length),
        );
    _labelPatterns = <(RegExp, String)>[
      for (final MapEntry<String, String> entry in _labels)
        (
          RegExp(
            '(?<![\\p{L}\\p{N}_-])${RegExp.escape(entry.key)}(?![\\p{L}\\p{N}_-])',
            unicode: true,
          ),
          entry.value,
        ),
    ];
  }

  static List<MapEntry<String, String>> _mappedLabels() {
    _ensureLabels();
    return _labels;
  }

  static String annotateText(String raw) {
    if (raw.isEmpty) {
      return raw;
    }
    _ensureLabels();
    final String? cached = _annotated[raw];
    if (cached != null) {
      return cached;
    }
    String out = raw;
    for (final (RegExp pattern, String label) in _labelPatterns) {
      out = out.replaceAll(pattern, label);
    }
    if (_annotated.length >= _annotatedLimit) {
      _annotated.clear();
    }
    return _annotated[raw] = out.replaceAll(_nodeIdInText, '');
  }

  static String annotateRuntimeConfig(String raw) {
    if (raw.isEmpty) {
      return raw;
    }
    String out = raw;
    for (final MapEntry<String, String> entry in _mappedLabels()) {
      final String shown = entry.value
          .replaceAll(r'\', r'\\')
          .replaceAll('"', r'\"');
      out = out.replaceAll('"${entry.key}"', '"$shown"');
      out = out.replaceAll(',${entry.key}"', ',$shown"');
      out = out.replaceAll(',${entry.key},', ',$shown,');
    }
    return out.replaceAll(_nodeIdInText, '');
  }

  static IconData groupIcon({required bool selectable}) =>
      selectable ? Icons.tune_outlined : Icons.auto_mode_outlined;

  static RegExp _compile(String raw) {
    final String source = raw.trim();
    final String delimiter = source.substring(0, 1);
    final int end = source.lastIndexOf(delimiter);
    final String pattern = source.substring(1, end);
    final String modifiers = source.substring(end + 1);

    return RegExp(
      pattern,
      unicode: modifiers.contains('u'),
      caseSensitive: !modifiers.contains('i'),
      multiLine: modifiers.contains('m'),
      dotAll: modifiers.contains('s'),
    );
  }
}
