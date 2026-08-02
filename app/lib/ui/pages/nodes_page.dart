import 'package:flutter/material.dart';

import '../../domain/kernel/clash_api_client.dart';
import '../../state/connection_controller.dart';
import '../app_scope.dart';
import '../node_labels.dart';
import '../theme.dart';
import '../widgets/flag_icon.dart';
import '../widgets/icon_image.dart';
import '../widgets/page_header.dart';
import '../widgets/tag_chip.dart';

class NodesPage extends StatelessWidget {
  const NodesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ConnectionController connection = AppScope.of(context).connection;

    return ListenableBuilder(
      listenable: connection,
      builder: (BuildContext context, _) {
        final List<ProxyGroup> groups = connection.groups;
        final bool live = connection.state == ConnectionPhase.connected;

        return Column(
          children: <Widget>[
            const PageHeader(title: '节点'),
            Expanded(
              child: groups.isEmpty
                  ? const _Placeholder(
                      icon: Icons.inbox_outlined,
                      message: '面板未下发节点分组',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(14),
                      itemCount: groups.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (BuildContext context, int index) =>
                          _GroupCard(
                            group: groups[index],
                            live: live,
                            connection: connection,
                          ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _GroupCard extends StatefulWidget {
  const _GroupCard({
    required this.group,
    required this.live,
    required this.connection,
  });

  final ProxyGroup group;
  final bool live;
  final ConnectionController connection;

  @override
  State<_GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<_GroupCard> {
  // 单卡最小宽度，据此按可用宽度算列数：窗口变宽先加列，不是把卡拉长
  static const double _minTileWidth = 210;
  static const double _tileGap = 8;

  bool _expanded = false;

  // 选中项本身是分组时（如「主节点」），补上它最终落到哪个节点
  static String _nowLabel(ConnectionController connection, ProxyGroup group) {
    if (group.now.isEmpty) {
      return '';
    }
    final String leaf = connection.resolveNode(group.now);
    return leaf == group.now
        ? ' · 当前 ${NodeLabels.displayName(group.now)}'
        : ' · 当前 ${NodeLabels.displayName(group.now)} → '
              '${NodeLabels.displayName(leaf)}';
  }

  Widget _buildTile(
    ConnectionController connection,
    ProxyGroup group,
    String member, {
    required bool live,
    required bool canSelect,
  }) {
    // 成员是分组时，延迟、协议与探测状态都记在它解析出的叶子节点上
    final String leaf = connection.resolveNode(member);

    return _NodeTile(
      name: member,
      via: leaf == member ? null : leaf,
      protocol: connection.typeOf(leaf),
      selected: member == group.now,
      // 必须走 delayOf：逐个探测的结果先落在控制器的延迟表里，
      // 取 ProxyNode.delay 要等下一轮 /proxies 才更新，看着像没反应
      delay: connection.delayOf(leaf),
      testing: connection.testingNodes.contains(leaf),
      unreachable: connection.unreachableNodes.contains(leaf),
      onSelect: canSelect
          ? () => connection.selectProxy(group.name, member)
          : null,
      live: live,
      onTest: () => connection.testDelay(member),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final ProxyGroup group = widget.group;
    final ConnectionController connection = widget.connection;
    final bool live = widget.live;
    final bool canSelect = live && group.selectable;
    final bool testing = connection.testingGroups.contains(group.name);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        // 默认展开态会画上下分割线，与卡片自身的描边叠在一起很脏
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        minTileHeight: 54,
        onExpansionChanged: (bool value) => setState(() => _expanded = value),
        leading: _GroupIcon(
          url: connection.groupIconOf(group.name),
          selectable: group.selectable,
        ),
        title: Row(
          children: <Widget>[
            Flexible(
              child: Text(
                group.name,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
            ),
            const SizedBox(width: 6),
            TagChip(label: group.selectable ? '手动' : '自动'),
          ],
        ),
        subtitle: Text(
          '${group.members.length} 个节点${_nowLabel(connection, group)}',
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        // 延迟测试按钮必须和展开箭头同在 trailing：放进 title 时两者分别按标题行与
        // 整块 tile 垂直居中，视觉上不在同一条线上
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 未连接时不置灰：禁用的 IconButton 会强制把指针改回箭头，
            // 看着像功能坏了。点它先连接再测，见 ConnectionController._ensureLive
            IconButton(
              tooltip: live ? '测试本组全部节点延迟' : '连接并测试本组全部节点延迟',
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              padding: EdgeInsets.zero,
              icon: testing
                  ? const SizedBox(
                      height: 14,
                      width: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.bolt_outlined),
              onPressed: testing
                  ? null
                  : () => connection.testGroup(group.name),
            ),
            const SizedBox(width: 2),
            AnimatedRotation(
              turns: _expanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 180),
              child: Icon(
                Icons.expand_more,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        children: <Widget>[
          // 展开区紧贴标题行时看着像两块叠在一起，用一条分割线加间距断开。
          // ExpansionTile 自带的 shape 描边画在卡片边缘、会和卡片自身描边重合，
          // 所以分割线画在内容区里
          const Divider(height: 1),
          const SizedBox(height: 10),
          if (!group.selectable)
            _AutoGroupHint(connection: connection, group: group),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final int columns =
                  ((constraints.maxWidth + _tileGap) /
                          (_minTileWidth + _tileGap))
                      .floor()
                      .clamp(1, 6);
              final double tileWidth =
                  (constraints.maxWidth - _tileGap * (columns - 1)) / columns;

              return Wrap(
                spacing: _tileGap,
                runSpacing: _tileGap,
                children: <Widget>[
                  for (final String member in group.members)
                    SizedBox(
                      width: tileWidth,
                      child: _buildTile(
                        connection,
                        group,
                        member,
                        live: live,
                        canSelect: canSelect,
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

// urltest 分组的选中项由内核持有，客户端只能把最优成员摆出来
class _AutoGroupHint extends StatelessWidget {
  const _AutoGroupHint({required this.connection, required this.group});

  final ConnectionController connection;
  final ProxyGroup group;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? fastest = connection.fastestMember(group);
    final String detail = fastest == null || fastest == group.now
        ? '本组由内核按延迟自动选择，点击节点不改变选中项；测延迟会让内核立即重选'
        : '本组由内核按延迟自动选择，当前最优为 ${NodeLabels.displayName(fastest)}；'
              '点上方测延迟可让内核立即切过去';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: <Widget>[
          Icon(Icons.auto_awesome_outlined, size: 13, color: scheme.outline),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              detail,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _NodeTile extends StatelessWidget {
  const _NodeTile({
    required this.name,
    required this.via,
    required this.protocol,
    required this.selected,
    required this.delay,
    required this.testing,
    required this.unreachable,
    required this.onSelect,
    required this.live,
    required this.onTest,
  });

  final String name;

  // 成员本身是分组时，它当前落到的叶子节点
  final String? via;
  final String protocol;
  final bool selected;
  final int delay;
  final bool testing;
  final bool unreachable;
  final VoidCallback? onSelect;
  final bool live;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? region = NodeLabels.region(via ?? name);
    final String label = NodeLabels.displayName(name);
    final Color titleColor = selected
        ? scheme.onPrimaryContainer
        : scheme.onSurface;

    return Material(
      color: selected
          ? scheme.primaryContainer.withValues(alpha: 0.55)
          : scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.tileRadius),
        side: BorderSide(
          color: selected
              ? scheme.primary.withValues(alpha: 0.7)
              : scheme.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onSelect,
        mouseCursor: onSelect == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 5, 6),
          child: Row(
            children: <Widget>[
              if (region != null) ...<Widget>[
                FlagIcon(code: region),
                const SizedBox(width: 7),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        if (selected)
                          Padding(
                            padding: const EdgeInsets.only(right: 3),
                            child: Icon(
                              Icons.check_circle,
                              size: 12,
                              color: scheme.primary,
                            ),
                          ),
                        Expanded(
                          child: Tooltip(
                            message: via == null
                                ? label
                                : '$label → ${NodeLabels.displayName(via!)}',
                            waitDuration: const Duration(milliseconds: 600),
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: titleColor),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: <Widget>[
                        // 协议名照内核给的 type 原样显示，不缩写
                        if (protocol.isNotEmpty) TagChip(label: protocol),
                        if (via != null) ...<Widget>[
                          if (protocol.isNotEmpty) const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              '→ ${NodeLabels.displayName(via!)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              _DelayBadge(
                delay: delay,
                testing: testing,
                unreachable: unreachable,
                live: live,
                onTest: onTest,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 策略组图标。地址由面板下发（sing-box 模板的 `x-sspanel.group_icons`），
/// 首次显示时下载并落盘缓存；没配或取不到的分组退回内置图形。
class _GroupIcon extends StatelessWidget {
  const _GroupIcon({required this.url, required this.selectable});

  final String? url;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget builtin = Icon(
      NodeLabels.groupIcon(selectable: selectable),
      size: 20,
      color: theme.colorScheme.primary,
    );

    if (url == null) {
      return SizedBox(height: 30, width: 30, child: Center(child: builtin));
    }

    // 面板下发的品牌图标都是按浅色背景做的，深色主题下纯黑那几个（Apple、Anthropic、
    // Cursor）与卡片底色糊在一起，垫一层浅色底板才认得出；浅色主题不需要
    return Container(
      height: 30,
      width: 30,
      padding: const EdgeInsets.all(3),
      decoration: theme.brightness == Brightness.dark
          ? BoxDecoration(
              color: const Color(0xFFF2F3F5),
              borderRadius: BorderRadius.circular(AppTheme.tileRadius),
            )
          : null,
      child: RemoteIcon(url: url!, width: 24, fallback: builtin),
    );
  }
}

class _DelayBadge extends StatelessWidget {
  const _DelayBadge({
    required this.delay,
    required this.testing,
    required this.unreachable,
    required this.live,
    required this.onTest,
  });

  final int delay;
  final bool testing;
  final bool unreachable;
  final bool live;
  final VoidCallback onTest;

  Color get _color => switch (delay) {
    < 200 => AppTheme.success,
    < 500 => AppTheme.warning,
    _ => AppTheme.danger,
  };

  @override
  Widget build(BuildContext context) {
    if (testing) {
      return const SizedBox(
        height: 24,
        width: 34,
        child: Center(
          child: SizedBox(
            height: 12,
            width: 12,
            child: CircularProgressIndicator(strokeWidth: 1.6),
          ),
        ),
      );
    }

    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget content = switch ((delay, unreachable)) {
      (> 0, _) => _text('$delay', _color),
      (_, true) => _text('超时', AppTheme.danger),
      _ => Icon(Icons.bolt_outlined, size: 13, color: scheme.outline),
    };

    // 独立的点击区域：点节点本体是切换，点这里只测这一个节点的延迟
    return Tooltip(
      message: live ? '测试该节点延迟' : '连接并测试该节点延迟',
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTest,
        borderRadius: BorderRadius.circular(6),
        mouseCursor: SystemMouseCursors.click,
        child: SizedBox(height: 24, width: 34, child: Center(child: content)),
      ),
    );
  }

  static Widget _text(String text, Color color) => Text(
    text,
    style: TextStyle(
      fontSize: 11,
      height: 1,
      color: color,
      fontWeight: FontWeight.w600,
      fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
    ),
  );
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 34, color: scheme.outline),
          const SizedBox(height: 10),
          Text(
            message,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
