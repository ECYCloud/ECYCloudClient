import '../../l10n/l10n.dart';
import 'profile_assembler.dart';
import 'speed_probe_config.dart';

class ProfileFormatException extends ProfileAssemblyException {
  ProfileFormatException(List<String> issues)
    : issues = List<String>.unmodifiable(issues),
      super('${L10n.t('面板配置不规范')}\n${issues.join('\n')}');

  final List<String> issues;
}

class ProfileInspector {
  static const int _maxIssues = 20;

  static const Set<String> _builtins = <String>{
    'direct',
    'reject',
    'reject-drop',
    'reject-tinygif',
    'pass',
    'compatible',
    'dns',
  };

  static const Set<String> _skipTargetTypes = <String>{
    'and',
    'or',
    'not',
    'sub-rule',
  };

  // 组网类出站会让内核加入外部 P2P 网络、开监听口或充当出口节点，等于替用户开了看不见的入站
  static const Set<String> _meshTypes = <String>{
    'easytier',
    'tailscale',
    'zerotier',
  };

  static List<String> inspect(Map<String, dynamic> remote) {
    final List<String> issues = <String>[];
    final Set<String> names = <String>{};
    final Set<String> providers = <String>{};

    final Object? proxyProviders = remote['proxy-providers'];
    final Object? panelNodes = proxyProviders is Map
        ? proxyProviders['ecy-panel-nodes']
        : null;
    _inspectProxies(
      panelNodes is Map ? panelNodes['payload'] : remote['proxies'],
      issues,
      names,
    );
    final Set<String> nodeProviders = <String>{};
    _inspectProviders(
      remote['proxy-providers'],
      'proxy-providers',
      issues,
      nodeProviders,
    );
    _inspectMeshNodes(<Object?>[
      remote['proxies'],
      if (proxyProviders is Map)
        for (final Object? provider in proxyProviders.values)
          if (provider is Map) provider['payload'],
    ], issues);
    _inspectGroups(remote['proxy-groups'], issues, names, nodeProviders);
    if (names.contains(SpeedProbeConfig.groupName)) {
      issues.add(
        L10n.t('面板配置占用了客户端测速名称：{0}', <Object>[SpeedProbeConfig.groupName]),
      );
    }
    _inspectProviders(
      remote['rule-providers'],
      'rule-providers',
      issues,
      providers,
    );
    _inspectRules(remote['rules'], issues, names, providers);
    _inspectDns(remote['dns'], issues);
    final Object? geox = remote['geox-url'];
    if (geox is Map) {
      geox.forEach((Object? key, Object? url) {
        if (!_httpsUrl(url)) {
          issues.add(L10n.t('geox-url「{0}」必须使用 https', <Object>['$key']));
        }
      });
    }

    if (issues.length <= _maxIssues) {
      return issues;
    }
    final int extra = issues.length - _maxIssues;
    return <String>[
      ...issues.take(_maxIssues),
      L10n.t('另有 {0} 项问题未列出', <Object>[extra]),
    ];
  }

  static void ensureValid(Map<String, dynamic> remote) {
    final List<String> issues = inspect(remote);
    if (issues.isNotEmpty) {
      throw ProfileFormatException(issues);
    }
  }

  static void _inspectProxies(
    Object? raw,
    List<String> issues,
    Set<String> names,
  ) {
    if (raw is! List) {
      issues.add(raw == null ? L10n.t('面板未下发任何可用节点') : L10n.t('节点列表格式不对'));
      return;
    }
    if (raw.isEmpty) {
      issues.add(L10n.t('面板未下发任何可用节点'));
      return;
    }

    final Set<String> seen = <String>{};
    for (int i = 0; i < raw.length; i++) {
      final Object? item = raw[i];
      if (item is! Map) {
        issues.add(L10n.t('第 {0} 个节点不是一条完整配置', <Object>[i + 1]));
        continue;
      }
      final String name = '${item['name'] ?? ''}'.trim();
      final String type = '${item['type'] ?? ''}'.trim();
      if (name.isEmpty) {
        issues.add(L10n.t('第 {0} 个节点没有名称', <Object>[i + 1]));
      } else if (!seen.add(name)) {
        issues.add(L10n.t('节点名重复：{0}', <Object>[name]));
      } else {
        names.add(name);
      }
      if (type.isEmpty) {
        issues.add(L10n.t('第 {0} 个节点没有类型', <Object>[i + 1]));
      }
    }
  }

