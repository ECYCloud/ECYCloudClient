import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/api/api_exception.dart';
import '../../data/api/panel_api_client.dart';
import '../../data/models/user_profile.dart';
import '../../data/store/settings_store.dart';
import '../../domain/kernel/clash_api_client.dart';
import '../../domain/platform/platform_service.dart';
import '../../state/announcement_controller.dart';
import '../../state/auth_controller.dart';
import '../../state/connection_controller.dart';
import '../app_scope.dart';
import '../format.dart';
import '../node_labels.dart';
import '../shell_navigator.dart';
import '../theme.dart';
import '../widgets/announcement_dialog.dart';
import '../widgets/connection_status_badge.dart';
import '../widgets/delay_badge.dart';
import '../widgets/flag_icon.dart';
import '../widgets/group_delay_test_button.dart';
import '../widgets/group_icon.dart';
import '../widgets/option_dropdown.dart';
import '../widgets/page_header.dart';
import '../widgets/refresh_button.dart';
import '../widgets/section_card.dart';
import '../widgets/sparkline.dart';
import '../widgets/switch_tile.dart';
import '../widgets/tag_chip.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Timer? _ticker;
  Timer? _profileTicker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => mounted ? setState(() {}) : null,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_profileTicker == null) {
      final AppScope scope = AppScope.of(context);
      // 账号定时刷新；公告仅本次进入首页拉一次（点铃铛可再拉）
      // 首帧不打 /user/profile：restore() 刚拉过；面板配额为每路径 60s/10 次。
      _profileTicker = Timer.periodic(
        const Duration(seconds: 60),
        (_) => unawaited(scope.auth.refreshProfile()),
      );
      unawaited(scope.announcements.refresh());
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _profileTicker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppScope scope = AppScope.of(context);

    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        scope.auth,
        scope.connection,
        scope.announcements,
      ]),
      builder: (BuildContext context, _) {
        final ConnectionController connection = scope.connection;
        final UserProfile? profile = scope.auth.profile;

        return Column(
          children: <Widget>[
            const PageHeader(title: '首页'),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (connection.preflightProblems.isNotEmpty) ...<Widget>[
                      _PreflightCard(connection: connection),
                      const SizedBox(height: 10),
                    ],
                    _ConnectionCard(
                      connection: connection,
                      announcements: scope.announcements,
                    ),
                    if (connection.groups.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 10),
                      _CurrentNodeCard(connection: connection),
                    ],
                    const SizedBox(height: 10),
                    _ProxyToggles(connection: connection),
                    const SizedBox(height: 10),
                    _Pair(
                      left: _TrafficCard(connection: connection, upload: true),
                      right: _TrafficCard(
                        connection: connection,
                        upload: false,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _KernelCard(connection: connection),
                    const SizedBox(height: 10),
                    _AccountCard(profile: profile, auth: scope.auth),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 两张同构卡片并排，窄窗口自动改为上下堆叠
class _Pair extends StatelessWidget {
  const _Pair({required this.left, required this.right});

  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      if (constraints.maxWidth < 660) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[left, const SizedBox(height: 10), right],
        );
      }

      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(child: left),
          const SizedBox(width: 10),
          Expanded(child: right),
        ],
      );
    },
  );
}

/// 卡片内的等宽栅格：一行放 [columns] 个，放不下就换行
class _Grid extends StatelessWidget {
  const _Grid({
    required this.children,
    required this.columns,
    this.rowSpacing = 10,
    this.columnSpacing = 16,
  });

  final List<Widget> children;
  final int columns;
  final double rowSpacing;
  final double columnSpacing;

  @override
  Widget build(BuildContext context) {
    final List<Widget> rows = <Widget>[];

    for (int start = 0; start < children.length; start += columns) {
      final List<Widget> cells = <Widget>[];
      for (int column = 0; column < columns; column++) {
        final int index = start + column;
        if (column > 0) {
          cells.add(SizedBox(width: columnSpacing));
        }
        cells.add(
          Expanded(
            child: index < children.length
                ? children[index]
                : const SizedBox.shrink(),
          ),
        );
      }

      if (rows.isNotEmpty) {
        rows.add(SizedBox(height: rowSpacing));
      }
      rows.add(
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: cells),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.connection,
    required this.announcements,
  });

