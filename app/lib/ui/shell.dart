import 'package:flutter/material.dart';

import '../state/connection_controller.dart';
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