  static void _inspectMeshNodes(List<Object?> lists, List<String> issues) {
    for (final Object? list in lists) {
      if (list is! List) {
        continue;
      }
      for (final Object? item in list) {
        if (item is Map &&
            _meshTypes.contains('${item['type'] ?? ''}'.trim().toLowerCase())) {
          issues.add(
            L10n.t('节点「{0}」是组网类型（{1}），会让内核加入外部网络，客户端不支持', <Object>[
              '${item['name'] ?? ''}',
              '${item['type']}'.trim(),
            ]),
          );
        }
      }
    }
  }

  static void _inspectGroups(
    Object? raw,
    List<String> issues,
    Set<String> names,
    Set<String> providers,
  ) {
    if (raw is! List) {
      issues.add(raw == null ? L10n.t('面板配置缺少策略组') : L10n.t('策略组列表格式不对'));
      return;
    }
    if (raw.isEmpty) {
      issues.add(L10n.t('面板配置缺少策略组'));
      return;
    }

    final List<({int index, String name, List<Object?> members})> groups =
        <({int index, String name, List<Object?> members})>[];
    final Set<String> seen = <String>{};

    for (int i = 0; i < raw.length; i++) {
      final Object? item = raw[i];
      if (item is! Map) {
        issues.add(L10n.t('第 {0} 个策略组不是一条完整配置', <Object>[i + 1]));
        continue;
      }
      final String name = '${item['name'] ?? ''}'.trim();
      final String type = '${item['type'] ?? ''}'.trim();
      if (name.isEmpty) {
        issues.add(L10n.t('第 {0} 个策略组没有名称', <Object>[i + 1]));
      } else if (names.contains(name) || !seen.add(name)) {
        issues.add(L10n.t('策略组名重复：{0}', <Object>[name]));
      } else {
        names.add(name);
      }
      if (type.isEmpty) {
        issues.add(L10n.t('第 {0} 个策略组没有类型', <Object>[i + 1]));
      }
      final Object? members = item['proxies'];
      final Object? use = item['use'];
      if (use is List) {
        for (final Object? provider in use) {
          if (provider is! String || !providers.contains(provider)) {
            issues.add(
              L10n.t('策略组「{0}」的成员「{1}」不存在', <Object>[name, '$provider']),
            );
          }
        }
      }
      if ((members is! List || members.isEmpty) &&
          (use is! List || use.isEmpty)) {
        issues.add(
          L10n.t('策略组「{0}」没有成员', <Object>[
            name.isEmpty ? L10n.t('第 {0} 个', <Object>[i + 1]) : name,
          ]),
        );
        continue;
      }
      groups.add((
        index: i,
        name: name,
        members: members is List ? members : <Object?>[],
      ));
    }

    for (final ({int index, String name, List<Object?> members}) group
        in groups) {
      for (final Object? member in group.members) {
        final String ref = '$member'.trim();
        if (ref.isEmpty ||
            names.contains(ref) ||
            _builtins.contains(ref.toLowerCase())) {
          continue;
        }
        issues.add(
          L10n.t('策略组「{0}」的成员「{1}」不存在', <Object>[
            group.name.isEmpty
                ? L10n.t('第 {0} 个', <Object>[group.index + 1])
                : group.name,
            ref,
          ]),
        );
      }
    }
  }

