import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../core/app_config.dart';
import '../../core/app_paths.dart';
import '../../core/logger.dart' show LogLevel, LogLevelName;
import '../../data/store/settings_store.dart';
import '../../domain/update/app_update.dart';
import '../../l10n/app_language.dart';
import '../../l10n/l10n.dart';
import '../../state/connection_controller.dart';
import '../../state/update_controller.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/option_dropdown.dart';
import '../widgets/page_header.dart';
import '../widgets/refresh_button.dart';
import '../widgets/section_card.dart';
import '../widgets/switch_tile.dart';
import '../widgets/update_progress_bar.dart';
import 'network_segments_page.dart';
import 'rule_providers_page.dart';
import 'text_viewer_page.dart';
import 'privacy_policy_page.dart';
import 'tos_page.dart';
import '../widgets/app_alert_dialog.dart';
import '../widgets/app_text_field.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final AppScope scope = AppScope.of(context);
    final ConnectionController connection = scope.connection;

    return ShellListenableBuilder(
      listenable: connection,
      builder: (BuildContext context, _) {
        final ThemeData theme = Theme.of(context);
        final AppSettings settings = connection.settings;

        return ListView(
          padding: AppTheme.pageScrollPadding.copyWith(left: 0, top: 0),
          children: <Widget>[
            PageHeader(title: L10n.t('设置'), showUserAvatar: false),
            Padding(
              padding: EdgeInsets.only(left: AppTheme.pageScrollPadding.left),
              child: Column(
                children: <Widget>[
                  Section(
                    icon: Icons.vpn_lock_outlined,
                    title: L10n.t('代理'),
                    children: <Widget>[
                      _RegionTile(connection: connection),
                      if (scope.platform.supportsSystemProxy)
                        SwitchTile(
                          title: L10n.t('设置系统代理'),
                          subtitle: L10n.t(
                            '把系统代理指向本机混合端口，只对读取该设置的程序生效，其余程序需要 TUN 模式；退出与崩溃后自动还原',
                          ),
                          value: settings.systemProxyEnabled,
                          onChanged: (bool value) => connection.updateSettings(
                            settings.copyWith(systemProxyEnabled: value),
                          ),
                          settingsTooltip: L10n.t('系统代理绕过'),
                          onSettings: () =>
                              unawaited(openSystemProxyBypass(context)),
                        ),
                      SwitchTile(
                        title: L10n.t('TUN 模式'),
                        subtitle: L10n.t('接管系统全部流量，需要后台服务与虚拟网卡驱动'),
                        value: settings.tunEnabled,
                        onChanged: scope.platform.requiresTun
                            ? null
                            : (bool value) => connection.updateSettings(
                                settings.copyWith(tunEnabled: value),
                              ),
                        settingsTooltip: L10n.t('TUN 排除自定义网段'),
                        onSettings: () =>
                            unawaited(openTunExcludeAddresses(context)),
                      ),
                      SwitchTile(
                        title: L10n.t('严格路由'),
                        subtitle: L10n.t(
                          '阻断绕过 TUN 的 DNS 查询防泄露，代价是直接查询局域网 DNS 的程序（如借宿主机网络上网的虚拟机）可能无法解析域名',
                        ),
                        value: settings.tunStrictRoute,
                        onChanged: settings.tunEnabled
                            ? (bool value) => connection.updateSettings(
                                settings.copyWith(tunStrictRoute: value),
                              )
                            : null,
                      ),
                      SwitchTile(
                        title: L10n.t('允许局域网连接'),
                        subtitle: L10n.t('混合端口监听全部网卡，供同网段其它设备使用'),
                        value: settings.allowLan,
                        onChanged: (bool value) => connection.updateSettings(
                          settings.copyWith(allowLan: value),
                        ),
                      ),
                      SwitchTile(
                        title: L10n.t('启用 IPv6'),
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
                  Section(
                    icon: Icons.tune,
                    title: L10n.t('应用'),
                    children: <Widget>[
                      ListTile(
                        title: Text(L10n.t('界面配色')),
                        trailing: OptionDropdown<ThemeMode>(
                          value: settings.themeMode,
                          options: <ThemeMode, String>{
                            ThemeMode.system: L10n.t('跟随系统'),
                            ThemeMode.light: L10n.t('浅色'),
                            ThemeMode.dark: L10n.t('深色'),
                          },
                          onChanged: (ThemeMode mode) =>
                              connection.updateSettings(
                                settings.copyWith(themeMode: mode),
                              ),
                        ),
                      ),
                      ListTile(
                        title: Text(L10n.t('语言')),
                        trailing: OptionDropdown<String>(
                          value: AppLanguage.resolve(stored: settings.locale)
                              .code,
                          options: <String, String>{
                            for (final AppLanguage language
                                in AppLanguage.values)
                              language.code: language.label,
                          },
                          onChanged: (String code) {
                            L10n.current =
                                AppLanguage.tryParse(code) ?? AppLanguage.zhCN;
                            connection.updateSettings(
                              settings.copyWith(locale: code),
                            );
                          },
                        ),
                      ),
                      SwitchTile(
                        title: L10n.t('开机自启'),
                        value: settings.launchAtLogin,
                        onChanged: scope.platform.supportsLaunchAtLogin
                            ? (bool value) => connection.updateSettings(
                                settings.copyWith(launchAtLogin: value),
                              )
                            : null,
                      ),
                      SwitchTile(
                        title: L10n.t('启动后自动连接'),
                        value: settings.autoConnect,
                        onChanged: (bool value) => connection.updateSettings(
                          settings.copyWith(autoConnect: value),
                        ),
                      ),
                      if (scope.platform.supportsTray)
                        SwitchTile(
                          title: L10n.t('关闭窗口时最小化到托盘'),
                          value: settings.closeToTray,
                          onChanged: (bool value) => connection.updateSettings(
                            settings.copyWith(closeToTray: value),
                          ),
                        ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          ListTile(
                            title: Text(L10n.t('日志落盘级别')),
                            subtitle: Text(
                              L10n.t(
                                '日志页始终显示内核全部日志；此项决定写进日志文件的门槛，调低会显著增加磁盘写入，选 silent 则不写日志文件',
                              ),
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
                          Padding(
                            // 左 16 与各行标题同列；右侧的 24 是下方「打开目录」的图标
                            // 大小，与同卡片其它行的尾部图标一致，两处不一致这个图标
                            // 就会脱离右侧那一列
                            padding: EdgeInsets.fromLTRB(
                              16,
                              0,
                              AppTheme.trailingIconButtonInset(24),
                              8,
                            ),
                            child: Row(
                              children: <Widget>[
                                Text(
                                  L10n.t('储存路径'),
                                  style: theme.textTheme.bodySmall,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    AppPaths.logs.path,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: L10n.t('打开目录'),
                                  icon: const Icon(
                                    Icons.folder_open_outlined,
                                    size: 24,
                                  ),
                                  visualDensity: VisualDensity.standard,
                                  constraints: AppTheme.iconButtonBox,
                                  padding: EdgeInsets.zero,
                                  onPressed: () =>
                                      unawaited(_openLogsDirectory(context)),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Section(
                    icon: Icons.description_outlined,
                    title: L10n.t('配置'),
                    children: <Widget>[
                      _PanelConfigTile(connection: connection),
                      _GeoDataTile(connection: connection),
                      ListTile(
                        title: Text(L10n.t('查看运行配置')),
                        subtitle: Text(L10n.t('只读查看内核落盘的 config.json')),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => TextViewerPage(
                              title: L10n.t('运行配置'),
                              subtitle: 'config.json',
                              load: connection.readRuntimeConfig,
                            ),
                          ),
                        ),
                      ),
                      ListTile(
                        title: Text(L10n.t('查看分流规则')),
                        subtitle: Text(L10n.t('只读查看已下载的 rule-providers')),
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
                    builder: (BuildContext context, _) => Section(
                      icon: Icons.info_outline,
                      title: L10n.t('关于'),
                      children: <Widget>[
                        ListTile(
                          title: Text(L10n.t('当前版本')),
                          subtitle: _SiteLink(site: scope.auth.siteOrigin),
                          trailing: Text(
                            AppConfig.appVersion,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        _AppUpdateTile(update: scope.update),
                        _KernelTile(update: scope.update),
                        ListTile(
                          title: Text(L10n.t('服务条款')),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const TosPage(),
                            ),
                          ),
                        ),
                        ListTile(
                          title: Text(L10n.t('隐私政策')),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const PrivacyPolicyPage(),
                            ),
                          ),
                        ),
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
}

class _SiteLink extends StatelessWidget {
  const _SiteLink({required this.site});

  final String site;

  @override
  Widget build(BuildContext context) {
    final TextStyle style = DefaultTextStyle.of(context).style;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: InkWell(
        onTap: () => unawaited(AppScope.of(context).platform.openUrl(site)),
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(Uri.parse(site).host),
            const SizedBox(width: 4),
            Icon(Icons.open_in_new, size: style.fontSize, color: style.color),
          ],
        ),
      ),
    );
  }
}

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
          title: L10n.t('检查更新'),
          subtitle: update.appStatus,
          tooltip: L10n.t('检查客户端更新'),
          action: update.appBusy
              ? const _Spinner()
              : update.appManualOnly
              ? TextButton(
                  onPressed: () => unawaited(
                    AppScope.of(context).platform
                        .openUrl(AppUpdate.releasesUrl),
                  ),
                  child: Text('${L10n.t('打开发布页')} ›'),
                )
              : app == null
              ? null
              // 版本号已在 subtitle 与确认弹窗里，按钮再带一遍会把 ListTile
              // 的 trailing 撑到整行宽度，窄屏放大字号时直接报错
              : TextButton(
                  onPressed: () => unawaited(_install(context, app.latest)),
                  child: Text(L10n.t('更新')),
                ),
          onRefresh: () async {
            await update.checkApp();
            if (context.mounted) {
              _toastStatus(context, L10n.t('客户端'), update.appStatus);
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
      title: L10n.t('更新客户端到 {0}', <Object>[version]),
      detail: L10n.t(
        Platform.isAndroid
            ? '将从 GitHub 下载安装包并校验 SHA-256，随后打开系统安装程序；首次更新需按提示允许本应用安装未知应用。安装时客户端会退出，期间连接会断开。'
            : '将从 GitHub 下载安装包并校验 SHA-256，随后启动安装程序并弹出管理员授权。客户端会自行退出让安装程序替换文件，期间连接会断开。',
      ),
      action: L10n.t('下载并安装'),
    );
    if (!confirmed) {
      return;
    }
    await update.installApp();
    if (context.mounted) {
      _toastStatus(context, L10n.t('客户端'), update.appStatus);
    }
  }
}

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
          title: L10n.t('mihomo 内核'),
          subtitle: update.kernelStatus,
          tooltip: L10n.t('检查内核更新'),
          action: update.kernelUpgrading
              ? const _Spinner()
              : upgradable == null
              ? null
              : TextButton(
                  onPressed: () => unawaited(_upgrade(context, upgradable)),
                  child: Text(L10n.t('升级')),
                ),
          onRefresh: () async {
            await update.checkKernel();
            if (context.mounted) {
              _toastStatus(context, L10n.t('内核'), update.kernelStatus);
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
      title: L10n.t('升级内核到 {0}', <Object>[version]),
      detail: L10n.t(
        '将从 mihomo 官方发布页下载约 17 MB 并校验 SHA-256，替换时连接会短暂中断，随后自动重连。校验或替换失败会自动回退到当前版本。',
      ),
      action: L10n.t('升级'),
    );
    if (!confirmed) {
      return;
    }
    await update.upgradeKernel();
    if (context.mounted) {
      _toastStatus(context, L10n.t('内核'), update.kernelStatus);
    }
  }
}

Future<void> _openLogsDirectory(BuildContext context) async {
  final bool opened = await AppScope.of(context).platform
      .openDirectory(AppPaths.logs.path);
  if (opened || !context.mounted) {
    return;
  }
  _toastStatus(context, L10n.t('打开目录'), L10n.t('系统里没有可用的文件管理器'));
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
    builder: (BuildContext context) => AppAlertDialog(
      title: Text(title),
      content: Text(detail),
      actions: <Widget>[
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(action),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(L10n.t('取消')),
        ),
      ],
    ),
  );
  return confirmed == true;
}

class _RegionTile extends StatelessWidget {
  const _RegionTile({required this.connection});

  final ConnectionController connection;

  Future<void> _change(BuildContext context, String region) async {
    final AppSettings settings = connection.settings;
    if (region == settings.region) {
      return;
    }
    final bool overseas = region == AppSettings.regionOverseas;
    final bool confirmed = await _confirm(
      context,
      title: overseas ? L10n.t('确认切换到海外？') : L10n.t('确认切换到中国？'),
      detail: overseas
          ? L10n.t(
              '选择海外后，中国大陆的网站和 IP 也将经代理节点访问。身处中国大陆时请勿选择，否则国内网站、App 会明显变慢，部分服务可能无法使用。',
            )
          : L10n.t('选择中国后，中国大陆的网站和 IP 将直接连接，不经过代理节点。身处海外时请勿选择，否则访问中国大陆服务可能受限。'),
      action: overseas ? L10n.t('切换到海外') : L10n.t('切换到中国'),
    );
    if (confirmed) {
      await connection.updateSettings(
        connection.settings.copyWith(region: region),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool overseas =
        connection.settings.region == AppSettings.regionOverseas;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListTile(
      title: Text(L10n.t('使用地区')),
      subtitle: Text(
        overseas
            ? L10n.t('选择海外时，所有的流量都走代理（包括中国流量）。')
            : L10n.t('选择中国时，中国的流量走直连，海外的流量走代理。'),
        style: TextStyle(color: overseas ? scheme.error : null),
      ),
      trailing: OptionDropdown<String>(
        value: connection.settings.region,
        options: <String, String>{
          AppSettings.regionChina: L10n.t('中国'),
          AppSettings.regionOverseas: L10n.t('海外'),
        },
        onChanged: (String region) => unawaited(_change(context, region)),
      ),
    );
  }
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
      final String? message = await widget.connection.refreshProfileFromPanel(
        force: true,
      );
      if (!mounted || message == null) {
        return;
      }
      _toastStatus(context, L10n.t('面板配置'), message);
    } on Object catch (e) {
      if (mounted) {
        _toastStatus(
          context,
          L10n.t('面板配置'),
          L10n.t('更新失败：{0}', <Object>['$e']),
        );
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
          title: L10n.t('刷新面板配置'),
          subtitle: L10n.t('重新拉取节点与分流规则；节点变更后随账号信息刷新自动更新'),
          tooltip: L10n.t('刷新面板配置'),
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
        _toastStatus(context, 'GeoData', L10n.t('更新失败：{0}', <Object>['$e']));
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
          title: L10n.t('更新 GeoData'),
          subtitle: L10n.t('按面板 geox-url 重新下载地理位置数据库（需内核运行中）'),
          tooltip: L10n.t('更新 GeoData'),
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
      title: Text(L10n.t('混合代理端口')),
      subtitle: Text(L10n.t('HTTP 与 SOCKS 共用，修改后重连生效')),
      trailing: SizedBox(
        width: AppTheme.controlWidth,
        height: AppTheme.controlHeight,
        child: AppTextFormField(
          initialValue: '$port',
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          decoration: AppTheme.controlDecoration(
            constraints: const BoxConstraints.tightFor(
              width: AppTheme.controlWidth,
              height: AppTheme.controlHeight,
            ),
          ),
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