  final ConnectionController connection;
  final AnnouncementController announcements;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ConnectionPhase phase = connection.state;
    final bool connected = phase == ConnectionPhase.connected;
    final bool connecting = phase == ConnectionPhase.connecting;
    final bool disconnecting = phase == ConnectionPhase.disconnecting;
    final bool busy = connecting || disconnecting;
    final ConnectionStatusVisual visual = ConnectionStatusVisual.of(
      phase,
      theme.colorScheme,
    );

    final String detail = switch (phase) {
      ConnectionPhase.connected =>
        connection.connectedAt == null
            ? '已连接'
            : '已连接 ${Format.duration(DateTime.now().difference(connection.connectedAt!))}',
      ConnectionPhase.connecting =>
        connection.error ??
            connection.startupStage ??
            (connection.kernelCacheReady
                ? '正在启动内核，请稍候'
                : '首次连接需下载分流规则集，可能耗时较久，请勿关闭'),
      ConnectionPhase.disconnecting => '正在断开连接，请稍候',
      ConnectionPhase.failed => connection.error ?? '连接失败',
      ConnectionPhase.disconnected => '点击右侧按钮开始连接',
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool wide = constraints.maxWidth >= 560;

            final Widget status = Row(
              children: <Widget>[
                ConnectionStatusBadge(
                  icon: visual.icon,
                  color: visual.color,
                  spinning: busy,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text(visual.label, style: theme.textTheme.titleLarge),
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: phase == ConnectionPhase.failed
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );

            // 不用 IntrinsicHeight+stretch：会把连接按钮硬拉成与分段控件同高，
            // 破坏主题 filledButton 的正常内边距与胶囊比例。
            //
            // 用 Wrap 而不是 Row：移动端密度下这一排自然宽 336（断开中态 349），
            // 已经超过 390 屏能给的 330，Row 会让排在最后的公告铃铛溢出到屏幕外。
            // 连接键与铃铛捆成一个整体换行，避免铃铛自己孤零零掉到第二行。
            final Widget actions = Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 8,
              children: <Widget>[
                _ModeSelector(connection: connection),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: disconnecting
                          ? null
                          : () => connected || connecting
                                ? connection.disconnect()
                                : connection.connect(),
                      icon: Icon(
                        disconnecting || connecting
                            ? Icons.close
                            : connected
                            ? Icons.stop
                            : Icons.play_arrow,
                        size: 16,
                      ),
                      label: Text(
                        disconnecting
                            ? '断开中'
                            : connecting
                            ? '取消'
                            : connected
                            ? '断开'
                            : '连接',
                      ),
                      style: connected || disconnecting
                          ? FilledButton.styleFrom(
                              backgroundColor: AppTheme.danger,
                            )
                          : null,
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: '网站公告',
                      onPressed: () => unawaited(
                        showAnnouncementBrowser(
                          context,
                          controller: announcements,
                        ),
                      ),
                      icon: Badge(
                        isLabelVisible: announcements.pendingPopup != null,
                        child: const Icon(
                          Icons.notifications_outlined,
                          size: 20,
                        ),
                      ),
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 32,
                      ),
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ],
            );

            return wide
                ? Row(
                    children: <Widget>[
                      Expanded(child: status),
                      const SizedBox(width: 12),
                      actions,
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      status,
                      const SizedBox(height: 12),
                      Align(alignment: Alignment.centerRight, child: actions),
                    ],
                  );
          },
        ),
      ),
    );
  }
}

class _ModeSelector extends StatelessWidget {
  const _ModeSelector({required this.connection});

  final ConnectionController connection;

  static const Map<String, String> _modes = <String, String>{
    'rule': '规则',
    'global': '全局',
    'direct': '直连',
  };

  @override
  Widget build(BuildContext context) {
    // 模式是内核的运行时配置，改它走控制面，与出口有没有接管无关
    final bool enabled = connection.controlPlaneReady;

    return SegmentedButton<String>(
      segments: <ButtonSegment<String>>[
        for (final MapEntry<String, String> entry in _modes.entries)
          ButtonSegment<String>(value: entry.key, label: Text(entry.value)),
      ],
      selected: <String>{
        _modes.containsKey(connection.routeMode)
            ? connection.routeMode
            : 'rule',
      },
      onSelectionChanged: enabled
          ? (Set<String> selection) => connection.setRouteMode(selection.first)
          : null,
      showSelectedIcon: false,
    );
  }
}

