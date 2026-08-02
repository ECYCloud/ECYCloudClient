import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/logger.dart';

/// 节点地区识别。内核不给地区字段（`/proxies` 每项只有 type / name / udp / history），
/// 面板也不存节点国家，只能从节点名认，两步：
/// 1. 名字自带国旗 emoji 就直接反推 ISO 码，纯字符运算，不查表；
/// 2. 否则用面板下发的取词正则（设置项 `flag_regex`）取词，查随包的 `regions.json`
///    （即面板 `config/regions.json`），与面板 `Node::getNodeFlag()` 同一套算法同一份数据。
class NodeLabels {
  NodeLabels._();

  static Map<String, String> _regions = const <String, String>{};
  static Map<String, String> _nodeNames = const <String, String>{};
  static RegExp? _words;

  /// 映射表随包，要在首帧前就绪，[region] 才能同步返回，界面无须为它做异步分支
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

      // 补全 ISO 自映射（FR => FR），节点名里直接写代码时也能认出来，与面板 flagToIsoMap() 一致
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

  /// 取词正则由面板下发（设置项 `flag_regex`），面板改了客户端下次取配置就跟上；
  /// 没拿到之前只认节点名自带的国旗 emoji。
  /// [nodeLabels]：官方客户端 API 的 tag=>显示名（tag 为 node-{id}）。
  static void configure(String flagRegex, [Map<String, String> nodeLabels = const <String, String>{}]) {
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

  /// 返回 ISO 3166-1 alpha-2 小写代码，与 `assets/flags/<code>.svg` 对应。
  /// [tagOrName] 可能是内核 tag（node-12）或已是显示名。
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

  /// 国旗 emoji 就是两个区域指示符（U+1F1E6..U+1F1FF），减去基点即得两个字母，
  /// 机场节点名普遍自带，认它不需要任何关键词表
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

  /// 展示用的名字：先把 tag 解析为面板下发的节点名，再去掉自带的国旗 emoji。
  /// Windows 的表情字体没有旗帜字形，区域指示符会被原样画成 TW、US，旁边又有
  /// FlagIcon，地区会说两遍。名字里只有旗帜时原样返回，免得整行空掉。
  static String displayName(String tagOrName) {
    final String name = _resolveName(tagOrName);
    final String stripped = name.replaceAll(_flag, '').trim();
    return stripped.isEmpty ? name : stripped;
  }

  static IconData groupIcon({required bool selectable}) =>
      selectable ? Icons.tune_outlined : Icons.auto_mode_outlined;

  /// 面板存的是 PHP 形态的正则（`/[\p{L}\p{N}]+/u`），要剥掉定界符与修饰符
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
