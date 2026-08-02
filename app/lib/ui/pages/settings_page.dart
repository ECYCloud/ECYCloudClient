import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_config.dart';
import '../../core/logger.dart' show LogLevel, LogLevelName;
import '../../data/store/settings_store.dart';
import '../../domain/update/app_update.dart';
import '../../state/auth_controller.dart';
import '../../state/connection_controller.dart';
import '../../state/update_controller.dart';
import '../app_scope.dart';
import '../widgets/option_dropdown.dart';
import '../widgets/page_header.dart';
import '../widgets/refresh_button.dart';
import '../widgets/switch_tile.dart';
import 'per_app_proxy_page.dart';

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
                    subtitle: '把系统代理指向本机混合端口，退出与崩溃后自动还原',
                    value: settings.systemProxyEnabled,
                    onChanged: (bool value) => connection.updateSettings(
                      settings.copyWith(systemProxyEnabled: value),
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
                  subtitle: '重新拉取节点与分流规则；节点变更后随账号信息刷新自动更新',
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
            ListenableBuilder(
              listenable: scope.update,
              builder: (BuildContext context, _) => _Section(
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

  static String _perAppSummary(AppSettings settings) => switch (settings
      .perAppMode) {
    PerAppProxyMode.off => '全部应用走代理',
    PerAppProxyMode.include => '仅所选 ${settings.perAppPackages.length} 个应用走代理',
    PerAppProxyMode.exclude => '已排除 ${settings.perAppPackages.length} 个应用',
  };

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

/// 客户端更新：安装包由本进程下载校验，替换文件要管理员权限，交给安装器接手。
class _AppUpdateTile extends StatelessWidget {
  const _AppUpdateTile({required this.update});

  final UpdateController update;

  @override
  Widget build(BuildContext context) {
    final AppUpdate? app = update.appInstallable ? update.appUpdate : null;

    return RefreshButton.tile(
      title: '检查更新',
      subtitle: update.appStatus,
      tooltip: '检查客户端更新',
      action: update.appBusy
          ? const _Spinner()
          : app == null
          ? null
          : TextButton(
              onPressed: () => unawaited(_install(context, app.latest)),
              child: Text('更新到 ${app.latest}'),
            ),
      onRefresh: update.checkApp,
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
    if (confirmed) {
      await update.installApp();
    }
  }
}

/// sing-box 内核版本与升级。内核装在 Program Files 下，替换要管理员权限，
/// 因此下载、校验与替换全在特权服务里完成，这里只发起并回报进度。
class _KernelTile extends StatelessWidget {
  const _KernelTile({required this.update});

  final UpdateController update;

  @override
  Widget build(BuildContext context) {
    final String? upgradable = update.kernelUpgradable;

    return RefreshButton.tile(
      title: 'sing-box 内核',
      subtitle: update.kernelStatus,
      tooltip: '检查内核更新',
      action: update.kernelUpgrading
          ? const _Spinner()
          : upgradable == null
          ? null
          : TextButton(
              onPressed: () => unawaited(_upgrade(context, upgradable)),
              child: Text('升级到 $upgradable'),
            ),
      onRefresh: update.checkKernel,
    );
  }

  Future<void> _upgrade(BuildContext context, String version) async {
    final bool confirmed = await _confirm(
      context,
      title: '升级内核到 $version',
      detail:
          '将从 sing-box 官方发布页下载约 20 MB 并校验 SHA-256，'
          '替换时连接会短暂中断，随后自动重连。'
          '校验或替换失败会自动回退到当前版本。',
      action: '升级',
    );
    if (confirmed) {
      await update.upgradeKernel();
    }
  }
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