  static void _inspectProviders(
    Object? raw,
    String section,
    List<String> issues,
    Set<String>? names,
  ) {
    if (raw == null) {
      return;
    }
    if (raw is! Map) {
      issues.add(
        L10n.t(
          section == 'proxy-providers' ? '节点订阅这一段不是一组完整设置' : '规则集这一段不是一组完整设置',
        ),
      );
      return;
    }

    raw.forEach((Object? key, Object? value) {
      final String name = '$key'.trim();
      if (name.isEmpty) {
        return;
      }
      names?.add(name);
      if (value is! Map) {
        issues.add(
          L10n.t(
            section == 'proxy-providers'
                ? '节点订阅「{0}」不是一条完整配置'
                : '规则集「{0}」不是一条完整配置',
            <Object>[name],
          ),
        );
        return;
      }
      final String type = '${value['type'] ?? ''}'.trim();
      if (type.isEmpty) {
        issues.add(
          L10n.t(
            section == 'proxy-providers' ? '节点订阅「{0}」没有类型' : '规则集「{0}」没有类型',
            <Object>[name],
          ),
        );
      }
      final Iterable<Object?> paths = _fields(value, 'path');
      final Iterable<Object?> urls = _fields(value, 'url');
      if (section == 'rule-providers' &&
          !paths.any((Object? path) => '${path ?? ''}'.trim().isNotEmpty)) {
        issues.add(L10n.t('规则集「{0}」没有保存路径', <Object>[name]));
      }
      if (!paths.every(_safeProviderPath)) {
        issues.add(L10n.t('「{0}」的保存路径必须位于运行目录内，且不能覆盖客户端文件', <Object>[name]));
      }
      if (section == 'proxy-providers' &&
          name.startsWith('ecy-panel-') &&
          ((name != 'ecy-panel-nodes' &&
                  !RegExp(r'^ecy-panel-[a-f0-9]{64}$').hasMatch(name)) ||
              value['type'] != 'file' ||
              value['path'] != '$name.json' ||
              value['payload'] is! List ||
              (value['payload'] as List).isEmpty)) {
        issues.add(L10n.t('节点订阅「{0}」不是一条完整配置', <Object>[name]));
      }
      if (type == 'http' &&
          !urls.any((Object? url) => '${url ?? ''}'.trim().isNotEmpty)) {
        issues.add(
          L10n.t(
            section == 'proxy-providers'
                ? '节点订阅「{0}」是在线下载，但没有地址'
                : '规则集「{0}」是在线下载，但没有地址',
            <Object>[name],
          ),
        );
      } else if (!urls.every(_httpsUrl)) {
        issues.add(
          L10n.t(
            section == 'proxy-providers'
                ? '节点订阅「{0}」的下载地址必须使用 https'
                : '规则集「{0}」的下载地址必须使用 https',
            <Object>[name],
          ),
        );
      }
      final String format = '${value['format'] ?? ''}'.trim().toLowerCase();
      final String behavior = '${value['behavior'] ?? ''}'.trim().toLowerCase();
      if (format == 'mrs' && behavior == 'classical') {
        issues.add(L10n.t('「{0}」把逐条规则存成了 mrs 格式，这样无法使用', <Object>[name]));
      }
    });
  }

  // 内核取 provider 字段时名字不分大小写（mihomo common/structure）：URL、PATH 这类变体一样会被拿去下载、落盘，
  // 同时存在多个变体时逐个检查
  static Iterable<Object?> _fields(Map<Object?, Object?> value, String key) =>
      value.entries
          .where(
            (MapEntry<Object?, Object?> field) =>
                '${field.key}'.toLowerCase() == key,
          )
          .map((MapEntry<Object?, Object?> field) => field.value);

  // 明文下载会被链路上替换规则集、节点订阅与地理数据库：只检查不改写，没有地址的本地 provider 不受影响
  static bool _httpsUrl(Object? value) {
    final String url = '${value ?? ''}'.trim().toLowerCase();
    return url.isEmpty || url.startsWith('https://');
  }