class _ProxyToggles extends StatelessWidget {
  const _ProxyToggles({required this.connection});

  final ConnectionController connection;

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = connection.settings;
    final bool active = connection.state == ConnectionPhase.connected;
    final PlatformService platform = AppScope.of(context).platform;
    final bool showSystemProxy = platform.supportsSystemProxy;
    final bool tunLocked = platform.requiresTun;

    return Card(
      child: Row(
        children: <Widget>[
          if (showSystemProxy) ...<Widget>[
            Expanded(
              child: SwitchTile(
                icon: Icons.public,
                title: '系统代理',
                subtitle: active
                    ? '本机 ${settings.mixedPort} 端口'
                    : '仅连接后占用，当前未生效',
                value: settings.systemProxyEnabled,
                onChanged: (bool value) => connection.updateSettings(
                  settings.copyWith(systemProxyEnabled: value),
                ),
              ),
            ),
            const SizedBox(
              height: 34,
              child: VerticalDivider(width: 1, indent: 0, endIndent: 0),
            ),
          ],
          Expanded(
            child: SwitchTile(
              icon: Icons.lan_outlined,
              title: 'TUN 模式',
              subtitle: tunLocked
                  ? 'Android 由系统 VPN 接管，始终开启'
                  : active
                  ? '接管系统全部流量'
                  : '仅连接后占用，当前未生效',
              value: settings.tunEnabled,
              onChanged: tunLocked
                  ? null
                  : (bool value) => connection.updateSettings(
                      settings.copyWith(tunEnabled: value),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.profile, required this.auth});

  final UserProfile? profile;
  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final UserProfile? user = profile;
    final UserPlan? plan = user?.plan;

    if (user == null) {
      return SectionCard(
        icon: Icons.person_outline,
        title: '账号',
        action: RefreshButton(
          tooltip: '刷新账号信息',
          onRefresh: auth.refreshProfile,
        ),
        child: const Text('—'),
      );
    }

    final List<Widget> fields = <Widget>[
      InfoRow(
        label: '套餐',
        value:
            plan?.name ??
            (user.userClass > 0 ? 'VIP ${user.userClass}' : '免费用户'),
      ),
      if (plan != null) ...<Widget>[
        InfoRow(label: '到期', value: plan.expireAt),
        InfoRow(label: '剩余天数', value: '${plan.remainingDays} 天'),
        InfoRow(label: '自动续费', value: plan.autoRenew ? plan.renewAt : '-'),
      ],
      if (user.trafficReset.isNotEmpty)
        InfoRow(label: '流量重置', value: user.trafficReset),
      InfoRow(
        label: '限速',
        value: user.speedLimitMbps <= 0
            ? '不限速'
            : '${user.speedLimitMbps.toStringAsFixed(0)} Mbps',
      ),
      InfoRow(
        label: '在线 IP',
        value: user.connectorLimit <= 0
            ? '${user.onlineIpCount} / 无限制'
            : '${user.onlineIpCount} / ${user.connectorLimit}',
      ),
    ];

    final bool canToggleRenew = plan != null && plan.canToggleAutoRenew;

    return SectionCard(
      icon: Icons.person_outline,
      title: '账号',
      action: RefreshButton(tooltip: '刷新账号信息', onRefresh: auth.refreshProfile),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            user.displayName,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        const SizedBox(width: 6),
                        TagChip(label: 'ID ${user.id}'),
                      ],
                    ),
                    Text(
                      user.email,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '剩余 ${Format.bytes(user.remaining)}',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(value: user.usedRatio),
          const SizedBox(height: 5),
          Text(
            '已用 ${Format.bytes(user.used)} / ${Format.bytes(user.transferEnable)}',
            style: theme.textTheme.bodySmall,
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Divider(height: 1),
          ),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) =>
                _Grid(
                  columns: constraints.maxWidth < 520 ? 1 : 3,
                  rowSpacing: 2,
                  columnSpacing: 24,
                  children: fields,
                ),
          ),
          if (canToggleRenew) ...<Widget>[
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                const Spacer(),
                TextButton(
                  onPressed: () => unawaited(
                    _toggleAutoRenew(context, plan, enable: !plan.autoRenew),
                  ),
                  child: Text(plan.autoRenew ? '关闭自动续费' : '开启自动续费'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _toggleAutoRenew(
    BuildContext context,
    UserPlan plan, {
    required bool enable,
  }) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(enable ? '确认开启自动续费？' : '确认关闭自动续费？'),
        content: Text(enable ? '开启后将在套餐到期时自动续费。' : '关闭后，您可以随时重新开启自动续费。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }

    final PanelApiClient? api = auth.api;
    if (api == null) {
      return;
    }

    try {
      final String message = await api.togglePurchaseAutoRenew(
        id: plan.id,
        action: enable ? 'enable' : 'disable',
      );
      await auth.refreshProfile();
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message.isEmpty ? (enable ? '自动续费开启成功' : '自动续费关闭成功') : message,
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on ApiException catch (e) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating),
      );
    }
  }
}

class _TrafficCard extends StatelessWidget {
  const _TrafficCard({required this.connection, required this.upload});

  final ConnectionController connection;
  final bool upload;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TrafficSample traffic = connection.traffic;
    final TrafficSample total = connection.trafficTotal;

    final Color color = upload ? AppTheme.warning : theme.colorScheme.primary;
    final List<int> history = <int>[
      for (final TrafficSample sample in connection.trafficHistory)
        upload ? sample.up : sample.down,
    ];

    return SectionCard(
      icon: upload ? Icons.north : Icons.south,
      title: upload ? '上传' : '下载',
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            Format.speed(upload ? traffic.up : traffic.down),
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 1),
          Text(
            '累计 ${Format.bytes(upload ? total.up : total.down)}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Sparkline(values: history, color: color),
        ],
      ),
    );
  }
}

