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

  static List<String> inspect(Map<String, dynamic> remote) {
    final List<String> issues = <String>[];
    final Set<String> names = <String>{};
    final Set<String> providers = <String>{};

    _inspectProxies(remote['proxies'], issues, names);
    _inspectGroups(remote['proxy-groups'], issues, names);
    if (names.contains(SpeedProbeConfig.groupName)) {
      issues.add(
        L10n.t('面板配置占用了客户端测速名称：{0}', <Object>[SpeedProbeConfig.groupName]),
      );
    }
    _inspectProviders(remote['rule-providers'], 'rule-providers', issues, providers);
    _inspectProviders(remote['proxy-providers'], 'proxy-providers', issues, null);
    _inspectRules(remote['rules'], issues, names, providers);
    _inspectDns(remote['dns'], issues);

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
      issues.add(
        raw == null
            ? L10n.t('面板未下发任何可用节点')
            : L10n.t('节点列表格式不对'),
      );
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

  static void _inspectGroups(
    Object? raw,
    List<String> issues,
    Set<String> names,
  ) {
    if (raw is! List) {
      issues.add(
        raw == null
            ? L10n.t('面板配置缺少策略组')
            : L10n.t('策略组列表格式不对'),
      );
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
      if (members is! List || members.isEmpty) {
        issues.add(
          L10n.t('策略组「{0}」没有成员', <Object>[
            name.isEmpty ? L10n.t('第 {0} 个', <Object>[i + 1]) : name,
          ]),
        );
        continue;
      }
      groups.add((index: i, name: name, members: members));
    }

    for (final ({int index, String name, List<Object?> members}) group
        in groups) {
      for (final Object? member in group.members) {
        final String ref = '$member'.trim();
        if (ref.isEmpty || names.contains(ref) || _builtins.contains(ref.toLowerCase())) {
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
          section == 'proxy-providers'
              ? '节点订阅这一段不是一组完整设置'
              : '规则集这一段不是一组完整设置',
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
            section == 'proxy-providers'
                ? '节点订阅「{0}」没有类型'
                : '规则集「{0}」没有类型',
            <Object>[name],
          ),
        );
      }
      if (section == 'rule-providers' && '${value['path'] ?? ''}'.trim().isEmpty) {
        issues.add(L10n.t('规则集「{0}」没有保存路径', <Object>[name]));
      }
      if (type == 'http' && '${value['url'] ?? ''}'.trim().isEmpty) {
        issues.add(
          L10n.t(
            section == 'proxy-providers'
                ? '节点订阅「{0}」是在线下载，但没有地址'
                : '规则集「{0}」是在线下载，但没有地址',
            <Object>[name],
          ),
        );
      }
      final String format = '${value['format'] ?? ''}'.trim().toLowerCase();
      final String behavior = '${value['behavior'] ?? ''}'.trim().toLowerCase();
      if (format == 'mrs' && behavior == 'classical') {
        issues.add(
          L10n.t('「{0}」把逐条规则存成了 mrs 格式，这样无法使用', <Object>[name]),
        );
      }
    });
  }

  static void _inspectRules(
    Object? raw,
    List<String> issues,
    Set<String> names,
    Set<String> providers,
  ) {
    if (raw is! List) {
      issues.add(
        raw == null
            ? L10n.t('面板配置缺少分流规则')
            : L10n.t('分流规则列表格式不对'),
      );
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
      if (!names.contains(target) && !_builtins.contains(target.toLowerCase())) {
        issues.add(
          L10n.t('规则「{0}」指向了不存在的策略：{1}', <Object>[line, target]),
        );
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
