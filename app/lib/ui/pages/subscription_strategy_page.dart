import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../data/api/api_exception.dart';
import '../../data/api/panel_api_client.dart';
import '../../data/models/account.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/group_icon.dart';
import '../widgets/multiline_content_field.dart';
import '../widgets/option_dropdown.dart';
import '../widgets/page_header.dart';
import '../widgets/section_card.dart';
import '../widgets/switch_tile.dart';
import '../../l10n/l10n.dart';

class SubscriptionStrategyPage extends StatefulWidget {
  const SubscriptionStrategyPage({super.key});

  @override
  State<SubscriptionStrategyPage> createState() =>
      _SubscriptionStrategyPageState();
}

class _SubscriptionStrategyPageState extends State<SubscriptionStrategyPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  SubscriptionConfig? _config;
  String? _error;
  bool _loading = true;
  bool _busy = false;

  final Set<String> _disabled = <String>{};
  final TextEditingController _hosts = TextEditingController();
  final TextEditingController _rules = TextEditingController();
  final TextEditingController _groupName = TextEditingController();
  final TextEditingController _groupIcon = TextEditingController();
  final TextEditingController _providerUrl = TextEditingController();
  final FocusNode _groupNameFocus = FocusNode();
  final FocusNode _providerUrlFocus = FocusNode();
  final List<CustomProxyGroup> _customGroups = <CustomProxyGroup>[];
  final List<CustomRuleProvider> _customRuleProviders = <CustomRuleProvider>[];
  final Set<String> _draftProxies = <String>{};
  bool _draftIncludeNodes = true;
  String _draftPolicy = 'DIRECT';
  int? _editingGroupIdx;
  int? _editingProviderIdx;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    unawaited(_load());
  }

  @override
  void dispose() {
    _tabs.dispose();
    _hosts.dispose();
    _rules.dispose();
    _groupName.dispose();
    _groupIcon.dispose();
    _providerUrl.dispose();
    _groupNameFocus.dispose();
    _providerUrlFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final PanelApiClient? api = AppScope.of(context).auth.api;
    if (api == null) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final SubscriptionConfig config = await api.fetchSubscriptionConfig();
      if (!mounted) {
        return;
      }
      setState(() {
        _config = config;
        _disabled
          ..clear()
          ..addAll(config.disabledGroups);
        _hosts.text = config.customHosts;
        _rules.text = config.customRules;
        _customGroups
          ..clear()
          ..addAll(config.customGroups);
        _customRuleProviders
          ..clear()
          ..addAll(config.customRuleProviders);
        _clearGroupForm();
        _clearProviderForm();
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = e is ApiException ? e.message : L10n.t('加载失败：{0}', <Object>[e]);
        _loading = false;
      });
    }
  }

  Future<void> _save(Map<String, dynamic> body) async {
    final PanelApiClient? api = AppScope.of(context).auth.api;
    if (api == null || _busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final String msg = await api.saveSubscriptionConfig(body);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg.isEmpty ? L10n.t('保存成功') : msg),
          behavior: SnackBarBehavior.floating,
        ),
      );
      await _load();
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating),
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  String? _groupToggleIcon(SubscriptionConfig config, String name) {
    final String? builtIn = config.groupIcons[name];
    if (builtIn != null && builtIn.isNotEmpty) {
      return builtIn;
    }
    for (final CustomProxyGroup group in _customGroups) {
      if (group.name == name) {
        return group.icon;
      }
    }
    return null;
  }

  void _clearGroupForm() {
    _groupName.clear();
    _groupIcon.clear();
    _draftIncludeNodes = true;
    _draftProxies.clear();
    _editingGroupIdx = null;
  }

  void _beginEditGroup(int i) {
    final CustomProxyGroup group = _customGroups[i];
    setState(() {
      _editingGroupIdx = i;
      _groupName.text = group.name;
      _groupIcon.text = group.icon ?? '';
      _draftIncludeNodes = group.includeNodes;
      _draftProxies
        ..clear()
        ..addAll(group.proxies);
    });
    _groupNameFocus.requestFocus();
  }

  void _persistCustomGroups() {
    unawaited(
      _save(<String, dynamic>{
        'custom_groups': jsonEncode(
          <Map<String, dynamic>>[
            for (final CustomProxyGroup g in _customGroups) g.toJson(),
          ],
        ),
      }),
    );
  }

  Future<void> _removeCustomGroup(int i) async {
    if (i < 0 || i >= _customGroups.length) {
      return;
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(L10n.t('确认删除')),
        content: Text(
          L10n.t('确定要删除自定义策略组「{0}」吗？', <Object>[
            _customGroups[i].name,
          ]),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L10n.t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L10n.t('确定')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) {
      return;
    }
    setState(() {
      _disabled.remove(_customGroups[i].name);
      _customGroups.removeAt(i);
      if (_editingGroupIdx == i) {
        _clearGroupForm();
      } else if (_editingGroupIdx != null && _editingGroupIdx! > i) {
        _editingGroupIdx = _editingGroupIdx! - 1;
      }
    });
    _persistCustomGroups();
  }

  void _commitCustomGroup({int? replaceAt}) {
    final SubscriptionConfig? config = _config;
    if (config == null) {
      return;
    }
    final String name = _groupName.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.t('请填写策略组名称')),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (replaceAt == null &&
        _customGroups.length >= config.maxCustomGroups) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.t('最多添加 {0} 个自定义策略组', <Object>[config.maxCustomGroups])),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (_customGroups.asMap().entries.any(
      (MapEntry<int, CustomProxyGroup> e) =>
          e.value.name == name && e.key != replaceAt,
    )) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.t('策略组名称已存在')),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final String icon = _groupIcon.text.trim();
    if (icon.isNotEmpty &&
        !(icon.startsWith('http://') ||
            icon.startsWith('https://') ||
            icon.startsWith('/'))) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.t('图标须为 http(s) 链接或站点根路径')),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final CustomProxyGroup group = CustomProxyGroup(
      name: name,
      icon: icon.isEmpty ? null : icon,
      includeNodes: _draftIncludeNodes,
      proxies: <String>[
        for (final String n in config.availableProxyNames)
          if (_draftProxies.contains(n)) n,
      ],
    );
    setState(() {
      if (replaceAt != null) {
        _customGroups[replaceAt] = group;
      } else {
        _customGroups.add(group);
      }
      _clearGroupForm();
    });
    _persistCustomGroups();
  }

  List<String> _policyNames(SubscriptionConfig config) {
    const List<String> builtins = <String>[
      'DIRECT',
      'REJECT',
      'REJECT-TINYGIF',
    ];
    final Set<String> seen = <String>{};
    final List<String> out = <String>[];
    void add(String name) {
      if (name.isNotEmpty && seen.add(name)) {
        out.add(name);
      }
    }

    for (final String name in builtins) {
      add(name);
    }
    for (final String name in config.allGroupNames) {
      add(name);
    }
    for (final CustomProxyGroup group in config.customGroups) {
      add(group.name);
    }
    return out;
  }

  void _clearProviderForm() {
    _providerUrl.clear();
    _draftPolicy = 'DIRECT';
    _editingProviderIdx = null;
  }

  void _beginEditProvider(int i) {
    final CustomRuleProvider provider = _customRuleProviders[i];
    setState(() {
      _editingProviderIdx = i;
      _providerUrl.text = provider.url;
      _draftPolicy = provider.policy;
    });
    _providerUrlFocus.requestFocus();
  }

  void _removeRuleProvider(int i) {
    setState(() {
      _customRuleProviders.removeAt(i);
      if (_editingProviderIdx == i) {
        _clearProviderForm();
      } else if (_editingProviderIdx != null && _editingProviderIdx! > i) {
        _editingProviderIdx = _editingProviderIdx! - 1;
      }
    });
  }

  void _commitRuleProvider({int? replaceAt}) {
    final SubscriptionConfig? config = _config;
    if (config == null) {
      return;
    }
    final String url = _providerUrl.text.trim();
    final List<String> policies = _policyNames(config);
    final String policy = policies.contains(_draftPolicy)
        ? _draftPolicy
        : (policies.isNotEmpty ? policies.first : '');
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.t('请填写规则集 URL')),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (!(url.startsWith('http://') || url.startsWith('https://'))) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.t('URL 须为 http(s) 链接')),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (policy.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.t('请选择策略')),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (replaceAt == null &&
        _customRuleProviders.length >= config.maxCustomRuleProviders) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.t('最多添加 {0} 个远程规则集', <Object>[config.maxCustomRuleProviders])),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final CustomRuleProvider? old =
        replaceAt != null ? _customRuleProviders[replaceAt] : null;
    final bool sameUrl = old != null && old.url == url;
    final CustomRuleProvider provider = CustomRuleProvider(
      name: sameUrl ? old.name : '',
      url: url,
      policy: policy,
      behavior: sameUrl ? old.behavior : '',
      format: sameUrl ? old.format : '',
      interval: sameUrl ? old.interval : 0,
    );
    setState(() {
      if (replaceAt != null) {
        _customRuleProviders[replaceAt] = provider;
      } else {
        _customRuleProviders.add(provider);
      }
      _clearProviderForm();
    });
    if (replaceAt != null) {
      unawaited(
        _save(<String, dynamic>{
          'custom_rule_providers': jsonEncode(
            <Map<String, dynamic>>[
              for (final CustomRuleProvider p in _customRuleProviders)
                p.toJson(),
            ],
          ),
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SubscriptionConfig? config = _config;

    return Scaffold(
      body: Column(
        children: <Widget>[
          SafeArea(
            bottom: false,
            child: PageHeader(
              title: L10n.t('自定义策略'),
              showBackButton: true,
              showUserAvatar: true,
            ),
          ),
          Material(
            color: theme.colorScheme.surface,
            child: TabBar(
              controller: _tabs,
              tabs: <Widget>[
                Tab(text: L10n.t('分组策略')),
                Tab(text: L10n.t('配置策略')),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(child: Text(_error!))
                : config == null
                ? Center(child: Text(L10n.t('暂无数据')))
                : TabBarView(
                    controller: _tabs,
                    children: <Widget>[
                      _buildGroupsTab(theme, config),
                      _buildConfigTab(theme, config),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupsTab(ThemeData theme, SubscriptionConfig config) {
    final List<String> toggleable = <String>[
      for (final String name in config.allGroupNames)
        if (config.customizableGroups.contains(name)) name,
    ];
    final Set<String> seen = toggleable.toSet();
    if (config.allowCustomGroups) {
      for (final CustomProxyGroup group in _customGroups) {
        if (group.name.isNotEmpty && seen.add(group.name)) {
          toggleable.add(group.name);
        }
      }
    }

    return ListView(
      padding: const EdgeInsets.all(14),
      children: <Widget>[
        SectionCard(
          icon: Icons.tune,
          title: L10n.t('策略组开关'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                L10n.t('开启或关闭策略组，保存后刷新配置生效'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              if (toggleable.isEmpty)
                Text(
                  config.customizableGroups.isEmpty && !config.allowCustomGroups
                      ? L10n.t('管理员未开放分组自定义功能')
                      : L10n.t('暂无可自定义的策略组'),
                  style: theme.textTheme.bodyMedium,
                )
              else
                for (final String name in toggleable)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: GroupIcon(
                      url: _groupToggleIcon(config, name),
                      selectable: true,
                      size: 20,
                    ),
                    title: Text(name),
                    trailing: Transform.scale(
                      scale: AppTheme.switchScale,
                      alignment: Alignment.centerRight,
                      child: Switch(
                        value: !_disabled.contains(name),
                        onChanged: (bool enabled) {
                          setState(() {
                            if (enabled) {
                              _disabled.remove(name);
                            } else {
                              _disabled.add(name);
                            }
                          });
                        },
                      ),
                    ),
                  ),
              if (toggleable.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: _busy
                        ? null
                        : () => unawaited(
                            _save(<String, dynamic>{
                              'disabled_groups': jsonEncode(
                                _disabled.toList()..sort(),
                              ),
                            }),
                          ),
                    child: Text(L10n.t('保存分组配置')),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (config.allowCustomGroups) ...<Widget>[
          const SizedBox(height: 10),
          SectionCard(
            icon: Icons.add_circle_outline,
            title: L10n.t('自定义策略组'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  L10n.t('仅支持手动选择（select）。下方可引用核心策略组与内置出站；图标可填自定义 URL。最多 {0} 个。', <Object>[config.maxCustomGroups]),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                if (_customGroups.isEmpty)
                  Text(L10n.t('尚未添加自定义策略组'), style: theme.textTheme.bodyMedium)
                else
                  for (int i = 0; i < _customGroups.length; i++)
                    if (_editingGroupIdx == i)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            TextField(
                              controller: _groupName,
                              focusNode: _groupNameFocus,
                              decoration: InputDecoration(
                                labelText: L10n.t('策略组名称'),
                                isDense: true,
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _groupIcon,
                              decoration: InputDecoration(
                                labelText: L10n.t('图标 URL（可选）'),
                                hintText: 'https://example.com/icon.png',
                                isDense: true,
                              ),
                            ),
                            SwitchTile(
                              contentPadding: EdgeInsets.zero,
                              title: L10n.t('包含全部节点'),
                              value: _draftIncludeNodes,
                              onChanged: (bool value) =>
                                  setState(() => _draftIncludeNodes = value),
                            ),
                            Text(
                              L10n.t('引用策略组'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            Wrap(
                              spacing: 4,
                              children: <Widget>[
                                for (final String name
                                    in config.availableProxyNames)
                                  FilterChip(
                                    label: Text(name),
                                    selected: _draftProxies.contains(name),
                                    onSelected: (bool selected) {
                                      setState(() {
                                        if (selected) {
                                          _draftProxies.add(name);
                                        } else {
                                          _draftProxies.remove(name);
                                        }
                                      });
                                    },
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: <Widget>[
                                TextButton(
                                  style: AppTheme.inlineTextLink(
                                    theme.colorScheme,
                                  ),
                                  onPressed: _busy
                                      ? null
                                      : () =>
                                          _commitCustomGroup(replaceAt: i),
                                  child: Text(L10n.t('保存')),
                                ),
                                const SizedBox(width: 10),
                                TextButton(
                                  style: AppTheme.inlineTextLink(
                                    theme.colorScheme,
                                  ),
                                  onPressed: _busy
                                      ? null
                                      : () => setState(_clearGroupForm),
                                  child: Text(L10n.t('取消')),
                                ),
                              ],
                            ),
                          ],
                        ),
                      )
                    else
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: GroupIcon(
                          url: _customGroups[i].icon,
                          selectable: true,
                          size: 20,
                        ),
                        title: Text(_customGroups[i].name),
                        subtitle: Text(
                          [
                            if (_customGroups[i].includeNodes) L10n.t('全部节点'),
                            if (_customGroups[i].proxies.isNotEmpty)
                              L10n.t('{0} 引用', <Object>[
                                _customGroups[i].proxies.length,
                              ]),
                          ].join(' · '),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            TextButton(
                              style: AppTheme.inlineTextLink(
                                theme.colorScheme,
                              ),
                              onPressed: _busy
                                  ? null
                                  : () => _beginEditGroup(i),
                              child: Text(L10n.t('编辑')),
                            ),
                            const SizedBox(width: 10),
                            TextButton(
                              style: AppTheme.inlineTextLink(
                                theme.colorScheme,
                              ),
                              onPressed: _busy
                                  ? null
                                  : () => unawaited(_removeCustomGroup(i)),
                              child: Text(L10n.t('删除')),
                            ),
                          ],
                        ),
                      ),
                if (_editingGroupIdx == null) ...<Widget>[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _groupName,
                    focusNode: _groupNameFocus,
                    decoration: InputDecoration(
                      labelText: L10n.t('策略组名称'),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _groupIcon,
                    decoration: InputDecoration(
                      labelText: L10n.t('图标 URL（可选）'),
                      hintText: 'https://example.com/icon.png',
                      isDense: true,
                    ),
                  ),
                  SwitchTile(
                    contentPadding: EdgeInsets.zero,
                    title: L10n.t('包含全部节点'),
                    value: _draftIncludeNodes,
                    onChanged: (bool value) =>
                        setState(() => _draftIncludeNodes = value),
                  ),
                  Text(
                    L10n.t('引用策略组'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Wrap(
                    spacing: 4,
                    children: <Widget>[
                      for (final String name in config.availableProxyNames)
                        FilterChip(
                          label: Text(name),
                          selected: _draftProxies.contains(name),
                          onSelected: (bool selected) {
                            setState(() {
                              if (selected) {
                                _draftProxies.add(name);
                              } else {
                                _draftProxies.remove(name);
                              }
                            });
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      onPressed: _busy ? null : _commitCustomGroup,
                      child: Text(L10n.t('添加')),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildConfigTab(ThemeData theme, SubscriptionConfig config) {
    final bool hasConfig =
        config.allowCustomHosts ||
        config.allowCustomRules ||
        config.allowCustomRuleProviders;
    if (!hasConfig) {
      return Center(child: Text(L10n.t('管理员未开放自定义配置功能')));
    }
    final bool hasHostsOrRules =
        config.allowCustomHosts || config.allowCustomRules;
    final List<String> policies = _policyNames(config);
    final String draftPolicy = policies.contains(_draftPolicy)
        ? _draftPolicy
        : (policies.isNotEmpty ? policies.first : '');

    return ListView(
      padding: const EdgeInsets.all(14),
      children: <Widget>[
        if (config.allowCustomHosts)
          SectionCard(
            icon: Icons.dns_outlined,
            title: L10n.t('自定义 Host'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  L10n.t('每行一条：domain = ip。最多 {0} 条。', <Object>[config.maxCustomHosts]),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                MultilineContentField(
                  controller: _hosts,
                  hintText: 'example.com = 1.2.3.4',
                  minLines: 4,
                  maxLines: 6,
                ),
              ],
            ),
          ),
        if (config.allowCustomHosts && config.allowCustomRules)
          const SizedBox(height: 10),
        if (config.allowCustomRules)
          SectionCard(
            icon: Icons.alt_route,
            title: L10n.t('自定义分流规则'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  L10n.t('每行一条：TYPE,value,POLICY。最多 {0} 条。', <Object>[config.maxCustomRules]),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                MultilineContentField(
                  controller: _rules,
                  hintText: 'DOMAIN-SUFFIX,example.com,DIRECT',
                  minLines: 4,
                  maxLines: 6,
                ),
              ],
            ),
          ),
        if (hasHostsOrRules) ...<Widget>[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _busy
                  ? null
                  : () {
                      final Map<String, dynamic> body = <String, dynamic>{};
                      if (config.allowCustomHosts) {
                        body['custom_hosts'] = _hosts.text;
                      }
                      if (config.allowCustomRules) {
                        body['custom_rules'] = _rules.text;
                      }
                      unawaited(_save(body));
                    },
              child: Text(L10n.t('保存配置策略')),
            ),
          ),
        ],
        if (hasHostsOrRules && config.allowCustomRuleProviders)
          const SizedBox(height: 10),
        if (config.allowCustomRuleProviders)
          SectionCard(
            icon: Icons.cloud_download_outlined,
            title: L10n.t('远程规则集'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  L10n.t('填写规则集 URL 并选择策略，仅 Clash / 官方客户端生效。需同时在上方设置自定义分流规则。最多 {0} 个。', <Object>[config.maxCustomRuleProviders]),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                if (_customRuleProviders.isEmpty)
                  Text(L10n.t('尚未添加远程规则集'), style: theme.textTheme.bodyMedium)
                else
                  for (int i = 0; i < _customRuleProviders.length; i++)
                    if (_editingProviderIdx == i)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            TextField(
                              controller: _providerUrl,
                              focusNode: _providerUrlFocus,
                              decoration: InputDecoration(
                                labelText: L10n.t('规则集 URL'),
                                isDense: true,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: <Widget>[
                                Text(L10n.t('策略'), style: theme.textTheme.bodyMedium),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: LayoutBuilder(
                                    builder:
                                        (
                                          BuildContext context,
                                          BoxConstraints constraints,
                                        ) {
                                      return OptionDropdown<String>(
                                        width: constraints.maxWidth,
                                        height: 36,
                                        value: draftPolicy.isEmpty
                                            ? null
                                            : draftPolicy,
                                        placeholder: L10n.t('选择策略'),
                                        options: <String, String>{
                                          for (final String name in policies)
                                            name: name,
                                        },
                                        onChanged: (String value) =>
                                            setState(() => _draftPolicy = value),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: <Widget>[
                                TextButton(
                                  style: AppTheme.inlineTextLink(
                                    theme.colorScheme,
                                  ),
                                  onPressed: _busy
                                      ? null
                                      : () =>
                                          _commitRuleProvider(replaceAt: i),
                                  child: Text(L10n.t('保存')),
                                ),
                                const SizedBox(width: 10),
                                TextButton(
                                  style: AppTheme.inlineTextLink(
                                    theme.colorScheme,
                                  ),
                                  onPressed: _busy
                                      ? null
                                      : () => setState(_clearProviderForm),
                                  child: Text(L10n.t('取消')),
                                ),
                              ],
                            ),
                          ],
                        ),
                      )
                    else
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(_customRuleProviders[i].url),
                        subtitle: Text(_customRuleProviders[i].policy),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            TextButton(
                              style: AppTheme.inlineTextLink(
                                theme.colorScheme,
                              ),
                              onPressed: _busy
                                  ? null
                                  : () => _beginEditProvider(i),
                              child: Text(L10n.t('编辑')),
                            ),
                            const SizedBox(width: 10),
                            TextButton(
                              style: AppTheme.inlineTextLink(
                                theme.colorScheme,
                              ),
                              onPressed: _busy
                                  ? null
                                  : () => _removeRuleProvider(i),
                              child: Text(L10n.t('删除')),
                            ),
                          ],
                        ),
                      ),
                if (_editingProviderIdx == null) ...<Widget>[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _providerUrl,
                    focusNode: _providerUrlFocus,
                    decoration: InputDecoration(
                      labelText: L10n.t('规则集 URL'),
                      hintText: 'https://example.com/rules.yaml',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      Text(L10n.t('策略'), style: theme.textTheme.bodyMedium),
                      const SizedBox(width: 12),
                      Expanded(
                        child: LayoutBuilder(
                          builder:
                              (
                                BuildContext context,
                                BoxConstraints constraints,
                              ) {
                            return OptionDropdown<String>(
                              width: constraints.maxWidth,
                              height: 36,
                              value: draftPolicy.isEmpty ? null : draftPolicy,
                              placeholder: L10n.t('选择策略'),
                              options: <String, String>{
                                for (final String name in policies) name: name,
                              },
                              onChanged: (String value) =>
                                  setState(() => _draftPolicy = value),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: <Widget>[
                    if (_editingProviderIdx == null)
                      OutlinedButton(
                        onPressed: _busy ? null : _commitRuleProvider,
                        child: Text(L10n.t('添加')),
                      ),
                    FilledButton(
                      onPressed: _busy
                          ? null
                          : () => unawaited(
                              _save(<String, dynamic>{
                                'custom_rule_providers': jsonEncode(
                                  <Map<String, dynamic>>[
                                    for (final CustomRuleProvider p
                                        in _customRuleProviders)
                                      p.toJson(),
                                  ],
                                ),
                              }),
                            ),
                      child: Text(L10n.t('保存远程规则集')),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}
