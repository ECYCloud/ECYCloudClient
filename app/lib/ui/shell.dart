import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/kernel/kernel_update.dart';
import '../domain/update/app_update.dart';
import '../data/models/announcement.dart';
import '../state/announcement_controller.dart';
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
import 'theme.dart';
import 'widgets/announcement_dialog.dart';

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
  AnnouncementController? _announcements;
  bool _forcingUpdate = false;
  int? _lastPromptedPopupId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_update != null) {
      return;
    }
    final AppScope scope = AppScope.of(context);
    _update = scope.update..addListener(_forceUpdateIfNeeded);
    _connection = scope.connection..addListener(_forceUpdateIfNeeded);
    _announcements = scope.announcements..addListener(_maybeShowPopup);
    _forceUpdateIfNeeded();
    _maybeShowPopup();
  }

  @override
  void dispose() {
    _update?.removeListener(_forceUpdateIfNeeded);
    _connection?.removeListener(_forceUpdateIfNeeded);
    _announcements?.removeListener(_maybeShowPopup);
    super.dispose();
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
        final Widget content = IndexedStack(
          index: _index,
          children: <Widget>[
            for (final _Destination destination in _destinations)
              destination.page,
          ],
        );

        return Scaffold(
          body: wide
              ? Row(
                  children: <Widget>[
                    NavigationRail(
                      selectedIndex: _index,
                      onDestinationSelected: (int index) =>
                          setState(() => _index = index),
                      labelType: NavigationRailLabelType.all,
                      // 顶距交给 NavigationRail 默认 padding（约 8），与 PageHeader 对齐
                      leading: const Padding(
                        padding: EdgeInsets.only(bottom: 18),
                        child: _Brand(),
                      ),
                      destinations: <NavigationRailDestination>[
                        for (final _Destination destination in _destinations)
                          NavigationRailDestination(
                            icon: Icon(destination.icon),
                            selectedIcon: Icon(destination.selectedIcon),
                            label: Text(destination.label),
                          ),
                      ],
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: content),
                  ],
                )
              : content,
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: _index,
                  onDestinationSelected: (int index) =>
                      setState(() => _index = index),
                  destinations: <NavigationDestination>[
                    for (final _Destination destination in _destinations)
                      NavigationDestination(
                        icon: Icon(destination.icon),
                        selectedIcon: Icon(destination.selectedIcon),
                        label: destination.label,
                      ),
                  ],
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
    final bool appFailed = update.appStatus.startsWith('安装失败');
    final bool kernelFailed = update.kernelStatus.startsWith('升级失败');
    final Color errorColor = Theme.of(context).colorScheme.error;

    return AlertDialog(
      icon: const Icon(Icons.system_update_alt),
      title: const Text('必须更新'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 6,
        children: <Widget>[
          const Text(
            '强烈建议立即更新。旧版客户端或内核可能与面板下发的最新配置不兼容，'
            '继续使用可能导致无法连接或行为异常。',
          ),
          if (appOutdated) Text('客户端 ${app.current} → ${app.latest}'),
          if (kernelOutdated)
            Text('sing-box 内核 ${kernel.current} → ${kernel.latest}'),
          if (update.appBusy || appFailed)
            Text(
              update.appStatus,
              style: appFailed ? TextStyle(color: errorColor) : null,
            ),
          if (update.kernelUpgrading || kernelFailed)
            Text(
              update.kernelStatus,
              style: kernelFailed ? TextStyle(color: errorColor) : null,
            ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () {
            update.dismissUpdatePrompt();
            Navigator.of(context).pop();
          },
          child: const Text('关闭'),
        ),
        if (kernelOutdated)
          FilledButton(
            onPressed: busy ? null : () => unawaited(update.upgradeKernel()),
            child: Text(update.kernelUpgrading ? '正在更新内核…' : '更新内核'),
          ),
        if (appOutdated)
          FilledButton(
            onPressed: busy ? null : () => unawaited(update.installApp()),
            child: Text(update.appBusy ? '正在更新客户端…' : '更新客户端'),
          ),
      ],
    );
  }
}

/// 侧栏连接状态：与首页 `_StatusBadge` 同款圆形底，尺寸适配 NavigationRail。
class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ConnectionController connection = AppScope.of(context).connection;

    return ListenableBuilder(
      listenable: connection,
      builder: (BuildContext context, _) {
        final (Color color, IconData icon, String label) =
            switch (connection.state) {
              ConnectionPhase.connected => (
                AppTheme.success,
                Icons.shield,
                '已连接',
              ),
              ConnectionPhase.connecting => (
                AppTheme.warning,
                Icons.sync,
                '正在连接',
              ),
              ConnectionPhase.disconnecting => (
                AppTheme.warning,
                Icons.sync,
                '正在断开连接',
              ),
              ConnectionPhase.failed => (
                AppTheme.danger,
                Icons.shield_outlined,
                connection.error ?? '连接失败',
              ),
              ConnectionPhase.disconnected => (
                scheme.outline,
                Icons.shield_outlined,
                '未连接',
              ),
            };

        return Tooltip(
          message: label,
          child: _RailStatusBadge(
            icon: icon,
            color: color,
            spinning: connection.busy,
          ),
        );
      },
    );
  }
}

class _RailStatusBadge extends StatefulWidget {
  const _RailStatusBadge({
    required this.icon,
    required this.color,
    required this.spinning,
  });

  final IconData icon;
  final Color color;
  final bool spinning;

  @override
  State<_RailStatusBadge> createState() => _RailStatusBadgeState();
}

class _RailStatusBadgeState extends State<_RailStatusBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(_RailStatusBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _syncAnimation() {
    if (widget.spinning) {
      if (!_controller.isAnimating) {
        _controller.repeat();
      }
    } else if (_controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget icon = Icon(widget.icon, size: 19, color: widget.color);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      height: 32,
      width: 32,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.color.withValues(alpha: 0.12),
        border: Border.all(color: widget.color.withValues(alpha: 0.22)),
      ),
      child: Center(
        child: widget.spinning
            ? RotationTransition(turns: _controller, child: icon)
            : icon,
      ),
    );
  }
}