class _KernelCard extends StatelessWidget {
  const _KernelCard({required this.connection});

  final ConnectionController connection;

  @override
  Widget build(BuildContext context) {
    final KernelStats stats = connection.stats;
    final bool live = connection.state == ConnectionPhase.connected;

    // 内核只统计活跃连接，入站与出站是同一条连接的两端，两个数值天然相等，
    // 所以这里给的是「活跃」与客户端按快照差分留下的「已关闭」
    final List<Widget> metrics = <Widget>[
      MetricTile(
        icon: Icons.memory,
        label: '内存占用',
        value: live ? Format.bytes(stats.memory) : '—',
      ),
      MetricTile(
        icon: Icons.swap_vert,
        label: '活跃连接',
        value: live ? '${stats.connections}' : '—',
        color: live && stats.connections > 0 ? AppTheme.success : null,
      ),
      MetricTile(
        icon: Icons.history,
        label: '已关闭连接',
        value: live ? '${connection.closedConnections.length}' : '—',
      ),
    ];

    return SectionCard(
      icon: Icons.developer_board,
      title: '内核状态',
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) => _Grid(
          columns: constraints.maxWidth < 460 ? 2 : 3,
          children: metrics,
        ),
      ),
    );
  }
}

class _PreflightCard extends StatelessWidget {
  const _PreflightCard({required this.connection});

