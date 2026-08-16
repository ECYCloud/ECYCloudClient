import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/api/api_exception.dart';
import '../../data/models/user_profile.dart';
import '../../data/store/settings_store.dart';
import '../../domain/kernel/clash_api_client.dart';
import '../../domain/platform/platform_service.dart';
import '../../state/announcement_controller.dart';
import '../../state/auth_controller.dart';
import '../../l10n/app_language.dart';
import '../../l10n/l10n.dart';
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
import 'traffic_log_page.dart';

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
      // 账号与公告均 60s 轮询（与面板限流窗口一致）；点铃铛也可再拉公告。
      // 首帧不打 /user/profile：restore() 刚拉过；面板配额为每路径 60s/10 次。
      _profileTicker = Timer.periodic(
        const Duration(seconds: 60),
        (_) {
          unawaited(scope.auth.refreshProfile());
          unawaited(scope.announcements.refresh());
        },
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
            PageHeader(
              title: L10n.t('首页'),
              showUserAvatar: true,
            ),
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
                    _TrafficUsageCard(profile: profile, auth: scope.auth),
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
  });

  final List<Widget> children;
  final int columns;
  final double rowSpacing = 10;
  final double columnSpacing = 16;

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
            ? L10n.t('已连接')
            : L10n.t('已连接 {0}', <Object>[
                Format.duration(
                  DateTime.now().difference(connection.connectedAt!),
                ),
              ]),
      ConnectionPhase.connecting =>
        connection.error ??
            connection.startupStage ??
            (connection.kernelCacheReady
                ? L10n.t('正在启动内核，请稍候')
                : L10n.t('首次连接需下载分流规则集，可能耗时较久，请勿关闭')),
      ConnectionPhase.disconnecting => L10n.t('正在断开连接，请稍候'),
      ConnectionPhase.failed => connection.error ?? L10n.t('连接失败'),
      ConnectionPhase.disconnected => L10n.t('点击右侧按钮开始连接'),
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
                          : () {
                              if (connected || connecting) {
                                unawaited(connection.disconnect());
                                return;
                              }
                              unawaited(connection.connect());
                            },
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
                            ? L10n.t('断开中')
                            : connecting
                            ? L10n.t('取消')
                            : connected
                            ? L10n.t('断开')
                            : L10n.current == AppLanguage.en
                            ? 'Connect'
                            : L10n.t('连接'),
                      ),
                      style: connected || disconnecting
                          ? FilledButton.styleFrom(
                              backgroundColor: AppTheme.danger,
                            )
                          : null,
                    ),
                    const SizedBox(width: 4),
                    Badge(
                      isLabelVisible: announcements.hasUnread,
                      backgroundColor: const Color(0xFFE53935),
                      smallSize: 8,
                      child: IconButton(
                        tooltip: L10n.t('网站公告'),
                        onPressed: () => unawaited(
                          showAnnouncementBrowser(
                            context,
                            controller: announcements,
                          ),
                        ),
                        icon: const Icon(
                          Icons.notifications_outlined,
                          size: 20,
                        ),
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 32,
                        ),
                        padding: EdgeInsets.zero,
                      ),
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
          ButtonSegment<String>(
            value: entry.key,
            label: Text(L10n.t(entry.value)),
          ),
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
                title: L10n.t('系统代理'),
                subtitle: active
                    ? L10n.t('本机 {0} 端口', <Object>[settings.mixedPort])
                    : L10n.t('仅连接后占用，当前未生效'),
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
              title: L10n.t('TUN 模式'),
              subtitle: tunLocked
                  ? L10n.t('Android 由系统 VPN 接管，始终开启')
                  : active
                  ? L10n.t('接管系统全部流量')
                  : L10n.t('仅连接后占用，当前未生效'),
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

class _TrafficUsageCard extends StatefulWidget {
  const _TrafficUsageCard({required this.profile, required this.auth});

  final UserProfile? profile;
  final AuthController auth;

  @override
  State<_TrafficUsageCard> createState() => _TrafficUsageCardState();
}

class _TrafficUsageCardState extends State<_TrafficUsageCard> {
  bool _checkingIn = false;

  Future<void> _checkin() async {
    if (_checkingIn) {
      return;
    }
    setState(() => _checkingIn = true);
    try {
      final String message = await widget.auth.checkin();
      if (!mounted) {
        return;
      }
      await _showCheckinResult(message);
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      await _showCheckinResult(e.message);
    } finally {
      if (mounted) {
        setState(() => _checkingIn = false);
      }
    }
  }

