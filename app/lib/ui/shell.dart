import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../domain/kernel/kernel_update.dart';
import '../l10n/l10n.dart';
import '../domain/update/app_update.dart';
import '../data/models/announcement.dart';
import '../state/announcement_controller.dart';
import '../state/auth_controller.dart';
import '../state/connection_controller.dart';
import '../state/update_controller.dart';
import 'app_scope.dart';
import 'pages/connections_page.dart';
import 'pages/home_page.dart';
import 'pages/logs_page.dart';
import 'pages/nodes_page.dart';
import 'pages/settings_page.dart';
import 'pages/shop_page.dart';
import 'pages/tickets_page.dart';
import 'pages/unlock_page.dart';
import 'shell_navigator.dart';
import 'widgets/announcement_dialog.dart';
import 'widgets/connection_status_badge.dart';
import 'widgets/update_progress_bar.dart';

class _Destination {
  const _Destination(this.icon, this.selectedIcon, this.label, this.page);

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final Widget page;
}

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  static const List<_Destination> _destinations = <_Destination>[
    _Destination(Icons.home_outlined, Icons.home, '首页', HomePage()),
    _Destination(
      Icons.shopping_bag_outlined,
      Icons.shopping_bag,
      '商店',
      ShopPage(),
    ),
    _Destination(Icons.dns_outlined, Icons.dns, '节点', NodesPage()),
    _Destination(
      Icons.confirmation_number_outlined,
      Icons.confirmation_number,
      '工单',
      TicketsPage(),
    ),
    _Destination(
      Icons.lock_open_outlined,
      Icons.lock_open,
      '解锁',
      UnlockPage(),
    ),
    _Destination(
      Icons.swap_horiz_outlined,
      Icons.swap_horiz,
      '连接',
      ConnectionsPage(),
    ),
    _Destination(Icons.article_outlined, Icons.article, '日志', LogsPage()),
    _Destination(Icons.settings_outlined, Icons.settings, '设置', SettingsPage()),
  ];

  int _index = 0;
  UpdateController? _update;
  ConnectionController? _connection;
  AuthController? _auth;
  AnnouncementController? _announcements;
  bool _forcingUpdate = false;
  int? _lastPromptedPopupId;
  bool _handlingIpKick = false;
  Timer? _ipKickPollTimer;

  @override
  void initState() {
    super.initState();
    ShellNavigator.bindHost(_goToTab);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_update != null) {
      return;
    }
    final AppScope scope = AppScope.of(context);
    _update = scope.update..addListener(_forceUpdateIfNeeded);
    _auth = scope.auth..onIpKickNotice = _onIpKickNotice;
    _connection = scope.connection
      ..addListener(_forceUpdateIfNeeded)
      ..addListener(_syncIpKickPoll)
      ..confirmIpLimitKick = _confirmIpLimitKick;
    _announcements = scope.announcements..addListener(_maybeShowPopup);
    _forceUpdateIfNeeded();
    _maybeShowPopup();
    _syncIpKickPoll();
    if (_auth?.profile?.ipKickNotice == true) {
      _onIpKickNotice();
    }
  }

  @override
  void dispose() {
    ShellNavigator.unbindHost(_goToTab);
    _ipKickPollTimer?.cancel();
    _update?.removeListener(_forceUpdateIfNeeded);
    _connection?.removeListener(_forceUpdateIfNeeded);
    _connection?.removeListener(_syncIpKickPoll);
    _connection?.confirmIpLimitKick = null;
    _auth?.onIpKickNotice = null;
    _announcements?.removeListener(_maybeShowPopup);
    super.dispose();
  }

  void _goToTab(int index) {
    setState(() => _index = index);
  }

  void _syncIpKickPoll() {
    final ConnectionController? connection = _connection;
    final bool connected =
        connection != null && connection.state == ConnectionPhase.connected;
    if (connected) {
      _ipKickPollTimer ??= Timer.periodic(
        const Duration(seconds: 60),
        (_) {
          final AuthController? auth = _auth;
          if (auth != null) {
            unawaited(auth.refreshProfile());
          }
        },
      );
      return;
    }
    _ipKickPollTimer?.cancel();
    _ipKickPollTimer = null;
  }

  Future<bool> _confirmIpLimitKick() async {
    if (!mounted) {
      return false;
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(L10n.t('在线 IP 已达上限')),
        content: Text(L10n.t('当前已超出在线IP限制，是否将其中一个在线IP踢下线，以挪出位置？')),
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
    return ok == true;
  }

  void _onIpKickNotice() {
    if (_handlingIpKick || !mounted) {
      return;
    }
    _handlingIpKick = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_handleIpKickNotice());
    });
  }

  Future<void> _handleIpKickNotice() async {
    try {
      final ConnectionController? connection = _connection;
      if (connection != null &&
          (connection.state == ConnectionPhase.connected ||
              connection.state == ConnectionPhase.connecting)) {
        await connection.disconnect();
      }
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) => AlertDialog(
          title: Text(L10n.t('设备已下线')),
          content: Text(
            L10n.t('由于超出在线 IP 限制，有新 IP 请求连接，已将您的设备踢下线。'),
          ),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(L10n.t('知道了')),
            ),
          ],
        ),
      );
      final api = _auth?.api;
      if (api != null) {
        try {
          await api.ackIpKick();
        } on Object {
          // 清除失败不阻断；下次 profile 仍可能再提示
        }
      }
    } finally {
      _handlingIpKick = false;
    }
  }

  void _maybeShowPopup() {
    if (!mounted) {
      return;
    }
    final AnnouncementController? announcements = _announcements;
    if (announcements == null || !announcements.loaded) {
      return;
    }
    final Announcement? pending = announcements.pendingPopup;
    if (pending == null || _lastPromptedPopupId == pending.id) {
      return;
    }
    _lastPromptedPopupId = pending.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(
        showAnnouncementPopup(
          context,
          announcement: pending,
          controller: announcements,
        ),
      );
    });
  }

  void _forceUpdateIfNeeded() {
    final UpdateController update = _update!;
    if (_forcingUpdate ||
        !update.shouldPromptUpdate ||
        !update.updateNetworkReady) {
      return;
    }
    _forcingUpdate = true;

    // 通知发出时正处在构建过程中，弹窗要等这一帧画完
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted ||
          !update.shouldPromptUpdate ||
          !update.updateNetworkReady) {
        _forcingUpdate = false;
        return;
      }
      // 经本地 mixed 探测 GitHub；直连偶发通也不能当作可更新
      if (!await update.githubReachable()) {
        _forcingUpdate = false;
        return;
      }
      if (!mounted ||
          !update.shouldPromptUpdate ||
          !update.updateNetworkReady) {
        _forcingUpdate = false;
        return;
      }
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) => _ForceUpdateDialog(update: update),
      );
      _forcingUpdate = false;
      if (mounted) {
        _forceUpdateIfNeeded();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= 640;
        final Color pageColor = Theme.of(context).scaffoldBackgroundColor;
        // Android（含 WSA）：IndexedStack 常驻多页 + 弹窗关闭后 Impeller/Skia
        // 合成易透出旧层；只挂当前页并铺不透明 Material，业务状态在 AppScope。
        // 桌面仍用 IndexedStack 保滚动位置。
        final Widget page = Material(
          color: pageColor,
          child: _destinations[_index].page,
        );
        final Widget content = Platform.isAndroid
            ? page
            : ColoredBox(
                color: pageColor,
                child: IndexedStack(
                  index: _index,
                  children: <Widget>[
                    for (final _Destination destination in _destinations)
                      destination.page,
                  ],
                ),
              );

        // 底栏由 Scaffold 自己吃系统手势区；宽屏没有底栏，SafeArea 要包底。
        // 顶栏必须包：Android / 鸿蒙 edge-to-edge 下内容会画进状态栏。
        return ShellNavigator(
          goTo: _goToTab,
          child: Scaffold(
            body: SafeArea(
              bottom: wide,
              child: wide
                  ? Row(
                      children: <Widget>[
                        // 7 个目的地全文案在矮窗口里高过可用高度，NavigationRail 自身
                        // 不滚动，直接放进 Row 会出黄黑溢出条；IntrinsicHeight 是让它
                        // 内部的 Expanded 能在无界高度下定高的唯一办法
                        LayoutBuilder(
                          builder:
                              (
                                BuildContext context,
                                BoxConstraints railConstraints,
                              ) => SingleChildScrollView(
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minHeight: railConstraints.maxHeight,
                                  ),
                                  child: IntrinsicHeight(
                                    child: NavigationRail(
                                      selectedIndex: _index,
                                      onDestinationSelected: _goToTab,
                                      // 顶距交给 NavigationRail 默认 padding（约 8），与 PageHeader 对齐
                                      leading: const Padding(
                                        padding: EdgeInsets.only(bottom: 18),
                                        child: _Brand(),
                                      ),
                                      destinations: <NavigationRailDestination>[
                                        for (final _Destination destination
                                            in _destinations)
                                          NavigationRailDestination(
                                            icon: Icon(destination.icon),
                                            selectedIcon: Icon(
                                              destination.selectedIcon,
                                            ),
                                            label: Text(L10n.t(destination.label)),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(child: content),
                      ],
                    )
                  : content,
            ),
            bottomNavigationBar: wide
                ? null
                : NavigationBar(
                    selectedIndex: _index,
                    onDestinationSelected: _goToTab,
                    destinations: <NavigationDestination>[
                      for (final _Destination destination in _destinations)
                        NavigationDestination(
                          icon: Icon(destination.icon),
                          selectedIcon: Icon(destination.selectedIcon),
                          label: L10n.t(destination.label),
                        ),
                    ],
                  ),
          ),
        );
      },
    );
  }
}

class _ForceUpdateDialog extends StatefulWidget {
  const _ForceUpdateDialog({required this.update});

  final UpdateController update;

  @override
  State<_ForceUpdateDialog> createState() => _ForceUpdateDialogState();
}

class _ForceUpdateDialogState extends State<_ForceUpdateDialog> {
  @override
  void initState() {
    super.initState();
    widget.update.addListener(_onUpdate);
  }

  @override
  void dispose() {
    widget.update.removeListener(_onUpdate);
    super.dispose();
  }

  void _onUpdate() {
    if (!mounted) {
      return;
    }
    if (!widget.update.requiresUpdate) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final UpdateController update = widget.update;
    final AppUpdate? app = update.appUpdate;
    final KernelUpdate? kernel = update.kernelUpdate;
    final bool appOutdated = app != null && app.outdated && app.installer != null;
    final bool kernelOutdated = kernel != null && kernel.outdated;
    final bool busy = update.appBusy || update.kernelUpgrading;
    final bool appFailed = update.appStatus.startsWith(L10n.t('更新失败'));
    final bool kernelFailed = update.kernelStatus.startsWith(L10n.t('更新失败'));
    final Color errorColor = Theme.of(context).colorScheme.error;

    return AlertDialog(
      icon: const Icon(Icons.system_update_alt),
      title: Text(L10n.t('必须更新')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 6,
        children: <Widget>[
          Text(
            L10n.t(
              '强烈建议立即更新。旧版客户端或内核可能与面板下发的最新配置不兼容，继续使用可能导致无法连接或行为异常。',
            ),
          ),
          if (appOutdated)
            Text(L10n.t('客户端 {0} → {1}', <Object>[app.current, app.latest])),
          if (kernelOutdated)
            Text(
              L10n.t('mihomo 内核 {0} → {1}', <Object>[
                kernel.current,
                kernel.latest,
              ]),
            ),
          if (update.appBusy || appFailed)
            Text(
              update.appStatus,
              style: appFailed
                  ? Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: errorColor)
                  : null,
            ),
          if (update.appBusy)
            UpdateProgressBar(
              percent: update.appPercent,
              padding: EdgeInsets.zero,
            ),
          if (update.kernelUpgrading || kernelFailed)
            Text(
              update.kernelStatus,
              style: kernelFailed
                  ? Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: errorColor)
                  : null,
            ),
          if (update.kernelUpgrading)
            UpdateProgressBar(
              percent: update.kernelPercent,
              padding: EdgeInsets.zero,
            ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () {
            update.dismissUpdatePrompt();
            Navigator.of(context).pop();
          },
          child: Text(L10n.t('关闭')),
        ),
        if (update.kernelUpgradable != null)
          FilledButton(
            onPressed: busy ? null : () => unawaited(update.upgradeKernel()),
            child: Text(
              update.kernelUpgrading
                  ? (update.kernelPercent == null
                        ? L10n.t('正在更新内核…')
                        : L10n.t('正在更新内核 {0}%', <Object>[
                            update.kernelPercent!,
                          ]))
                  : L10n.t('更新内核'),
            ),
          ),
        if (appOutdated)
          FilledButton(
            onPressed: busy ? null : () => unawaited(update.installApp()),
            child: Text(
              update.appBusy
                  ? (update.appPercent == null
                        ? L10n.t('正在更新客户端…')
                        : L10n.t('正在更新客户端 {0}%', <Object>[
                            update.appPercent!,
                          ]))
                  : L10n.t('更新客户端'),
            ),
          ),
      ],
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ConnectionController connection = AppScope.of(context).connection;

    return ListenableBuilder(
      listenable: connection,
      builder: (BuildContext context, _) {
        final ConnectionStatusVisual visual = ConnectionStatusVisual.of(
          connection.state,
          scheme,
          failedLabel: connection.error ?? L10n.t('连接失败'),
        );

        return Tooltip(
          message: visual.label,
          child: ConnectionStatusBadge(
            icon: visual.icon,
            color: visual.color,
            spinning: connection.busy,
            size: 32,
          ),
        );
      },
    );
  }
}