  final ConnectionController connection;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.warning_amber_outlined,
                  size: 16,
                  color: scheme.onErrorContainer,
                ),
                const SizedBox(width: 7),
                Text(
                  '运行环境自检未通过',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                RefreshButton(
                  tooltip: '重新检测',
                  color: scheme.onErrorContainer,
                  onRefresh: connection.runPreflight,
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final String problem in connection.preflightProblems)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1.5),
                child: Text(
                  '· $problem',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onErrorContainer,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CurrentNodeCard extends StatefulWidget {
  const _CurrentNodeCard({required this.connection});

  final ConnectionController connection;

  @override
  State<_CurrentNodeCard> createState() => _CurrentNodeCardState();
}

class _CurrentNodeCardState extends State<_CurrentNodeCard> {
  String? _groupName;

  ProxyGroup? get _group {
    final ConnectionController connection = widget.connection;
    final String? name = _groupName;
    if (name != null) {
      final ProxyGroup? picked = connection.groupByName(name);
      if (picked != null) {
        return picked;
      }
    }
    return connection.mainGroup;
  }

  @override
  Widget build(BuildContext context) {
    final ConnectionController connection = widget.connection;
    final ProxyGroup? group = _group;
    if (group == null) {
      return const SizedBox.shrink();
    }

    // 内核常驻，控制面在线就有真实的选中项，不必等到接管出口
    final bool live = connection.controlPlaneReady;
    final bool testing = connection.testingGroups.contains(group.name);
    final String now = group.now;
    final String leaf = now.isEmpty ? '' : connection.resolveNode(now);
    final String display = leaf.isEmpty
        ? (live ? '未选择节点' : '正在准备内核')
        : NodeLabels.displayName(leaf);
    final String? region = leaf.isEmpty ? null : NodeLabels.region(leaf);
    final String protocol = leaf.isEmpty ? '' : connection.typeOf(leaf);
    final int delay = leaf.isEmpty ? 0 : connection.delayOf(leaf);

    return SectionCard(
      icon: Icons.cell_tower_outlined,
      title: '当前节点',
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          GroupDelayTestButton(
            testing: testing,
            onPressed: () => connection.testGroup(group.name),
          ),
          TextButton(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () =>
                ShellNavigator.go(context, ShellNavigator.nodesTab),
            child: const Text('节点 ›'),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerLow.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(AppTheme.tileRadius),
              border: Border.all(
                color: Theme.of(
                  context,
                ).colorScheme.outlineVariant.withValues(alpha: 0.7),
              ),
            ),
            child: Row(
              children: <Widget>[
                if (region != null) ...<Widget>[
                  FlagIcon(code: region),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        display,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      if (protocol.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 4),
                        TagChip(label: protocol),
                      ],
                    ],
                  ),
                ),
                if (leaf.isNotEmpty)
                  DelayBadge(
                    delay: delay,
                    testing: connection.testingNodes.contains(leaf),
                    unreachable: connection.unreachableNodes.contains(leaf),
                    onTest: () => connection.testDelay(leaf),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _Pair(
            left: _LabeledDropdown(
              label: '策略组',
              builder: (double width) => OptionDropdown<String>(
                width: width,
                height: 36,
                value: group.name,
                options: <String, String>{
                  for (final ProxyGroup item in connection.groups)
                    item.name: item.name,
                },
                selectedLeading: GroupIcon(
                  url: connection.groupIconOf(group.name),
                  selectable: group.selectable,
                  size: 16,
                ),
                itemLeading: (String name) {
                  final ProxyGroup? item = connection.groupByName(name);
                  return GroupIcon(
                    url: connection.groupIconOf(name),
                    selectable: item?.selectable ?? true,
                    size: 16,
                  );
                },
                onChanged: (String name) => setState(() => _groupName = name),
              ),
            ),
            right: _LabeledDropdown(
              label: '节点',
              builder: (double width) => OptionDropdown<String>(
                width: width,
                height: 36,
                value: now.isEmpty ? null : now,
                placeholder: live ? '未选择' : '内核尚未就绪',
                enabled: live && group.selectable && group.members.isNotEmpty,
                options: <String, String>{
                  for (final String member in group.members)
                    member: NodeLabels.displayName(member),
                },
                selectedLeading: region == null
                    ? null
                    : FlagIcon(code: region, width: 14),
                selectedTrailing: DelayBadge.label(delay),
                itemLeading: (String member) {
                  final String? code = NodeLabels.region(
                    connection.resolveNode(member),
                  );
                  return code == null ? null : FlagIcon(code: code, width: 14);
                },
                itemTrailing: (String member) => DelayBadge.label(
                  connection.delayOf(connection.resolveNode(member)),
                ),
                onChanged: (String member) =>
                    unawaited(connection.selectProxy(group.name, member)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LabeledDropdown extends StatelessWidget {
  const _LabeledDropdown({required this.label, required this.builder});

  final String label;
  final Widget Function(double width) builder;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) =>
              builder(constraints.maxWidth),
        ),
      ],
    );
  }
}
