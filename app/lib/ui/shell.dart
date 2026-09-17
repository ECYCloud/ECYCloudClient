import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../domain/kernel/kernel_update.dart';
import '../l10n/l10n.dart';
import '../domain/update/app_update.dart';
import '../data/models/announcement.dart';
import '../data/models/online_device.dart';
import '../state/announcement_controller.dart';
import '../state/auth_controller.dart';
import '../state/connection_controller.dart';
import '../state/update_controller.dart';
import 'app_scope.dart';
import 'theme.dart';
import 'widgets/nav_glyph.dart';
import 'widgets/overlay_scroll_view.dart';
import 'pages/connections_page.dart';
import 'pages/home_page.dart';
import 'pages/invite_page.dart';
import 'pages/logs_page.dart';
import 'pages/nodes_page.dart';
import 'pages/settings_page.dart';
import 'pages/shop_page.dart';
import 'pages/tickets_page.dart';
import 'pages/unlock_page.dart';
import 'shell_navigator.dart';
import 'widgets/announcement_dialog.dart';
import 'widgets/app_header.dart';
import 'widgets/app_sidebar.dart';
import 'widgets/page_header.dart';
import 'widgets/clipped_scroll_body.dart';
import 'widgets/profile_format_dialog.dart';
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
  static const int _mobilePinnedCount = 5;

  static const List<_Destination> _destinations = <_Destination>[
    _Destination(Icons.home_outlined, Icons.home, '首页', HomePage()),
    _Destination(Icons.dns_outlined, Icons.dns, '节点', NodesPage()),
    _Destination(
      Icons.shopping_bag_outlined,
      Icons.shopping_bag,
      '商店',
      ShopPage(),
    ),
    _Destination(
      Icons.confirmation_number_outlined,
      Icons.confirmation_number,
      '工单',
      TicketsPage(),
    ),
    _Destination(
      Icons.group_add_outlined,
      Icons.group_add,
      '邀请',
      InvitePage(),
    ),
    _Destination(
      Icons.lock_open_outlined,
      Icons.lock_open,
      '解锁',
      UnlockPage(),
    ),
    _Destination(
      Icons.swap_horiz_outlined,
      Icons.swap_horizontal_circle,
      '连接',
      ConnectionsPage(),
    ),
    _Destination(Icons.article_outlined, Icons.article, '日志', LogsPage()),
    _Destination(Icons.settings_outlined, Icons.settings, '设置', SettingsPage()),
  ];

  int _index = 0;
  bool _moreOpen = false;
  final ShellChromeBar _chrome = ShellChromeBar();
  UpdateController? _update;
  ConnectionController? _connection;
  AuthController? _auth;
  AnnouncementController? _announcements;
  bool _forcingUpdate = false;
  String? _lastPromptedPopupKey;
  bool _handlingDeviceKick = false;
  Timer? _deviceKickPollTimer;
  Duration? _deviceKickPollInterval;
  DateTime? _lastClientAddressRefresh;
  bool _deviceKickPolling = false;

  @override
  void initState() {
    super.initState();
    _chrome.set(title: L10n.t(_destinations[0].label));
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
    _auth = scope.auth
      ..onDeviceKickNotice = _onDeviceKickNotice
      ..addListener(_syncDeviceKickPoll);
    _connection = scope.connection
      ..addListener(_forceUpdateIfNeeded)
      ..addListener(_syncDeviceKickPoll)
      ..confirmDeviceLimitKick = _confirmDeviceLimitKick
      ..onConfigAlert = _onConfigAlert;
    _announcements = scope.announcements..addListener(_maybeShowPopup);
    _forceUpdateIfNeeded();
    _maybeShowPopup();
    _syncDeviceKickPoll();
    if (_auth?.profile?.deviceKickNotice == true) {
      _onDeviceKickNotice();
    }
  }

  @override
  void dispose() {
    ShellNavigator.unbindHost(_goToTab);
    _deviceKickPollTimer?.cancel();
    _update?.removeListener(_forceUpdateIfNeeded);
    _connection?.removeListener(_forceUpdateIfNeeded);
    _connection?.removeListener(_syncDeviceKickPoll);
    _connection?.confirmDeviceLimitKick = null;
    _connection?.onConfigAlert = null;
    _auth?.onDeviceKickNotice = null;
    _auth?.removeListener(_syncDeviceKickPoll);
    _announcements?.removeListener(_maybeShowPopup);
    _chrome.dispose();
    super.dispose();
  }

  void _goToTab(int index) {
    if (index == ShellNavigator.ticketsTab) {
      AppScope.of(context).auth.markTicketsSeen();
    }
    setState(() {
      _index = index;
      _moreOpen = false;
    });
    _chrome.set(title: L10n.t(_destinations[index].label));
  }

  Widget _chromePage(int index, Widget page) {
    return ShellChrome(active: _index == index, bar: _chrome, child: page);
  }

  void _syncDeviceKickPoll() {
    final ConnectionController? connection = _connection;
    final bool connected =
        connection != null && connection.state == ConnectionPhase.connected;
    final bool connecting = connection?.state == ConnectionPhase.connecting;
    if (connected || connecting) {
      final profile = _auth?.profile;
      final Duration interval = Duration(
        seconds:
            connecting ||
                (profile != null &&
                    profile.connectorLimit > 0 &&
                    !profile.onlineDeviceSelf)
            ? 5
            : 60,
      );
      if (_deviceKickPollInterval != interval) {
        _deviceKickPollTimer?.cancel();
        _deviceKickPollInterval = interval;
        if (_lastClientAddressRefresh == null) {
          _lastClientAddressRefresh = DateTime.now();
          unawaited(_auth?.refreshPanelClientAddress());
        }
        _deviceKickPollTimer = Timer.periodic(interval, (_) async {
          final AuthController? polled = _auth;
          if (polled == null || _deviceKickPolling || _handlingDeviceKick) {
            return;
          }
          _deviceKickPolling = true;
          try {
            final DateTime now = DateTime.now();
            if (now.difference(_lastClientAddressRefresh!) >=
                const Duration(seconds: 60)) {
              _lastClientAddressRefresh = now;
              unawaited(polled.refreshPanelClientAddress());
            }
            await polled.refreshProfile();
          } finally {
            _deviceKickPolling = false;
          }
        });
      }
      return;
    }
    _deviceKickPollTimer?.cancel();
    _deviceKickPollTimer = null;
    _deviceKickPollInterval = null;
    _lastClientAddressRefresh = null;
  }

  /// 返回用户选定要下线的客户端；取消返回 null，列不出在线客户端时返回空串交给节点挑最旧的
  Future<String?> _confirmDeviceLimitKick(List<OnlineDevice> devices) async {
    if (!mounted) {
      return null;
    }
    String selected = devices.isEmpty ? '' : devices.first.deviceId;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(L10n.t('在线客户端数量已达上限')),
        content: devices.isEmpty
            ? Text(L10n.t('在线客户端数量已达上限，是否下线其中一个客户端，以挪出位置？'))
            : StatefulBuilder(
                builder: (BuildContext context, StateSetter setDialogState) =>
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text(L10n.t('在线客户端数量已达上限，请选择一个要下线的客户端：')),
                        const SizedBox(height: 8),
                        ClippedScrollBody(
                          filled: false,
                          child: RadioGroup<String>(
                            groupValue: selected,
                            onChanged: (String? value) => setDialogState(
                              () => selected = value ?? selected,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                for (final OnlineDevice device in devices)
                                  RadioListTile<String>(
                                    value: device.deviceId,
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(
                                      device.device.isEmpty
                                          ? device.deviceId
                                          : device.device,
                                    ),
                                    subtitle: Text(
                                      device.location.isEmpty
                                          ? device.ip
                                          : '${device.ip} · ${device.location}',
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
              ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L10n.t('确定')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L10n.t('取消')),
          ),
        ],
      ),
    );
    return ok == true ? selected : null;
  }

  void _onConfigAlert(String message) {
    if (!mounted || message.trim().isEmpty) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(showProfileFormatDialog(context, message));
    });
  }

  void _onDeviceKickNotice() {
    if (_handlingDeviceKick || !mounted) {
      return;
    }
    _handlingDeviceKick = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_handleDeviceKickNotice());
    });
  }

  Future<void> _handleDeviceKickNotice() async {
    try {
      if (!mounted) {
        return;
      }
      final ConnectionController? connection = _connection;
      if (_auth?.profile?.deviceKickReason == 'limit_denied') {
        final bool attempted =
            connection?.state == ConnectionPhase.connected ||
            connection?.state == ConnectionPhase.connecting;
        if (attempted) {
          await connection!.handleDeviceLimitDenied();
        }
        if (!mounted) {
          return;
        }
        if (!attempted ||
            connection?.state == ConnectionPhase.disconnected ||
            connection?.state == ConnectionPhase.disconnecting) {
          try {
            await _auth?.api?.ackDeviceKick();
          } on Object catch (_) {}
        }
        await _auth?.refreshProfile();
        return;
      }
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
            L10n.t(
              _auth?.profile?.deviceKickReason == 'remove'
                  ? '该设备已从使用记录中被移除下线。'
                  : '由于超出在线客户端数量限制，有新客户端请求连接，已将您的设备踢下线。',
            ),
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
          await api.ackDeviceKick();
        } on Object catch (_) {}
      }
    } finally {
      _handlingDeviceKick = false;
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
    final String? key = pending == null
        ? null
        : '${pending.id}|${pending.updatedAt}';
    if (pending == null || _lastPromptedPopupKey == key) {
      return;
    }
    _lastPromptedPopupKey = key;
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
        final bool wide = constraints.maxWidth >= AppTheme.wideBreakpoint;
        final Color pageColor = Theme.of(context).scaffoldBackgroundColor;
        // Android（含 WSA）：IndexedStack 常驻多页 + 弹窗关闭后 Impeller/Skia
        // 合成易透出旧层；只挂当前页并铺不透明 Material，业务状态在 AppScope。
        // 桌面仍用 IndexedStack 保滚动位置。
        final Widget page = Material(
          color: pageColor,
          child: _chromePage(_index, _destinations[_index].page),
        );
        final Widget content = Platform.isAndroid
            ? page
            : ColoredBox(
                color: pageColor,
                child: IndexedStack(
                  index: _index,
                  children: <Widget>[
                    for (int i = 0; i < _destinations.length; i++)
                      _chromePage(i, _destinations[i].page),
                  ],
                ),
              );

        final Widget headed = Stack(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: AppTheme.headerHeight),
              child: content,
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AppHeader(bar: _chrome),
            ),
          ],
        );

        // 底栏由 Scaffold 自己吃系统手势区；宽屏没有底栏，SafeArea 要包底。
        // 顶栏必须包：Android / 鸿蒙 edge-to-edge 下内容会画进状态栏。
        return ListenableBuilder(
          listenable: AppScope.of(context).auth,
          builder: (BuildContext context, Widget? _) {
            final bool ticketUnread = AppScope.of(
              context,
            ).auth.hasUnreadTicketReply;
            return ShellNavigator(
              goTo: _goToTab,
              child: Scaffold(
            body: SafeArea(
              bottom: wide,
              child: wide
                  ? Row(
                      children: <Widget>[
                        AppSidebar(
                          selectedIndex: _index,
                          onSelected: _goToTab,
                          items: <AppSidebarItem>[
                            for (int i = 0; i < _destinations.length; i++)
                              AppSidebarItem(
                                icon: _destinations[i].icon,
                                selectedIcon: _destinations[i].selectedIcon,
                                label: L10n.t(_destinations[i].label),
                                badge:
                                    i == ShellNavigator.ticketsTab &&
                                    ticketUnread,
                              ),
                          ],
                        ),
                        Expanded(child: headed),
                      ],
                    )
                  : Stack(
                      children: <Widget>[
                        headed,
                        if (_moreOpen)
                          Align(
                            alignment: Alignment.bottomRight,
                            child: Material(
                              color: Theme.of(context).colorScheme.surface,
                              clipBehavior: Clip.antiAlias,
                              borderRadius: BorderRadius.circular(
                                AppTheme.cardRadius,
                              ),
                              child: IntrinsicWidth(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    for (
                                      int i = _mobilePinnedCount;
                                      i < _destinations.length;
                                      i++
                                    )
                                      ListTile(
                                        leading: NavGlyph(
                                          _index == i
                                              ? _destinations[i].selectedIcon
                                              : _destinations[i].icon,
                                          filled: _index == i,
                                        ),
                                        title: Text(
                                          L10n.t(_destinations[i].label),
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyLarge
                                              ?.copyWith(
                                                fontSize: AppTheme.navLabelSize,
                                              ),
                                        ),
                                        selected: _index == i,
                                        selectedTileColor: Theme.of(
                                          context,
                                        ).colorScheme.surfaceContainerHighest,
                                        onTap: () => _goToTab(i),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
            bottomNavigationBar: wide
                ? null
                : NavigationBar(
                    selectedIndex: _index < _mobilePinnedCount
                        ? _index
                        : _mobilePinnedCount,
                    onDestinationSelected: (int index) {
                      if (index < _mobilePinnedCount) {
                        _goToTab(index);
                        return;
                      }
                      setState(() => _moreOpen = !_moreOpen);
                    },
                    destinations: <NavigationDestination>[
                      for (int i = 0; i < _mobilePinnedCount; i++)
                        NavigationDestination(
                          icon: _navIcon(
                            _destinations[i].icon,
                            badge:
                                i == ShellNavigator.ticketsTab && ticketUnread,
                          ),
                          selectedIcon: _navIcon(
                            _destinations[i].selectedIcon,
                            filled: true,
                            badge:
                                i == ShellNavigator.ticketsTab && ticketUnread,
                          ),
                          label: L10n.t(_destinations[i].label),
                        ),
                      NavigationDestination(
                        icon: const Icon(Icons.more_horiz),
                        selectedIcon: const Icon(Icons.more_horiz),
                        label: L10n.t('更多'),
                      ),
                    ],
                  ),
          ),
            );
          },
        );
      },
    );
  }
}

Widget _navIcon(IconData icon, {bool filled = false, bool badge = false}) {
  return Badge(
    isLabelVisible: badge,
    backgroundColor: const Color(0xFFE53935),
    smallSize: 8,
    child: NavGlyph(icon, filled: filled),
  );
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
    final bool appOutdated =
        app != null && app.outdated && app.installer != null;
    final bool kernelOutdated = kernel != null && kernel.outdated;
    final bool busy = update.appBusy || update.kernelUpgrading;
    final bool appFailed = update.appStatus.startsWith(L10n.t('更新失败'));
    final bool kernelFailed = update.kernelStatus.startsWith(L10n.t('更新失败'));
    final Color errorColor = Theme.of(context).colorScheme.error;

    return AlertDialog(
      icon: const Icon(Icons.system_update_alt),
      title: Text(L10n.t('必须更新')),
      content: OverlayScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: <Widget>[
            Text(L10n.t('强烈建议立即更新。旧版客户端或内核可能与面板下发的最新配置不兼容，继续使用可能导致无法连接或行为异常。')),
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
      ),
      actions: <Widget>[
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
                        : L10n.t('正在更新客户端 {0}%', <Object>[update.appPercent!]))
                  : L10n.t('更新客户端'),
            ),
          ),
        TextButton(
          onPressed: () {
            update.dismissUpdatePrompt();
            Navigator.of(context).pop();
          },
          child: Text(L10n.t('关闭')),
        ),
      ],
    );
  }
}
