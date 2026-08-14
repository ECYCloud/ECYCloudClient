import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_config.dart';
import '../../core/logger.dart' show LogLevel, LogLevelName;
import '../../data/store/settings_store.dart';
import '../../domain/config/network_bypass.dart';
import '../../domain/update/app_update.dart';
import '../../state/connection_controller.dart';
import '../../state/update_controller.dart';
import '../app_scope.dart';
import '../widgets/option_dropdown.dart';
import '../widgets/page_header.dart';
import '../widgets/refresh_button.dart';
import '../widgets/switch_tile.dart';
import '../widgets/tag_chip.dart';
import '../widgets/update_progress_bar.dart';
import 'per_app_proxy_page.dart';
import 'rule_providers_page.dart';
import 'text_viewer_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  static const Map<ThemeMode, String> _themeModes = <ThemeMode, String>{
    ThemeMode.system: '跟随系统',
    ThemeMode.light: '浅色',
    ThemeMode.dark: '深色',
  };

  @override
  Widget build(BuildContext context) {
    final AppScope scope = AppScope.of(context);
    final ConnectionController connection = scope.connection;

    return ListenableBuilder(
      listenable: connection,
      builder: (BuildContext context, _) {
        final AppSettings settings = connection.settings;

        return Column(
          children: <Widget>[
            const PageHeader(title: '设置'),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(14),
                children: <Widget>[
                  _Section(
                    icon: Icons.vpn_lock_outlined,
                    title: '代理',
                    children: <Widget>[
                      if (scope.platform.supportsSystemProxy)
                        SwitchTile(
                          title: '设置系统代理',
                          subtitle:
                              '把系统代理指向本机混合端口，只对读取该设置的程序生效，'
                              '其余程序需要 TUN 模式；退出与崩溃后自动还原',
                          value: settings.systemProxyEnabled,
                          onChanged: (bool value) => connection.updateSettings(
                            settings.copyWith(systemProxyEnabled: value),
                          ),
                        ),
                      if (scope.platform.supportsSystemProxy)
                        ListTile(
                          title: const Text('系统代理绕过'),
                          subtitle: Text(_systemProxyBypassSummary(settings)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => unawaited(
                            _editSegments(
                              context,
                              title: '系统代理绕过',
                              helperText: scope.platform.platformId == 'windows'
                                  ? '追加到默认列表，支持通配，例如 192.168.56.* 或 example.com'
                                  : '追加到默认列表，例如 192.168.56.0/24 或 *.local',
                              hintText: scope.platform.platformId == 'windows'
                                  ? '192.168.56.*'
                                  : '192.168.56.0/24',
                              items: settings.systemProxyBypass,
                              lockedItems: defaultSystemProxyBypass(
                                scope.platform.platformId,
                              ),
                              lockedLabel: '默认绕过',
                              onSave: (List<String> value) =>
                                  connection.updateSettings(
                                    connection.settings.copyWith(
                                      systemProxyBypass: value,
                                    ),
                                  ),
                            ),
                          ),
                        ),
                      SwitchTile(
                        title: 'TUN 模式',
                        subtitle: '接管系统全部流量，需要后台服务与虚拟网卡驱动',
                        value: settings.tunEnabled,
                        onChanged: scope.platform.requiresTun
                            ? null
                            : (bool value) => connection.updateSettings(
                                settings.copyWith(tunEnabled: value),
                              ),
                      ),
                      if (scope.platform.supportsPerAppProxy)
                        ListTile(
                          title: const Text('分应用代理'),
                          subtitle: Text(_perAppSummary(settings)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (BuildContext context) =>
                                  const PerAppProxyPage(),
                            ),
                          ),
                        ),
                      ListTile(
                        title: const Text('TUN 排除自定义网段'),
                        subtitle: Text(_tunExcludeSummary(settings)),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => unawaited(
                          _editSegments(
                            context,
                            title: '排除自定义网段',
                            helperText:
                                '仅支持 IPv4/IPv6 CIDR，例如 192.168.56.0/24 或 fd00::/8；'
                                '局域网与回环已默认排除',
                            hintText: '192.168.56.0/24',
                            items: settings.tunExcludeAddresses,
                            validate: (String value) =>
                                isIpCidr(value) ? null : '仅支持 IPv4/IPv6 CIDR',
                            onSave: (List<String> value) =>
                                connection.updateSettings(
                                  connection.settings.copyWith(
                                    tunExcludeAddresses: value,
                                  ),
                                ),
                          ),
                        ),
                      ),
                      SwitchTile(
                        title: '严格路由',
                        subtitle:
                            '阻断绕过 TUN 的 DNS 查询防泄露，代价是打断本机回环通信，'
                            '游戏与虚拟机可能不可用',
                        value: settings.tunStrictRoute,
                        onChanged: settings.tunEnabled
                            ? (bool value) => connection.updateSettings(
                                settings.copyWith(tunStrictRoute: value),
                              )
                            : null,
                      ),
                      SwitchTile(
                        title: '允许局域网连接',
                        subtitle: '混合端口监听全部网卡，供同网段其它设备使用',
                        value: settings.allowLan,
                        onChanged: (bool value) => connection.updateSettings(
                          settings.copyWith(allowLan: value),
                        ),
                      ),
                      SwitchTile(
                        title: '启用 IPv6',
                        value: settings.ipv6Enabled,
                        onChanged: (bool value) => connection.updateSettings(
                          settings.copyWith(ipv6Enabled: value),
                        ),
                      ),
                      _PortTile(
                        port: settings.mixedPort,
                        onChanged: (int value) => connection.updateSettings(
                          settings.copyWith(mixedPort: value),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    icon: Icons.tune,
                    title: '应用',
                    children: <Widget>[
                      ListTile(
                        title: const Text('界面配色'),
                        trailing: OptionDropdown<ThemeMode>(
                          value: settings.themeMode,
                          options: _themeModes,
                          onChanged: (ThemeMode mode) =>
                              connection.updateSettings(
                                settings.copyWith(themeMode: mode),
                              ),
                        ),
                      ),
                      SwitchTile(
                        title: '开机自启',
                        value: settings.launchAtLogin,
                        onChanged: scope.platform.supportsLaunchAtLogin
                            ? (bool value) => connection.updateSettings(
                                settings.copyWith(launchAtLogin: value),
                              )
                            : null,
                      ),
                      SwitchTile(
                        title: '启动后自动连接',
                        value: settings.autoConnect,
                        onChanged: (bool value) => connection.updateSettings(
                          settings.copyWith(autoConnect: value),
                        ),
                      ),
                      if (scope.platform.supportsTray)
                        SwitchTile(
                          title: '关闭窗口时最小化到托盘',
                          value: settings.closeToTray,
                          onChanged: (bool value) => connection.updateSettings(
                            settings.copyWith(closeToTray: value),
                          ),
                        ),
                      ListTile(
                        title: const Text('日志落盘级别'),
                        subtitle: const Text(
                          '日志页始终显示内核全部日志；此项决定写进日志文件的门槛，'
                          '调低会显著增加磁盘写入',
                        ),
                        trailing: OptionDropdown<LogLevel>(
                          value: settings.logLevel,
                          options: <LogLevel, String>{
                            for (final LogLevel level in LogLevel.values)
                              level: level.label,
                          },
                          onChanged: (LogLevel level) =>
                              connection.updateSettings(
                                settings.copyWith(logLevel: level),
                              ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    icon: Icons.description_outlined,
                    title: '配置',
                    children: <Widget>[
                      _PanelConfigTile(connection: connection),
                      _GeoDataTile(connection: connection),
                      ListTile(
                        title: const Text('查看运行配置'),
                        subtitle: const Text('只读查看内核落盘的 config.json'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => TextViewerPage(
                              title: '运行配置',
                              subtitle: 'config.json',
                              load: connection.readRuntimeConfig,
                            ),
                          ),
                        ),
                      ),
                      ListTile(
                        title: const Text('查看分流规则'),
                        subtitle: const Text('只读查看已下载的 rule-providers'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const RuleProvidersPage(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  ListenableBuilder(
                    listenable: scope.update,
                    builder: (BuildContext context, _) => _Section(
                      icon: Icons.info_outline,
                      title: '关于',
                      children: <Widget>[
                        ListTile(
                          title: const Text('当前版本'),
                          subtitle: Text(AppConfig.siteHost),
                          trailing: Text(
                            AppConfig.appVersion,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        _AppUpdateTile(update: scope.update),
                        _KernelTile(update: scope.update),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  static String _perAppSummary(AppSettings settings) =>
      switch (settings.perAppMode) {
        PerAppProxyMode.off => '全部应用走代理',
        PerAppProxyMode.include =>
          '仅所选 ${settings.perAppPackages.length} 个应用走代理',
        PerAppProxyMode.exclude => '已排除 ${settings.perAppPackages.length} 个应用',
      };

  static String _systemProxyBypassSummary(AppSettings settings) =>
      settings.systemProxyBypass.isEmpty
      ? '局域网与回环默认绕过，可追加网段或域名'
      : '已追加 ${settings.systemProxyBypass.length} 条';

  static String _tunExcludeSummary(AppSettings settings) =>
      settings.tunExcludeAddresses.isEmpty
      ? '局域网与回环已默认排除，可追加自定义网段'
      : '已排除 ${settings.tunExcludeAddresses.length} 条自定义网段';
}

class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 7),
          child: Row(
            children: <Widget>[
              Icon(icon, size: 14, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Text(
                title,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
        Card(
          child: Column(
            children: <Widget>[
              for (int i = 0; i < children.length; i++) ...<Widget>[
                if (i > 0) const Divider(indent: 12, endIndent: 12),
                children[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 客户端更新：安装包由本进程下载校验，替换文件要管理员权限，交给安装器接手。
class _AppUpdateTile extends StatelessWidget {
  const _AppUpdateTile({required this.update});

  final UpdateController update;

  @override
  Widget build(BuildContext context) {
    final AppUpdate? app = update.appInstallable ? update.appUpdate : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        RefreshButton.tile(
          title: '检查更新',
          subtitle: update.appStatus,
          tooltip: '检查客户端更新',
          action: update.appBusy
              ? const _Spinner()
              : update.appManualOnly
              ? TextButton(
                  onPressed: () => unawaited(
                    AppScope.of(
                      context,
                    ).platform.openUrl(AppUpdate.releasesUrl),
                  ),
                  child: const Text('打开发布页'),
                )
              : app == null
              ? null
              // 版本号已在 subtitle 与确认弹窗里，按钮再带一遍会把 ListTile
              // 的 trailing 撑到整行宽度，窄屏放大字号时直接报错
              : TextButton(
                  onPressed: () => unawaited(_install(context, app.latest)),
                  child: const Text('更新'),
                ),
          onRefresh: () async {
            await update.checkApp();
            if (context.mounted) {
              _toastStatus(context, '客户端', update.appStatus);
            }
          },
        ),
        if (update.appBusy) UpdateProgressBar(percent: update.appPercent),
      ],
    );
  }

  Future<void> _install(BuildContext context, String version) async {
    final bool confirmed = await _confirm(
      context,
      title: '更新客户端到 $version',
      detail:
          '将从 GitHub 下载安装包并校验 SHA-256，随后启动安装程序并弹出管理员授权。'
          '客户端会自行退出让安装程序替换文件，期间连接会断开。',
      action: '下载并安装',
    );
    if (!confirmed) {
      return;
    }
    await update.installApp();
    if (context.mounted) {
      _toastStatus(context, '客户端', update.appStatus);
    }
  }
}

/// mihomo 内核版本与升级。内核装在 Program Files 下，替换要管理员权限，
/// 因此下载、校验与替换全在特权服务里完成，这里只发起并回报进度。
class _KernelTile extends StatelessWidget {
  const _KernelTile({required this.update});

  final UpdateController update;

  @override
  Widget build(BuildContext context) {
    final String? upgradable = update.kernelUpgradable;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        RefreshButton.tile(
          title: 'mihomo 内核',
          subtitle: update.kernelStatus,
          tooltip: '检查内核更新',
          action: update.kernelUpgrading
              ? const _Spinner()
              : upgradable == null
              ? null
              : TextButton(
                  onPressed: () => unawaited(_upgrade(context, upgradable)),
                  child: const Text('升级'),
                ),
          onRefresh: () async {
            await update.checkKernel();
            if (context.mounted) {
              _toastStatus(context, '内核', update.kernelStatus);
            }
          },
        ),
        if (update.kernelUpgrading)
          UpdateProgressBar(percent: update.kernelPercent),
      ],
    );
  }

  Future<void> _upgrade(BuildContext context, String version) async {
    final bool confirmed = await _confirm(
      context,
      title: '升级内核到 $version',
      detail:
          '将从 mihomo 官方发布页下载约 17 MB 并校验 SHA-256，'
          '替换时连接会短暂中断，随后自动重连。'
          '校验或替换失败会自动回退到当前版本。',
      action: '升级',
    );
    if (!confirmed) {
      return;
    }
    await update.upgradeKernel();
    if (context.mounted) {
      _toastStatus(context, '内核', update.kernelStatus);
    }
  }
}

void _toastStatus(BuildContext context, String name, String status) {
  final String text = status.trim();
  if (text.isEmpty) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('$name · $text'),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String detail,
  required String action,
}) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(title),
      content: Text(detail),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(action),
        ),
      ],
    ),
  );
  return confirmed == true;
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 16,
    width: 16,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}

class _PanelConfigTile extends StatefulWidget {
  const _PanelConfigTile({required this.connection});

  final ConnectionController connection;

  @override
  State<_PanelConfigTile> createState() => _PanelConfigTileState();
}

class _PanelConfigTileState extends State<_PanelConfigTile> {
  bool _busy = false;

  Future<void> _refresh() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final String? message = await widget.connection.refreshProfileFromPanel();
      if (!mounted || message == null) {
        return;
      }
      _toastStatus(context, '面板配置', message);
    } on Object catch (e) {
      if (mounted) {
        _toastStatus(context, '面板配置', '更新失败：$e');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        RefreshButton.tile(
          title: '刷新面板配置',
          subtitle: '重新拉取节点与分流规则；节点变更后随账号信息刷新自动更新',
          tooltip: '刷新面板配置',
          onRefresh: _refresh,
        ),
        if (_busy) const UpdateProgressBar(percent: null),
      ],
    );
  }
}

class _GeoDataTile extends StatefulWidget {
  const _GeoDataTile({required this.connection});

  final ConnectionController connection;

  @override
  State<_GeoDataTile> createState() => _GeoDataTileState();
}

class _GeoDataTileState extends State<_GeoDataTile> {
  bool _busy = false;

  Future<void> _update() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final String message = await widget.connection.updateGeoData();
      if (mounted) {
        _toastStatus(context, 'GeoData', message);
      }
    } on Object catch (e) {
      if (mounted) {
        _toastStatus(context, 'GeoData', '更新失败：$e');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        RefreshButton.tile(
          title: '更新 GeoData',
          subtitle: '按面板 geox-url 重新下载地理位置数据库（需内核运行中）',
          tooltip: '更新 GeoData',
          onRefresh: _update,
        ),
        if (_busy) const UpdateProgressBar(percent: null),
      ],
    );
  }
}

class _PortTile extends StatelessWidget {
  const _PortTile({required this.port, required this.onChanged});

  final int port;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: const Text('混合代理端口'),
      subtitle: const Text('HTTP 与 SOCKS 共用，修改后重连生效'),
      trailing: SizedBox(
        width: 96,
        child: TextFormField(
          initialValue: '$port',
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          onFieldSubmitted: (String value) {
            final int? parsed = int.tryParse(value);
            if (parsed != null && parsed > 1024 && parsed < 65536) {
              onChanged(parsed);
            }
          },
        ),
      ),
    );
  }
}

Future<void> _editSegments(
  BuildContext context, {
  required String title,
  required String helperText,
  required String hintText,
  required List<String> items,
  required Future<void> Function(List<String> value) onSave,
  List<String> lockedItems = const <String>[],
  String? lockedLabel,
  String? Function(String value)? validate,
}) async {
  final List<String>? next = await showDialog<List<String>>(
    context: context,
    builder: (BuildContext context) => _SegmentListDialog(
      title: title,
      helperText: helperText,
      hintText: hintText,
      items: items,
      lockedItems: lockedItems,
      lockedLabel: lockedLabel,
      validate: validate,
    ),
  );
  if (next == null) {
    return;
  }
  await onSave(next);
}

class _SegmentListDialog extends StatefulWidget {
  const _SegmentListDialog({
    required this.title,
    required this.helperText,
    required this.hintText,
    required this.items,
    required this.lockedItems,
    required this.lockedLabel,
    required this.validate,
  });

  final String title;
  final String helperText;
  final String hintText;
  final List<String> items;
  final List<String> lockedItems;
  final String? lockedLabel;
  final String? Function(String value)? validate;

  @override
  State<_SegmentListDialog> createState() => _SegmentListDialogState();
}

class _SegmentListDialogState extends State<_SegmentListDialog> {
  late final List<String> _items = List<String>.of(widget.items);
  final TextEditingController _input = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _add() {
    final List<String> candidates = splitNetworkSegments(_input.text);
    if (candidates.isEmpty) {
      setState(() => _error = '请输入网段');
      return;
    }

    String? error;
    for (final String item in candidates) {
      error = widget.validate?.call(item);
      if (error != null) {
        break;
      }
      if (_items.contains(item) || widget.lockedItems.contains(item)) {
        error = '已存在';
        break;
      }
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }

    setState(() {
      _items.addAll(candidates);
      _error = null;
    });
    _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String? lockedLabel = widget.lockedLabel;
    final TextStyle? helperStyle = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (lockedLabel != null &&
                widget.lockedItems.isNotEmpty) ...<Widget>[
              Text(lockedLabel, style: helperStyle),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final String item in widget.lockedItems)
                    TagChip(label: item),
                ],
              ),
              const SizedBox(height: 14),
              Text('自定义', style: helperStyle),
              const SizedBox(height: 8),
            ],
            if (_items.isEmpty)
              Text('尚未添加', style: helperStyle)
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final String item in _items)
                    InputChip(
                      label: Text(item),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onDeleted: () => setState(() => _items.remove(item)),
                    ),
                ],
              ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _input,
                    decoration: InputDecoration(hintText: widget.hintText),
                    onSubmitted: (_) => _add(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _add, child: const Text('添加')),
              ],
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
            const SizedBox(height: 8),
            Text(widget.helperText, style: helperStyle),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(List<String>.of(_items)),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
