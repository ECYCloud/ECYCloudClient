import 'package:flutter/material.dart';

import '../domain/kernel/kernel_update.dart';
import '../domain/update/app_update.dart';
import '../state/connection_controller.dart';
import '../state/update_controller.dart';
import 'app_scope.dart';
import 'pages/connections_page.dart';
import 'pages/home_page.dart';
import 'pages/logs_page.dart';
import 'pages/nodes_page.dart';
import 'pages/settings_page.dart';
import 'theme.dart';

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
  static const int _settingsIndex = 4;

  static const List<_Destination> _destinations = <_Destination>[
    _Destination(Icons.home_outlined, Icons.home, '首页', HomePage()),
    _Destination(Icons.dns_outlined, Icons.dns, '节点', NodesPage()),
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
  bool _announcing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_update != null) {
      return;
    }
    _update = AppScope.of(context).update..addListener(_announceUpdate);
    _announceUpdate();
  }

  @override
  void dispose() {
    _update?.removeListener(_announceUpdate);
    super.dispose();
  }

  void _announceUpdate() {
    final UpdateController update = _update!;
    if (_announcing || !update.shouldAnnounce) {
      return;
    }
    _announcing = true;
    update.markAnnounced();

    // 通知发出时正处在构建过程中，弹窗要等这一帧画完
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        return;
      }
      final bool? toSettings = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => _UpdateDialog(update: update),
      );
      _announcing = false;
      if (toSettings == true && mounted) {
        setState(() => _index = _settingsIndex);
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
                      leading: const Padding(
                        padding: EdgeInsets.only(top: 14, bottom: 18),
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

class _UpdateDialog extends StatelessWidget {
  const _UpdateDialog({required this.update});

  final UpdateController update;

  @override
  Widget build(BuildContext context) {
    final AppUpdate? app = update.appUpdate;
    final KernelUpdate? kernel = update.kernelUpdate;

    return AlertDialog(
      icon: const Icon(Icons.system_update_alt),
      title: const Text('发现新版本'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 6,
        children: <Widget>[
          if (app != null && app.outdated)
            Text('客户端 ${app.current} → ${app.latest}'),
          if (kernel != null && kernel.outdated)
            Text('sing-box 内核 ${kernel.current} → ${kernel.latest}'),
          const Text('可在设置 - 关于里更新，更新期间连接会短暂中断。'),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('稍后'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('前往更新'),
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
        final (Color color, IconData icon, String label) =
            switch (connection.state) {
              ConnectionPhase.connected => (
                AppTheme.success,
                Icons.shield,
                '已连接',
              ),
              ConnectionPhase.connecting => (
                AppTheme.warning,
                Icons.shield_outlined,
                '正在连接',
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
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            height: 32,
            width: 32,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              border: Border.all(color: color.withValues(alpha: 0.22)),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 19, color: color),
          ),
        );
      },
    );
  }
}
