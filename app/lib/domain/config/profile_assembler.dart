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

    final Map<String, dynamic> config = <String, dynamic>{...remote};

    template.fallbacks.forEach((String key, Object? value) {
      if (!config.containsKey(key)) {
        config[key] = value;
      }
    });

    config.addAll(template.overrides);

    // 面板下发的 dns.listen 是 0.0.0.0:1053，照抄即对局域网开 DNS 口，allow-lan 管不到；
    // 空串即不监听（dns/server.go 的 ReCreateServer 见 addr == "" 直接 return）
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
