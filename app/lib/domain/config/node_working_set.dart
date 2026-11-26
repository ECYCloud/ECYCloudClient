import 'dart:convert';

import 'package:crypto/crypto.dart';

class NodeWorkingSet {
  NodeWorkingSet._();

  // 交给内核的节点副本上限。两头都随副本数增长：桌面特权侧单条请求上限 4 MiB（每个副本带缩进并转义后约 660 字节），
  // 内核每个副本约占 11 KiB 内存。面板配置超过这个数就只装在用的节点，其余留在界面，用到时再装入
  static const int copyBudget = 5000;

  static const String nodesProvider = 'ecy-panel-nodes';

  // 名字须符合特权侧对节点文件的校验（ecy-panel- 加 64 位十六进制）
  static final String probeProvider =
      'ecy-panel-${sha256.convert(utf8.encode('ecy-probe'))}';

  static const Map<String, String> _placeholder = <String, String>{
    'name': 'ecy-panel-empty',
    'type': 'reject',
  };

  /// 返回要装入内核的节点名；副本数没超过上限时返回 null，表示全部装入。
  static Set<String>? select(
    Map<String, dynamic> config, {
    Iterable<String> pinned = const <String>[],
    int budget = copyBudget,
  }) {
    final Object? providers = config['proxy-providers'];
    if (providers is! Map || providers[nodesProvider] is! Map) {
      return null;
    }
    final List<List<String>> members = <List<String>>[
      for (final MapEntry<dynamic, dynamic> entry in providers.entries)
        if ('${entry.key}'.startsWith('ecy-panel-') &&
            entry.value is Map &&
            (entry.value as Map)['payload'] is List)
          <String>[
            for (final Object? node in (entry.value as Map)['payload'] as List)
              if (node is Map &&
                  node['name'] is String &&
                  node['name'] != _placeholder['name'])
                node['name'] as String,
          ],
    ];
    final Map<String, int> copies = <String, int>{};
    int total = 0;
    for (final List<String> list in members) {
      for (final String name in list) {
        copies[name] = (copies[name] ?? 0) + 1;
        total++;
      }
    }
    if (total <= budget) {
      return null;
    }

    final Set<String> loaded = <String>{};
    int used = 0;
    void add(String name) {
      final int? count = copies[name];
      if (count != null && loaded.add(name)) {
        used += count;
      }
    }

    pinned.forEach(add);
    _required(config).forEach(add);
    // 每个有成员的节点文件至少留一个：分组清空会回落成 REJECT，命中该组的流量全被拒
    for (final List<String> list in members) {
      if (list.isNotEmpty && !list.any(loaded.contains)) {
        add(list.first);
      }
    }
    for (int index = 0; used < budget; index++) {
      bool progressed = false;
      for (final List<String> list in members) {
        if (index >= list.length) {
          continue;
        }
        progressed = true;
        add(list[index]);
        if (used >= budget) {
          break;
        }
      }
      if (!progressed) {
        break;
      }
    }
    return loaded;
  }

  // 分组的初始选中项，以及规则直接指向的节点（面板为每个这样的节点建一个 ecy-panel-target- 分组，
  // filter 是 ^节点名$ 的转义形式）：不装入的话前者落到别的成员上，后者整组清空
  static Iterable<String> _required(Map<String, dynamic> config) sync* {
    final Object? groups = config['proxy-groups'];
    if (groups is! List) {
      return;
    }
    for (final Object? group in groups) {
      if (group is! Map) {
        continue;
      }
      final Object? selected = group['default-selected'];
      if (selected is String) {
        yield selected;
      }
      final Object? filter = group['filter'];
      if ('${group['name']}'.startsWith('ecy-panel-target-') &&
          filter is String &&
          filter.length > 2 &&
          filter.startsWith('^') &&
          filter.endsWith(r'$')) {
        yield filter
            .substring(1, filter.length - 1)
            .replaceAllMapped(RegExp(r'\\(.)'), (Match m) => m[1]!);
      }
    }
  }

  /// 节点文件只保留 [loaded] 里的节点，并附上探测节点文件；[loaded] 为 null 时节点文件原样保留。
  static Map<String, dynamic> restrict(
    Map<String, dynamic> config,
    Set<String>? loaded, [
    List<Object?> probe = const <Object?>[],
  ]) {
    final Object? providers = config['proxy-providers'];
    if (providers is! Map || providers[nodesProvider] is! Map) {
      return config;
    }
    return <String, dynamic>{
      ...config,
      'proxy-providers': <String, dynamic>{
        for (final MapEntry<dynamic, dynamic> entry in providers.entries)
          '${entry.key}':
              loaded != null &&
                  '${entry.key}'.startsWith('ecy-panel-') &&
                  entry.value is Map &&
                  (entry.value as Map)['payload'] is List
              ? <String, dynamic>{
                  ...(entry.value as Map).cast<String, dynamic>(),
                  'payload': _kept(
                    (entry.value as Map)['payload'] as List,
                    loaded,
                  ),
                }
              : entry.value,
        probeProvider: <String, dynamic>{
          'type': 'file',
          'path': '$probeProvider.json',
          'payload': probe.isEmpty ? <Object?>[_placeholder] : probe,
        },
      },
    };
  }

  static List<Object?> _kept(List<dynamic> payload, Set<String> loaded) {
    final List<Object?> kept = <Object?>[
      for (final Object? node in payload)
        if (node is Map && loaded.contains(node['name'])) node,
    ];
    return kept.isEmpty ? <Object?>[_placeholder] : kept;
  }
}
