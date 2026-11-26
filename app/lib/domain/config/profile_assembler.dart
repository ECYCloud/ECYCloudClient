import 'dart:convert';

import '../../l10n/l10n.dart';

import 'local_template.dart';
import 'network_bypass.dart';
import 'profile_inspector.dart';
import 'speed_probe_config.dart';

class ProfileAssemblyException implements Exception {
  ProfileAssemblyException(this.message);

  final String message;

  @override
  String toString() => L10n.message(message);
}

class AssembledProfile {
  const AssembledProfile(this.config, this.json);

  final Map<String, dynamic> config;
  final String json;

  bool get usesFakeIp {
    final Object? dns = config['dns'];
    return dns is Map &&
        dns['enable'] == true &&
        '${dns['enhanced-mode']}'.toLowerCase() == 'fake-ip';
  }

  // mihomo 解析持久化地址池会修改 cache.db，校验必须使用非持久化的临时池。
  String get validationJson => jsonEncode(<String, dynamic>{
    ...config,
    if (config['proxy-providers'] is Map)
      'proxy-providers': <String, dynamic>{
        for (final MapEntry<String, dynamic> entry
            in (config['proxy-providers'] as Map)
                .cast<String, dynamic>()
                .entries)
          entry.key:
              entry.value is Map &&
                  entry.value['type'] == 'file' &&
                  entry.value['payload'] is List
              ? <String, dynamic>{...entry.value as Map, 'type': 'inline'}
              : entry.value,
      },
    'profile': <String, dynamic>{
      ...(config['profile'] as Map).cast<String, dynamic>(),
      'store-fake-ip': false,
    },
  });

  int get remoteProviderCount => countRemoteProviders(config);

  static List<Map<String, dynamic>> nodesOf(Map<String, dynamic> config) {
    final Object? providers = config['proxy-providers'];
    final Object? panel = providers is Map
        ? providers['ecy-panel-nodes']
        : null;
    final Object? nodes = panel is Map ? panel['payload'] : config['proxies'];
    return nodes is List
        ? nodes
              .whereType<Map>()
              .map((Map node) => Map<String, dynamic>.from(node))
              .toList()
        : const <Map<String, dynamic>>[];
  }

  static List<String> membersOf(Map<String, dynamic> config, Map group) {
    final List<String> members = <String>[
      if (group['proxies'] is List)
        ...(group['proxies'] as List).whereType<String>(),
      if (group['use'] is List && config['proxy-providers'] is Map)
        for (final String name in (group['use'] as List).whereType<String>())
          if ((config['proxy-providers'] as Map)[name] case final Map provider)
            if (provider['payload'] is List)
              for (final Map node
                  in (provider['payload'] as List).whereType<Map>())
                if (node['name'] is String && node['name'] != 'ecy-panel-empty')
                  node['name'] as String,
    ];
    final Object? filter = group['filter'];
    if (group['use'] is List && filter is String && filter.contains('`')) {
      final Set<String> ordered = <String>{};
      for (final String pattern in filter.split('`')) {
        final RegExp? expression = _filterExpression(pattern);
        if (expression != null) {
          ordered.addAll(members.where(expression.hasMatch));
        }
      }
      ordered.addAll(members);
      return ordered.toList();
    }
    return members;
  }

  // filter 是 mihomo 的 regexp2 语法（常带 (?i) 前缀）：Dart 正则不认的写法只放弃排序，不能让装配失败
  static RegExp? _filterExpression(String pattern) {
    final bool ignoreCase = pattern.startsWith('(?i)');
    try {
      return RegExp(
        ignoreCase ? pattern.substring(4) : pattern,
        caseSensitive: !ignoreCase,
      );
    } on FormatException {
      return null;
    }
  }

  static bool canUpdateNodes(
    Map<String, dynamic> before,
    Map<String, dynamic> after,
  ) {
    String signature(
      Map<String, dynamic> config,
    ) => jsonEncode(<String, dynamic>{
      ...config,
      if (config['proxy-groups'] is List)
        'proxy-groups': <Object?>[
          for (final Map group in (config['proxy-groups'] as List).cast<Map>())
            <String, dynamic>{
              for (final MapEntry<String, dynamic> entry
                  in group.cast<String, dynamic>().entries)
                if (entry.key != 'default-selected') entry.key: entry.value,
            },
        ],
      'proxy-providers': <String, dynamic>{
        for (final MapEntry<String, dynamic> entry
            in (config['proxy-providers'] as Map)
                .cast<String, dynamic>()
                .entries)
          entry.key: entry.key.startsWith('ecy-panel-') && entry.value is Map
              ? <String, dynamic>{
                  for (final MapEntry<String, dynamic> field
                      in (entry.value as Map).cast<String, dynamic>().entries)
                    if (field.key != 'payload') field.key: field.value,
                }
              : entry.value,
      },
    });
    return before['proxy-providers'] is Map &&
        after['proxy-providers'] is Map &&
        (before['proxy-providers'] as Map).containsKey('ecy-panel-nodes') &&
        (after['proxy-providers'] as Map).containsKey('ecy-panel-nodes') &&
        signature(before) == signature(after);
  }

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
    ProfileInspector.ensureValid(remote);

