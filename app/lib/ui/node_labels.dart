import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/logger.dart';

/// 与面板 Node::getNodeFlag、regions.json、flagToIsoMap 同算法。
class NodeLabels {
  NodeLabels._();

  static Map<String, String> _regions = const <String, String>{};
  static Map<String, String> _nodeNames = const <String, String>{};
  static RegExp? _words;

  /// 须在首帧前同步加载，[region] 才能同步返回。
  static Future<void> load() async {
    try {
      final Map<String, dynamic> raw =
          jsonDecode(await rootBundle.loadString('assets/regions.json'))
              as Map<String, dynamic>;

      final Map<String, String> regions = <String, String>{
        for (final MapEntry<String, dynamic> entry in raw.entries)
          if (!entry.key.startsWith('_') && entry.value is String)
            entry.key: entry.value as String,
      };

      // 补 ISO 自映射，与面板 flagToIsoMap() 一致
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

  /// 面板按 node-{id} 命名 proxy，身份不随改名变。
  static void configure(
    String flagRegex, [
    Map<String, String> nodeLabels = const <String, String>{},
  ]) {
    _nodeNames = nodeLabels;
    if (flagRegex.trim().isEmpty) {
      _words = null;
      return;
    }
    try {
      _words = _compile(flagRegex);
    } on Object catch (e) {
      Logger.instance.warn('assets', '面板下发的取词正则无法解析：$e');
      _words = null;
    }
  }

  static String? region(String tagOrName) {
    final String name = _resolveName(tagOrName);
    final String? emoji = _fromEmoji(name);
    if (emoji != null) {
      return emoji;
    }

    final RegExp? words = _words;
    if (words == null) {
      return null;
    }

    for (final RegExpMatch match in words.allMatches(name)) {
      final String? code = _regions[match[0]];
      if (code != null) {
        return code.toLowerCase();
      }
    }
    return null;
  }

  static String _resolveName(String tagOrName) =>
      _nodeNames[tagOrName] ?? tagOrName;

  // 与 User\NodeController 的 strcmp(name) 同一套，用面板原名（含国旗 emoji）
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

  /// Windows 表情字体没有旗帜，区域指示符会画成 TW、US；名字只有旗帜时原样返回。
  static String displayName(String tagOrName) {
    final String name = _resolveName(tagOrName);
    final String stripped = name.replaceAll(_flag, '').trim();
    return stripped.isEmpty ? name : stripped;
  }

  static String originalName(String tagOrName) => _resolveName(tagOrName);

  static List<MapEntry<String, String>> _mappedLabels() {
    if (_nodeNames.isEmpty) {
      return const <MapEntry<String, String>>[];
    }
    final List<MapEntry<String, String>> labels =
        <MapEntry<String, String>>[
          for (final String id in _nodeNames.keys)
            if (displayName(id) case final String label when label != id)
              MapEntry<String, String>(id, label),
        ]..sort(
          (MapEntry<String, String> a, MapEntry<String, String> b) =>
              b.key.length.compareTo(a.key.length),
        );
    return labels;
  }

  static String annotateText(String raw) {
    final List<MapEntry<String, String>> labels = _mappedLabels();
    if (labels.isEmpty || raw.isEmpty) {
      return raw;
    }
    String out = raw;
    for (final MapEntry<String, String> entry in labels) {
      out = out.replaceAllMapped(
        RegExp('(?<![\\w-])${RegExp.escape(entry.key)}(?![\\w-])'),
        (_) => entry.value,
      );
    }
    return out;
  }

  static String annotateRuntimeConfig(String raw) {
    final List<MapEntry<String, String>> labels = _mappedLabels();
    if (labels.isEmpty || raw.isEmpty) {
      return raw;
    }
    String out = raw;
    for (final MapEntry<String, String> entry in labels) {
      final String shown =
          '${entry.key}（${entry.value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}）';
      out = out.replaceAll('"${entry.key}"', '"$shown"');
      out = out.replaceAll(',${entry.key}"', ',$shown"');
      out = out.replaceAll(',${entry.key},', ',$shown,');
    }
    return out;
  }

  static IconData groupIcon({required bool selectable}) =>
      selectable ? Icons.tune_outlined : Icons.auto_mode_outlined;

  /// 面板存 PHP 正则，须剥定界符与修饰符。
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