  static bool _safeProviderPath(Object? path) {
    if (path is! String ||
        path.isEmpty ||
        path.startsWith('/') ||
        // ~ 可组成 Windows 8.3 短文件名（CONFIG~1.JSO），绕过下面按字面比对的保留文件名
        RegExp(r'[\\:~\x00-\x1f\x7f]').hasMatch(path)) {
      return false;
    }
    final List<String> parts = path
        .split('/')
        .where((String part) => part != '.')
        .toList();
    if (parts.isEmpty ||
        parts.any(
          (String part) =>
              part.isEmpty ||
              part == '..' ||
              part.endsWith('.') ||
              part.endsWith(' ') ||
              RegExp(
                r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
                caseSensitive: false,
              ).hasMatch(part),
        )) {
      return false;
    }
    return !RegExp(
      r'^(config\.json|config\.check\.json|cache\.db|proxy-snapshot\.json|geoip\.metadb|geosite\.dat|geoip\.dat|asn\.mmdb|bundlemrs\.7z)(\.|$)|^\.validate-',
      caseSensitive: false,
    ).hasMatch(parts.first);
  }

  static void _inspectRules(
    Object? raw,
    List<String> issues,
    Set<String> names,
    Set<String> providers,
  ) {
    if (raw is! List) {
      issues.add(raw == null ? L10n.t('面板配置缺少分流规则') : L10n.t('分流规则列表格式不对'));
      return;
    }
    if (raw.isEmpty) {
      issues.add(L10n.t('面板配置缺少分流规则'));
      return;
    }

    var hasMatch = false;
    for (int i = 0; i < raw.length; i++) {
      final Object? item = raw[i];
      if (item is! String) {
        issues.add(L10n.t('第 {0} 条分流规则不是一行文字', <Object>[i + 1]));
        continue;
      }
      final String line = item.trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      final List<String> parts = <String>[
        for (final String part in line.split(',')) part.trim(),
      ].where((String part) => part.isNotEmpty).toList();
      if (parts.isEmpty) {
        issues.add(L10n.t('第 {0} 条分流规则写错了：{1}', <Object>[i + 1, line]));
        continue;
      }

      final String type = parts.first.toUpperCase();
      if (type == 'MATCH' || type == 'FINAL') {
        hasMatch = true;
      }
      if (type == 'RULE-SET') {
        if (parts.length < 2) {
          issues.add(L10n.t('第 {0} 条分流规则写错了：{1}', <Object>[i + 1, line]));
          continue;
        }
        final String provider = parts[1];
        if (!providers.contains(provider)) {
          issues.add(
            L10n.t('第 {0} 条分流规则用到了规则集「{1}」，但配置里没有这份规则集', <Object>[
              i + 1,
              provider,
            ]),
          );
        }
      }
      if (_skipTargetTypes.contains(type.toLowerCase())) {
        continue;
      }
      final String? target = _ruleTarget(parts);
      if (target == null || target.isEmpty) {
        issues.add(L10n.t('第 {0} 条分流规则写错了：{1}', <Object>[i + 1, line]));
        continue;
      }
      if (!names.contains(target) &&
          !_builtins.contains(target.toLowerCase())) {
        issues.add(L10n.t('规则「{0}」指向了不存在的策略：{1}', <Object>[line, target]));
      }
    }

    if (!hasMatch) {
      issues.add(L10n.t('分流规则缺少最后一条兜底规则'));
    }
  }

  static void _inspectDns(Object? raw, List<String> issues) {
    if (raw != null && raw is! Map) {
      issues.add(L10n.t('DNS 设置不是一组完整配置'));
    }
  }

  static String? _ruleTarget(List<String> parts) {
    if (parts.isEmpty) {
      return null;
    }
    final String last = parts.last;
    if (last.toLowerCase() == 'no-resolve' && parts.length >= 2) {
      return parts[parts.length - 2];
    }
    if (parts.length == 1) {
      return null;
    }
    return last;
  }
}
