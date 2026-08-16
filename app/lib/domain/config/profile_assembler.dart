import 'dart:convert';

import 'local_template.dart';

class ProfileAssemblyException implements Exception {
  ProfileAssemblyException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AssembledProfile {
  const AssembledProfile(this.config, this.json);

  final Map<String, dynamic> config;
  final String json;

  // 首次启动要逐个下载并编译远程 provider，这是等待时间的主要来源，
  // 数量取自配置本身，用来给启动进度提供分母
  int get remoteProviderCount => countRemoteProviders(config);

  // 内核对 rule-providers 与 proxy-providers 用的是同一套 fetcher，完成日志同样是
  // 「[Provider] ...」，两类都要计入，否则进度分子会超过分母
  static int countRemoteProviders(Map<String, dynamic> config) {
    var total = 0;
    for (final String section in const <String>[
      'rule-providers',
      'proxy-providers',
    ]) {
      final Object? providers = config[section];
      if (providers is! Map<String, dynamic>) {
        continue;
      }
      total += providers.values
          .whereType<Map<String, dynamic>>()
          .where((Map<String, dynamic> provider) => provider['type'] == 'http')
          .length;
    }
    return total;
  }
}

class ProfileAssembler {
  const ProfileAssembler();

  AssembledProfile assemble({
    required Map<String, dynamic> remote,
    required LocalTemplate template,
    Map<String, String> selectorDefaults = const <String, String>{},
  }) {
    final Object? proxies = remote['proxies'];
    if (proxies is! List || proxies.isEmpty) {
      throw ProfileAssemblyException('面板未下发任何可用节点');
    }

    final Object? rules = remote['rules'];
    if (rules is! List || rules.isEmpty) {
      throw ProfileAssemblyException('面板配置缺少分流规则');
    }

    // 面板下发的整份配置为底稿：proxies / proxy-groups / rules / rule-providers
    // 以及 dns、sniffer、ntp、hosts 等由面板维护的段一律原样保留
    final Map<String, dynamic> config = <String, dynamic>{...remote};

    template.fallbacks.forEach((String key, Object? value) {
      if (!config.containsKey(key)) {
        config[key] = value;
      }
    });

    config.addAll(template.overrides);

    // dns 段整体归面板（nameserver、fake-ip-filter、fallback-filter 都是有价值的分流
    // 依据），但里面的 listen 是给通用 Clash 客户端「把内核当 DNS 服务器用」准备的：
    // 面板下发 0.0.0.0:1053，照抄就等于无条件对局域网开一个 DNS 口，连 allow-lan 开关
    // 都绕过去了；机上另有 Clash 系客户端时还会撞端口，每次启动在日志面板刷两行红字。
    // 本客户端的 DNS 走 TUN 的 dns-hijack 或代理自身，从不需要这个监听。
    // 整键覆盖会连带丢掉面板那些有价值的键，因此只挖掉这一个子键——空串即不监听
    // （dns/server.go 的 ReCreateServer 见 addr == "" 直接 return）
    final Object? dns = config['dns'];
    if (dns is Map) {
      config['dns'] = <String, dynamic>{
        ...dns.cast<String, dynamic>(),
        'listen': '',
      };
    }

    // NewSelector 的初始 now 是 default-selected。ApplyConfig 先开 TUN 再
    // patchSelectGroup，有落盘选择时必须关掉 store-selected，否则会被盖成首个成员。
    if (selectorDefaults.isNotEmpty) {
      final Object? groups = config['proxy-groups'];
      if (groups is List) {
        final List<Object?> next = <Object?>[
          for (final Object? entry in groups)
            _withSelectorDefault(entry, selectorDefaults),
        ];
        config['proxy-groups'] = next;
        if (_appliedSelectorDefault(next, selectorDefaults)) {
          final Object? profile = config['profile'];
          if (profile is Map) {
            config['profile'] = <String, dynamic>{
              ...profile.cast<String, dynamic>(),
              'store-selected': false,
            };
          }
        }
      }
    }

    return AssembledProfile(
      config,
      const JsonEncoder.withIndent('  ').convert(config),
    );
  }

  static Object? _withSelectorDefault(
    Object? entry,
    Map<String, String> defaults,
  ) {
    if (entry is! Map) {
      return entry;
    }
    final Map<String, dynamic> group = Map<String, dynamic>.from(entry);
    if (group['type'] != 'select') {
      return group;
    }
    final String name = group['name'] as String? ?? '';
    final String? want = defaults[name];
    if (want == null || want.isEmpty) {
      return group;
    }
    final Object? members = group['proxies'];
    if (members is! List || !members.contains(want)) {
      return group;
    }
    group['default-selected'] = want;
    return group;
  }

  static bool _appliedSelectorDefault(
    List<Object?> groups,
    Map<String, String> defaults,
  ) {
    for (final Object? entry in groups) {
      if (entry is! Map) {
        continue;
      }
      final String name = entry['name'] as String? ?? '';
      final String? want = defaults[name];
      if (want != null && entry['default-selected'] == want) {
        return true;
      }
    }
    return false;
  }
}
