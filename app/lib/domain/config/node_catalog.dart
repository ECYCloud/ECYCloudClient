import 'dart:convert';

typedef CatalogProvider = ({String key, int total, int head});

typedef NodePage = ({String stamp, bool more, List<CatalogNode> nodes});

class CatalogNode {
  const CatalogNode({
    required this.name,
    required this.rank,
    required this.label,
    required this.providers,
    required this.proxy,
  });

  final String name;
  final int rank;
  final String label;
  final List<String> providers;
  final Map<String, dynamic> proxy;

  static CatalogNode? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Object? name = raw['name'];
    final Object? rank = raw['rank'];
    final Object? label = raw['label'];
    final Object? providers = raw['providers'];
    final Object? proxy = raw['proxy'];
    if (name is! String ||
        rank is! int ||
        label is! String ||
        providers is! List ||
        proxy is! Map ||
        proxy['name'] != name) {
      return null;
    }
    return CatalogNode(
      name: name,
      rank: rank,
      label: label,
      providers: providers.whereType<String>().toList(growable: false),
      proxy: Map<String, dynamic>.from(proxy),
    );
  }
}

class NodeCatalog {
  const NodeCatalog({
    required this.stamp,
    required this.providers,
    required this.ranks,
  });

  final String stamp;
  final Map<String, CatalogProvider> providers;
  final Map<String, int> ranks;

  static NodeCatalog? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Object? stamp = raw['stamp'];
    final Object? providers = raw['providers'];
    final Object? ranks = raw['ranks'];
    if (stamp is! String || providers is! Map) {
      return null;
    }
    return NodeCatalog(
      stamp: stamp,
      providers: <String, CatalogProvider>{
        for (final MapEntry<dynamic, dynamic> entry in providers.entries)
          if (entry.value case final Map value
              when entry.key is String &&
                  value['key'] is String &&
                  value['total'] is int &&
                  value['head'] is int)
            entry.key as String: (
              key: value['key'] as String,
              total: value['total'] as int,
              head: value['head'] as int,
            ),
      },
      ranks: <String, int>{
        if (ranks is Map)
          for (final MapEntry<dynamic, dynamic> entry in ranks.entries)
            if (entry.key is String && entry.value is int)
              entry.key as String: entry.value as int,
      },
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'stamp': stamp,
    'providers': <String, dynamic>{
      for (final MapEntry<String, CatalogProvider> entry in providers.entries)
        entry.key: <String, dynamic>{
          'key': entry.value.key,
          'total': entry.value.total,
          'head': entry.value.head,
        },
    },
    'ranks': ranks,
  };

  /// 把 [nodes] 并入面板配置：写进 key 出现在节点 providers 里的每个节点文件，位置按 rank
  /// 插在已有的带序号成员之间，不带序号的成员（模板里写死的节点）位置不动。三端同一套规则。
  ({Map<String, dynamic> config, NodeCatalog catalog}) merge(
    Map<String, dynamic> config,
    Iterable<CatalogNode> nodes,
  ) {
    final Object? files = config['proxy-providers'];
    final List<CatalogNode> incoming = nodes.toList()
      ..sort((CatalogNode a, CatalogNode b) => a.rank.compareTo(b.rank));
    if (files is! Map || incoming.isEmpty) {
      return (config: config, catalog: this);
    }
    return (
      config: <String, dynamic>{
        ...config,
        'proxy-providers': <String, dynamic>{
          for (final MapEntry<dynamic, dynamic> entry in files.entries)
            '${entry.key}': _withNodes(
              entry.value,
              providers[entry.key]?.key,
              incoming,
            ),
        },
      },
      catalog: NodeCatalog(
        stamp: stamp,
        providers: providers,
        ranks: <String, int>{
          ...ranks,
          for (final CatalogNode node in incoming) node.name: node.rank,
        },
      ),
    );
  }

  Object? _withNodes(Object? file, String? key, List<CatalogNode> incoming) {
    final Object? payload = file is Map ? file['payload'] : null;
    if (file is! Map || payload is! List || key == null) {
      return file;
    }
    final Set<Object?> present = <Object?>{
      for (final Object? node in payload)
        if (node is Map) node['name'],
    };
    final List<CatalogNode> added = <CatalogNode>[
      for (final CatalogNode node in incoming)
        if (node.providers.contains(key) && !present.contains(node.name)) node,
    ];
    if (added.isEmpty) {
      return file;
    }
    int? rankOf(Object? node) => node is Map ? ranks[node['name']] : null;
    final int lastRanked = payload.lastIndexWhere(
      (Object? node) => rankOf(node) != null,
    );
    final List<Object?> merged = <Object?>[];
    int next = 0;
    void take(int? below) {
      while (next < added.length &&
          (below == null || added[next].rank < below)) {
        merged.add(jsonDecode(jsonEncode(added[next++].proxy)));
      }
    }

    for (int i = 0; i < payload.length; i++) {
      final Object? node = payload[i];
      if (node is Map && node['name'] == 'ecy-panel-empty') {
        continue;
      }
      take(rankOf(node) ?? -1);
      merged.add(node);
      if (i == lastRanked) {
        take(null);
      }
    }
    take(null);
    return <String, dynamic>{
      ...file.cast<String, dynamic>(),
      'payload': merged,
    };
  }
}
