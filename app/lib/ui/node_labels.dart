import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/logger.dart';

class NodeLabels {
  NodeLabels._();

  static Map<String, String> _regions = const <String, String>{};
  static Map<String, String> _nodeNames = const <String, String>{};
  static RegExp? _words;

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
    final String name = _resolveName(tagOrName);
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
    if (raw.isEmpty) {
      return raw;
    }
    String out = raw;
    for (final MapEntry<String, String> entry in _mappedLabels()) {
      out = out.replaceAllMapped(
        RegExp('(?<![\\w-])${RegExp.escape(entry.key)}(?![\\w-])'),
        (_) => entry.value,
      );
    }
    return out.replaceAll(_nodeIdInText, '');
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
