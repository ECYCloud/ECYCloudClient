import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_config.dart';
import '../../core/logger.dart' show LogLevel, LogLevelName;
import '../../data/store/settings_store.dart';
import '../../domain/kernel/kernel_update.dart';
import '../../state/auth_controller.dart';
import '../../state/connection_controller.dart';
import '../app_scope.dart';
import '../widgets/option_dropdown.dart';
import '../widgets/refresh_button.dart';
import '../widgets/switch_tile.dart';

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

        return ListView(
          padding: const EdgeInsets.all(14),
          children: <Widget>[
            _Section(
              icon: Icons.vpn_lock_outlined,
              title: '代理',
              children: <Widget>[
                SwitchTile(
                  title: '设置系统代理',
                  subtitle: '把系统代理指向本机混合端口，退出与崩溃后自动还原',
                  value: settings.systemProxyEnabled,
                  onChanged: (bool value) => connection.updateSettings(
                    settings.copyWith(systemProxyEnabled: value),
                  ),
                ),
                SwitchTile(
                  title: 'TUN 模式',
                  subtitle: '接管系统全部流量，需要后台服务与 wintun 驱动',
                  value: settings.tunEnabled,
                  onChanged: (bool value) => connection.updateSettings(
                    settings.copyWith(tunEnabled: value),
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
                    onChanged: (ThemeMode mode) => connection.updateSettings(
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
                SwitchTile(
                  title: '关闭窗口时最小化到托盘',
                  value: settings.closeToTray,
                  onChanged: scope.platform.supportsTray
                      ? (bool value) => connection.updateSettings(
                          settings.copyWith(closeToTray: value),
                        )
                      : null,
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
                    onChanged: (LogLevel level) => connection.updateSettings(
                      settings.copyWith(logLevel: level),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Section(
              icon: Icons.person_outline,
              title: '账号',
              children: <Widget>[
                RefreshButton.tile(
                  title: '刷新面板配置',
                  subtitle: '重新拉取节点与分流规则，内容无变化时不会重连',
                  tooltip: '刷新面板配置',
                  onRefresh: connection.refreshProfileFromPanel,
                ),
                ListTile(
                  title: const Text('退出登录'),
                  trailing: const Icon(Icons.logout),
                  onTap: () => _logout(context, scope.auth, connection),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Section(
              icon: Icons.info_outline,
              title: '关于',
              children: <Widget>[
                ListTile(
                  title: const Text('当前版本'),
                  subtitle: Text('面板 ${AppConfig.panelHost}'),
                  trailing: Text(
                    AppConfig.appVersion,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                ListTile(
                  title: const Text('检查更新'),
                  subtitle: const Text('从 GitHub Releases 获取新版本'),
                  trailing: const Icon(Icons.system_update_alt),
                  onTap: () => _notImplemented(context),
                ),
                _KernelTile(connection: connection),
              ],
            ),
          ],
        );
      },
    );
  }

  // 检查更新按需求预留入口，尚未接 GitHub Releases
  static void _notImplemented(BuildContext context) =>
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('检查更新功能尚未开放'),
          duration: Duration(seconds: 2),
        ),
      );

  Future<void> _logout(
    BuildContext context,
    AuthController auth,
    ConnectionController connection,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出后将断开连接并清除本机保存的登录凭据。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    await connection.disconnect();
    await auth.logout();
  }
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

/// sing-box 内核版本、更新检查与升级。内核装在 Program Files 下，替换要管理员
/// 权限，因此下载、校验与替换全在特权服务里完成，这里只发起并回报进度。
class _KernelTile extends StatefulWidget {
  const _KernelTile({required this.connection});

  final ConnectionController connection;

  @override
  State<_KernelTile> createState() => _KernelTileState();
}

class _KernelTileState extends State<_KernelTile> {
  String _status = '正在读取版本…';
  String? _upgradable;
  bool _upgrading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final String version = await widget.connection.kernelVersion();
    if (mounted) {
      setState(() => _status = version.isEmpty ? '后台服务未运行，取不到版本' : version);
    }
  }

  Future<void> _check() async {
    try {
      final KernelUpdate update = await widget.connection.checkKernelUpdate();
      if (!mounted) {
        return;
      }
      final String text;
      if (update.current.isEmpty) {
        text = '最新正式版 ${update.latest}，本机版本取不到';
      } else if (update.outdated) {
        text = '${update.current} · 官方已发布 ${update.latest}';
      } else {
        text = '${update.current} · 已是最新正式版';
      }
      setState(() {
        _upgradable = update.outdated ? update.latest : null;
        _status = text;
      });
    } on Object catch (e) {
      if (mounted) {
        setState(() => _status = '检查失败：$e');
      }
    }
  }

  Future<void> _upgrade(String version) async {
    if (!await _confirm(version)) {
      return;
    }

    setState(() {
      _upgrading = true;
      _status = '正在下载并校验 $version，请勿关闭客户端';
    });

    try {
      final String installed = await widget.connection.upgradeKernel(version);
      if (mounted) {
        setState(() {
          _upgradable = null;
          _status = '已更新到 $installed';
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() => _status = '升级失败：$e');
      }
    } finally {
      if (mounted) {
        setState(() => _upgrading = false);
      }
    }
  }

  Future<bool> _confirm(String version) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('升级内核到 $version'),
        content: const Text(
          '将从 sing-box 官方发布页下载约 20 MB 并校验 SHA-256，'
          '替换时连接会短暂中断，随后自动重连。'
          '校验或替换失败会自动回退到当前版本。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('升级'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  @override
  Widget build(BuildContext context) {
    final String? upgradable = _upgradable;

    return RefreshButton.tile(
      title: 'sing-box 内核',
      subtitle: _status,
      tooltip: '检查内核更新',
      action: _upgrading
          ? const SizedBox(
              height: 16,
              width: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : upgradable == null
          ? null
          : TextButton(
              onPressed: () => unawaited(_upgrade(upgradable)),
              child: Text('升级到 $upgradable'),
            ),
      onRefresh: _check,
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