  Future<void> _showCheckinResult(String message) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(L10n.t('提示')),
        content: Text(message),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(L10n.t('我知道了')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final UserProfile? user = widget.profile;
    final AuthController auth = widget.auth;

    if (user == null) {
      return SectionCard(
        icon: Icons.pie_chart_outline,
        title: L10n.t('流量使用情况'),
        action: RefreshButton(
          tooltip: L10n.t('刷新流量'),
          onRefresh: auth.refreshProfile,
        ),
        child: const Text('—'),
      );
    }

    final int remainBytes = user.transferEnable - user.used;
    final String remainText = Format.bytes(remainBytes).replaceAll(' ', '');

    return SectionCard(
      icon: Icons.pie_chart_outline,
      title: L10n.t('流量使用情况'),
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          RefreshButton(
            tooltip: L10n.t('刷新流量'),
            onRefresh: auth.refreshProfile,
          ),
          TextButton(
            style: AppTheme.inlineTextLink(theme.colorScheme),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => const TrafficLogPage(),
              ),
            ),
            child: Text(L10n.t('流量明细 ›')),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _TrafficBarRow(
            label: L10n.t('今日已使用'),
            value: Format.bytes(user.todayUsed).replaceAll(' ', ''),
            ratio: user.ratioOf(user.todayUsed),
            barColor: AppTheme.danger,
            tagColor: AppTheme.danger,
          ),
          const SizedBox(height: 10),
          _TrafficBarRow(
            label: L10n.t('之前已使用'),
            value: Format.bytes(user.lastUsed).replaceAll(' ', ''),
            ratio: user.ratioOf(user.lastUsed),
            barColor: AppTheme.warning,
            tagColor: AppTheme.warning,
          ),
          const SizedBox(height: 10),
          _TrafficBarRow(
            label: L10n.t('剩余流量'),
            value: remainText,
            ratio: user.ratioOf(remainBytes > 0 ? remainBytes : 0),
            barColor: remainBytes < 0 ? AppTheme.danger : AppTheme.success,
            tagColor: AppTheme.success,
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1),
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(L10n.t('账户总流量'), style: theme.textTheme.bodyMedium),
              ),
              TagChip(
                label: Format.bytes(user.transferEnable).replaceAll(' ', ''),
                color: theme.colorScheme.primary,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text(
                L10n.t('流量不够用？前往 '),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              TextButton(
                style: AppTheme.inlineTextLink(theme.colorScheme),
                onPressed: () => ShellNavigator.openShopTraffic(context),
                child: Text(L10n.t('商店 ›')),
              ),
              Text(
                L10n.t(' 选购流量包'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _TrafficMetaRow(
            icon: Icons.today_outlined,
            label: L10n.t('下次重置已使用流量日期'),
            value: user.trafficReset.isEmpty ? '—' : user.trafficReset,
          ),
          _TrafficMetaRow(
            icon: Icons.schedule_outlined,
            label: L10n.t('上次使用时间'),
            value: L10n.t(user.lastSsTime),
          ),
          if (user.enableCheckin)
            _TrafficMetaRow(
              icon: Icons.calendar_month_outlined,
              label: L10n.t('上次签到时间'),
              value: L10n.t(user.lastCheckInTime),
            ),
          if (user.enableCheckin) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              L10n.t('签到可随机获得 {0}~{1} MB 流量', <Object>[user.checkinMin, user.checkinMax]),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: !user.ableToCheckin || _checkingIn
                  ? null
                  : _checkin,
              icon: _checkingIn
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_circle_outline, size: 18),
              label: Text(
                user.ableToCheckin ? L10n.t('点我签到') : L10n.t('今日已签到'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TrafficBarRow extends StatelessWidget {
  const _TrafficBarRow({
    required this.label,
    required this.value,
    required this.ratio,
    required this.barColor,
    required this.tagColor,
  });

  final String label;
  final String value;
  final double ratio;
  final Color barColor;
  final Color tagColor;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
            TagChip(label: value, color: tagColor),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: ratio.clamp(0.0, 1.0),
            minHeight: 6,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            color: barColor,
          ),
        ),
      ],
    );
  }
}

class _TrafficMetaRow extends StatelessWidget {
  const _TrafficMetaRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(value, style: theme.textTheme.bodySmall),
        ],
      ),
    );
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
      title: upload ? L10n.t('上传') : L10n.t('下载'),
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
            L10n.t('累计 {0}', <Object>[
              Format.bytes(upload ? total.up : total.down),
            ]),
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
        label: L10n.t('内存占用'),
        value: live ? Format.bytes(stats.memory) : '—',
      ),
      MetricTile(
        icon: Icons.swap_vert,
        label: L10n.t('活跃连接'),
        value: live ? '${stats.connections}' : '—',
        color: live && stats.connections > 0 ? AppTheme.success : null,
      ),
      MetricTile(
        icon: Icons.history,
        label: L10n.t('已关闭连接'),
        value: live ? '${connection.closedConnections.length}' : '—',
      ),
    ];

    return SectionCard(
      icon: Icons.developer_board,
      title: L10n.t('内核状态'),
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
                  L10n.t('运行环境自检未通过'),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                RefreshButton(
                  tooltip: L10n.t('重新检测'),
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
        ? (live ? L10n.t('未选择节点') : L10n.t('正在准备内核'))
        : NodeLabels.displayName(leaf);
    final String? region = leaf.isEmpty ? null : NodeLabels.region(leaf);
    final String protocol = leaf.isEmpty ? '' : connection.typeOf(leaf);
    final int delay = leaf.isEmpty ? 0 : connection.delayOf(leaf);

    return SectionCard(
      icon: Icons.cell_tower_outlined,
      title: L10n.t('当前节点'),
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          GroupDelayTestButton(
            testing: testing,
            onPressed: () => connection.testGroup(group.name),
          ),
          TextButton(
            style: AppTheme.inlineTextLink(Theme.of(context).colorScheme),
            onPressed: () =>
                ShellNavigator.go(context, ShellNavigator.nodesTab),
            child: Text(L10n.t('节点 ›')),
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
              label: L10n.t('策略组'),
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
              label: L10n.t('节点'),
              builder: (double width) => OptionDropdown<String>(
                width: width,
                height: 36,
                value: now.isEmpty ? null : now,
                placeholder: live ? L10n.t('未选择') : L10n.t('内核尚未就绪'),
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