    final Map<String, dynamic> config = <String, dynamic>{...remote};

    template.fallbacks.forEach((String key, Object? value) {
      if (!config.containsKey(key)) {
        config[key] = value;
      }
    });

    config.addAll(template.overrides);

    final Object? ntp = config['ntp'];
    if (ntp is Map && ntp.containsKey('write-to-system')) {
      config['ntp'] = <String, dynamic>{
        ...ntp.cast<String, dynamic>(),
        'write-to-system': false,
      };
    }

    // 面板下发的 dns.listen 是 0.0.0.0:1053，照抄即对局域网开 DNS 口，allow-lan 管不到；
    // 空串即不监听（dns/server.go 的 ReCreateServer 见 addr == "" 直接 return）
    final Object? dns = config['dns'];
    if (dns is Map) {
      config['dns'] = <String, dynamic>{
        ...dns.cast<String, dynamic>(),
        'listen': '',
        'ipv6': template.options.ipv6Enabled,
        if (template.options.lanNamesViaSystemDns) ...lanNamesViaSystem(dns),
      };
    }

    if (template.options.proxyChina) {
      final Object? rules = config['rules'];
      if (rules is List) {
        config['rules'] = proxyChinaRules(rules);
      }
    }

    // NewSelector 的初始 now 是 default-selected。ApplyConfig 先开 TUN 再
    // patchSelectGroup，有落盘选择时必须关掉 store-selected，否则会被盖成首个成员。
    if (selectorDefaults.isNotEmpty) {
      final Object? groups = config['proxy-groups'];
      if (groups is List) {
        final List<Object?> next = <Object?>[
          for (final Object? entry in groups)
            _withSelectorDefault(entry, selectorDefaults, config),
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

    SpeedProbeConfig.applyTo(
      config,
      template.options.mixedPort,
      template.clashApi.secret,
    );

    return AssembledProfile(
      config,
      const JsonEncoder.withIndent('  ').convert(config),
    );
  }

  // 与 network_bypass.dart 的 _lanHostSuffixes、helper 的 lanDomains 一致
  static const List<String> lanDnsSuffixes = <String>[
    'lan',
    'home.arpa',
    'internal',
    'localdomain',
  ];

  // 面板已给的后缀不覆盖、按原顺序追加；fake-ip-filter 只在黑名单模式下追加，否则应用拿到的仍是假地址
  static Map<String, dynamic> lanNamesViaSystem(Map<dynamic, dynamic> dns) {
    final Object? policy = dns['nameserver-policy'];
    if (policy != null && policy is! Map) {
      return const <String, dynamic>{};
    }
    final Map<String, dynamic> policies = <String, dynamic>{
      ...?(policy as Map<dynamic, dynamic>?)?.cast<String, dynamic>(),
    };
    for (final String suffix in lanDnsSuffixes) {
      policies.putIfAbsent('+.$suffix', () => 'system');
    }
    final Object? mode = dns['fake-ip-filter-mode'];
    final Object? filter = dns['fake-ip-filter'];
    final bool editFilter =
        (mode == null || mode == 'blacklist') &&
        (filter == null ||
            (filter is List && filter.every((e) => e is String)));
    return <String, dynamic>{
      'nameserver-policy': policies,
      if (editFilter)
        'fake-ip-filter': appendUnique(
          <String>[...?(filter as List<dynamic>?)?.cast<String>()],
          <String>[for (final String suffix in lanDnsSuffixes) '+.$suffix'],
        ),
    };
  }

  // 海外：面板的 GEOSITE,CN / GEOIP,CN 直连规则改走 MATCH 的出站。Apple 与 OpenWrt 同一判定
  static List<Object?> proxyChinaRules(List<Object?> rules) {
    String? fallback;
    for (final Object? rule in rules) {
      final List<String> fields = '$rule'.split(',');
      if (fields.length >= 2 && fields[0].trim().toUpperCase() == 'MATCH') {
        fallback = fields[1].trim();
        break;
      }
    }
    if (fallback == null || fallback.toUpperCase() == 'DIRECT') {
      return rules;
    }
    return <Object?>[
      for (final Object? rule in rules)
        if (rule is String) _proxyChinaRule(rule, fallback) else rule,
    ];
  }

  static String _proxyChinaRule(String rule, String target) {
    final List<String> fields = rule
        .split(',')
        .map((String field) => field.trim())
        .toList();
    if (fields.length < 3 ||
        !const <String>{'GEOIP', 'GEOSITE'}.contains(fields[0].toUpperCase()) ||
        fields[1].toLowerCase() != 'cn' ||
        fields[2].toUpperCase() != 'DIRECT') {
      return rule;
    }
    fields[2] = target;
    return fields.join(',');
  }

  static Object? _withSelectorDefault(
    Object? entry,
    Map<String, String> defaults,
    Map<String, dynamic> config,
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
    if (!AssembledProfile.membersOf(config, group).contains(want)) {
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
