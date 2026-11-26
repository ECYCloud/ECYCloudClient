import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderAbstractViewport, SliverConstraints;

import '../../domain/kernel/clash_api_client.dart';
import '../../domain/nodes/node_group_sort.dart';
import '../../state/connection_controller.dart';
import '../app_scope.dart';
import '../node_labels.dart';
import '../theme.dart';
import '../widgets/delay_badge.dart';
import '../widgets/flag_icon.dart';
import '../widgets/gapped_sliver_list.dart';
import '../widgets/group_delay_test_button.dart';
import '../widgets/group_icon.dart';
import '../widgets/group_sort_button.dart';
import '../widgets/group_speed_test_button.dart';
import '../widgets/page_header.dart';
import '../widgets/refresh_button.dart';
import '../widgets/search_field.dart';
import '../widgets/speed_badge.dart';
import '../widgets/tag_chip.dart';
import '../widgets/touch_bleed.dart';
import '../../l10n/l10n.dart';

const double _groupCardGap = 10;
const double _groupPinnedGap = 4;

class NodesPage extends StatelessWidget {
  const NodesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ConnectionController connection = AppScope.of(context).connection;

    return ShellListenableBuilder(
      listenable: connection,
      builder: (BuildContext context, _) {
        final List<ProxyGroup> groups = connection.groupsForMode;
        final bool live = connection.controlPlaneReady;

        return CustomScrollView(
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: PageHeader(
                title: L10n.t('节点'),
                showUserAvatar: false,
                actions: <Widget>[
                  RefreshButton(
                    tooltip: L10n.t('刷新节点'),
                    onRefresh: connection.refreshProfileFromPanel,
                  ),
                ],
              ),
            ),
            if (groups.isEmpty)
              SliverFillRemaining(
                child: _Placeholder(
                  icon: connection.routeMode == 'direct'
                      ? Icons.public
                      : Icons.inbox_outlined,
                  message: connection.routeMode == 'direct'
                      ? L10n.t('直连')
                      : L10n.t('面板未下发节点分组'),
                ),
              )
            else ...<Widget>[
              for (int i = 0; i < groups.length; i++) ...<Widget>[
                if (i > 0)
                  const SliverToBoxAdapter(
                    child: SizedBox(height: _groupCardGap - _groupPinnedGap),
                  ),
                _GroupCard(
                  key: ValueKey<String>(groups[i].name),
                  group: groups[i],
                  live: live,
                  connection: connection,
                  initiallyExpanded: connection.routeMode == 'global',
                ),
              ],
              const SliverToBoxAdapter(child: SizedBox(height: 14)),
            ],
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
    this.initiallyExpanded = false,
    super.key,
  });

  final ProxyGroup group;
  final bool live;
  final ConnectionController connection;
  final bool initiallyExpanded;

  @override
  State<_GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<_GroupCard> {
  // 须放下 VLESS + TCP + REALITY + XUDP 单行，再窄就减列而不是把标签折行
  static const double _minTileWidth = 260;
  static const double _tileGap = 8;
  static const double _tileEstimate = 52;

  final GlobalKey _selectedTileKey = GlobalKey();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  late bool _expanded;
  NodeGroupSort _sort = NodeGroupSort.name;
  bool _searchOpen = false;
  String _query = '';
  Timer? _searchTimer;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // 面板上还有没列出的成员时，本地过滤只看得到已知节点，停止输入 400 毫秒后再向面板查
  void _search(String value) {
    setState(() => _query = value.trim().toLowerCase());
    _searchTimer?.cancel();
    final ConnectionController connection = widget.connection;
    final ProxyGroup group = widget.group;
    if (_query.isEmpty ||
        connection.memberTotalOf(group) <= group.members.length) {
      return;
    }
    final String query = _query;
    _searchTimer = Timer(
      const Duration(milliseconds: 400),
      () => unawaited(connection.loadMoreNodes(group.name, query: query)),
    );
  }

  void _toast(String? message) {
    if (message == null || message.isEmpty || !mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _locateSelected() async {
    if (!_expanded) {
      setState(() => _expanded = true);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) {
        return;
      }
    }
    final BuildContext? target = _selectedTileKey.currentContext;
    if (target == null || !target.mounted) {
      return;
    }
    await Scrollable.ensureVisible(
      target,
      alignment: 0.5,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
    );
  }

  static String _nowLabel(ConnectionController connection, ProxyGroup group) {
    if (group.now.isEmpty) {
      return '';
    }
    final String leaf = connection.resolveNode(group.now);
    return leaf == group.now
        ? L10n.t(' · 当前 {0}', <Object>[NodeLabels.displayName(group.now)])
        : L10n.t(' · 当前 {0} → {1}', <Object>[
            NodeLabels.displayName(group.now),
            NodeLabels.displayName(leaf),
          ]);
  }

  static List<Widget> _groupMeta(
    BuildContext context,
    ConnectionController connection,
    ProxyGroup group,
    ThemeData theme,
    ColorScheme scheme, {
    required bool expanded,
  }) {
    final String now = _nowLabel(connection, group);
    final TextStyle? style = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    if (AppTheme.isWide(context)) {
      return <Widget>[
        Text(
          L10n.t('{0} 个节点{1}', <Object>[connection.memberTotalOf(group), now]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      ];
    }
    return <Widget>[
      if (now.isNotEmpty)
        Text(
          now.startsWith(' · ') ? now.substring(3) : now,
          maxLines: expanded ? null : 1,
          overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
          style: style,
        ),
    ];
  }

  Widget _buildTile(
    ConnectionController connection,
    ProxyGroup group,
    String member, {
    required bool canSelect,
  }) {
    final String leaf = connection.resolveNode(member);
    final ProxyGroup? nested = connection.groupByName(member);

    return _NodeTile(
      name: member,
      groupTag: nested == null
          ? null
          : (nested.selectable ? L10n.t('手动') : L10n.t('自动')),
      via: leaf == member ? null : leaf,
      protocol: leaf == member ? connection.typeOf(leaf) : '',
      network: leaf == member ? connection.networkOf(leaf) : '',
      tls: leaf == member ? connection.tlsOf(leaf) : '',
      udp: leaf == member ? connection.udpOf(leaf) : '',
      selected: member == group.now,
      // 必须走 delayOf：逐个探测的结果先落在控制器的延迟表里，
      // 取 ProxyNode.delay 要等下一轮 /proxies 才更新，看着像没反应
      delay: connection.delayOf(leaf),
      testing: connection.testingNodes.contains(leaf),
      unreachable: connection.unreachableNodes.contains(leaf),
      speed: connection.speedOf(leaf),
      speedTesting: connection.testingSpeedNodes.contains(leaf),
      speedFailed: connection.speedFailedNodes.contains(leaf),
      onSelect: canSelect
          ? () => connection.selectProxy(group.name, member)
          : null,
      onTest: () => connection.testDelay(member),
      onSpeedTest: () => unawaited(() async {
        _toast(await connection.testSpeed(member));
      }()),
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
    final bool speedTesting = connection.testingSpeedGroups.contains(
      group.name,
    );
    final bool wide = AppTheme.isWide(context);
    final bool searching = _searchOpen && _query.isNotEmpty;
    // 折叠着的分组不排序：每次刷新所有分组都会重建，成员多时白白排一遍
    final List<String> members = !_expanded
        ? const <String>[]
        : <String>[
            for (final String member in NodeGroupSortLogic.apply(
              members: group.members,
              mode: _sort,
              delayOf: (String name) =>
                  connection.delayOf(connection.resolveNode(name)),
              speedOf: (String name) =>
                  connection.speedOf(connection.resolveNode(name)),
            ))
              if (!searching ||
                  _matchesQuery(member) ||
                  connection.nodeMatched(group.name, member, _query))
                member,
          ];
    final bool loading = connection.loadingNodes(group.name);
    final String? loadError = connection.nodesErrorOf(group.name);
    final bool more =
        _expanded &&
        connection.memberTotalOf(group) > group.members.length &&
        (loadError != null ||
            connection.hasMoreNodes(
              group.name,
              query: searching ? _query : '',
            ));
    void loadMore() => unawaited(
      connection.loadMoreNodes(group.name, query: searching ? _query : ''),
    );

    final List<Widget> actions = <Widget>[
      GroupDelayTestButton(
        testing: testing,
        inMenu: !wide,
        onPressed: () => connection.testGroup(group.name),
      ),
      GroupSpeedTestButton(
        testing: speedTesting,
        inMenu: !wide,
        onPressed: () => unawaited(() async {
          _toast(await connection.testGroupSpeed(group.name));
        }()),
      ),
      GroupSortButton(
        mode: _sort,
        inMenu: !wide,
        onPressed: () => setState(() => _sort = NodeGroupSortLogic.next(_sort)),
      ),
      if (wide)
        TouchBleed(
          child: IconButton(
            tooltip: L10n.t('搜索节点名称'),
            iconSize: 16,
            visualDensity: VisualDensity.standard,
            constraints: AppTheme.iconButtonBox,
            padding: EdgeInsets.zero,
            style: _searchOpen
                ? IconButton.styleFrom(
                    backgroundColor: scheme.onSurfaceVariant.withValues(
                      alpha: 0.08,
                    ),
                  )
                : null,
            icon: const Icon(Icons.search),
            onPressed: _toggleSearch,
          ),
        )
      else
        MenuItemButton(
          leadingIcon: const Icon(Icons.search, size: 16),
          style: MenuItemButton.styleFrom(
            backgroundColor: _searchOpen
                ? scheme.onSurfaceVariant.withValues(alpha: 0.08)
                : null,
            textStyle: theme.textTheme.bodyMedium,
            minimumSize: Size(0, AppTheme.minTapTarget),
            visualDensity: VisualDensity.standard,
          ),
          onPressed: _toggleSearch,
          child: Text(L10n.t('搜索节点名称')),
        ),
      if (wide)
        TouchBleed(
          child: IconButton(
            tooltip: L10n.t('定位到当前节点'),
            iconSize: 16,
            visualDensity: VisualDensity.standard,
            constraints: AppTheme.iconButtonBox,
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.my_location_outlined),
            onPressed: group.now.isEmpty
                ? null
                : () => unawaited(_locateSelected()),
          ),
        )
      else
        MenuItemButton(
          leadingIcon: const Icon(Icons.my_location_outlined, size: 16),
          style: MenuItemButton.styleFrom(
            textStyle: theme.textTheme.bodyMedium,
            minimumSize: Size(0, AppTheme.minTapTarget),
            visualDensity: VisualDensity.standard,
          ),
          onPressed: group.now.isEmpty
              ? null
              : () => unawaited(_locateSelected()),
          child: Text(L10n.t('定位到当前节点')),
        ),
    ];
    final ShapeBorder headerShape = _cardShape(top: true, bottom: !_expanded);
    final ShapeBorder bodyShape = _cardShape(top: false, bottom: true);

    return SliverMainAxisGroup(
      slivers: <Widget>[
        PinnedHeaderSliver(
          child: ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: Padding(
              padding: EdgeInsets.only(
                left: AppTheme.pageScrollPadding.left,
                right: AppTheme.pageScrollPadding.right,
                top: _groupPinnedGap,
              ),
              child: Material(
                color: scheme.surface,
                shape: headerShape,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  mouseCursor: SystemMouseCursors.click,
                  hoverColor: scheme.surfaceContainerHighest,
                  splashColor: scheme.surfaceContainerHighest,
                  highlightColor: scheme.surfaceContainerHighest,
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 54),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: wide ? 0 : 10,
                      ),
                      child: Row(
                        children: <Widget>[
                          GroupIcon(
                            url: connection.groupIconOf(group.name),
                            selectable: group.selectable,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: <Widget>[
                                Row(
                                  children: <Widget>[
                                    Flexible(
                                      child: Text(
                                        NodeLabels.displayName(group.name),
                                        maxLines: !wide && _expanded ? null : 1,
                                        overflow: !wide && _expanded
                                            ? TextOverflow.visible
                                            : TextOverflow.ellipsis,
                                        style: theme.textTheme.titleSmall,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    TagChip(
                                      label:
                                          (group.selectable
                                              ? L10n.t('手动')
                                              : L10n.t('自动')) +
                                          (wide
                                              ? ''
                                              : ' · ${connection.memberTotalOf(group)}'),
                                    ),
                                  ],
                                ),
                                ..._groupMeta(
                                  context,
                                  connection,
                                  group,
                                  theme,
                                  scheme,
                                  expanded: _expanded,
                                ),
                              ],
                            ),
                          ),
                          if (wide)
                            ...actions
                          else
                            MenuAnchor(
                              style: MenuStyle(
                                alignment: AlignmentDirectional.bottomEnd,
                                shape: WidgetStatePropertyAll<OutlinedBorder>(
                                  RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      AppTheme.menuRadius,
                                    ),
                                  ),
                                ),
                              ),
                              menuChildren: actions,
                              builder:
                                  (
                                    BuildContext context,
                                    MenuController controller,
                                    Widget? child,
                                  ) => TouchBleed(
                                    child: IconButton(
                                      tooltip: L10n.t('更多'),
                                      iconSize: 18,
                                      visualDensity: VisualDensity.standard,
                                      constraints: AppTheme.iconButtonBox,
                                      padding: EdgeInsets.zero,
                                      icon: testing || speedTesting
                                          ? const SizedBox(
                                              width: 14,
                                              height: 14,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : const Icon(Icons.more_horiz),
                                      onPressed: () => controller.isOpen
                                          ? controller.close()
                                          : controller.open(),
                                    ),
                                  ),
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
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_expanded)
          SliverPadding(
            padding: EdgeInsets.only(
              left: AppTheme.pageScrollPadding.left,
              right: AppTheme.pageScrollPadding.right,
            ),
            sliver: DecoratedSliver(
              decoration: ShapeDecoration(
                color: scheme.surfaceContainerLowest,
                shape: bodyShape,
              ),
              sliver: SliverPadding(
                padding: const EdgeInsets.only(bottom: 12),
                sliver: SliverMainAxisGroup(
                  slivers: <Widget>[
                    SliverToBoxAdapter(
                      child: Material(
                        type: MaterialType.transparency,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const SizedBox(height: 10),
                            if (_searchOpen)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  0,
                                  12,
                                  10,
                                ),
                                child: SearchField(
                                  controller: _searchController,
                                  focusNode: _searchFocus,
                                  hintText: L10n.t('搜索节点名称'),
                                  width: double.infinity,
                                  onChanged: _search,
                                ),
                              ),
                            if (!group.selectable)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  0,
                                  12,
                                  0,
                                ),
                                child: _AutoGroupHint(
                                  connection: connection,
                                  group: group,
                                ),
                              ),
                            if (_query.isNotEmpty && members.isEmpty)
                              loading || loadError != null
                                  ? _MoreNodes(
                                      loading: loading,
                                      error: loadError,
                                      onLoad: loadMore,
                                    )
                                  : Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      child: Text(
                                        L10n.t('没有符合条件的节点'),
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: scheme.onSurfaceVariant,
                                            ),
                                      ),
                                    ),
                          ],
                        ),
                      ),
                    ),
                    // 成员可能上万个：按行懒加载，只构建滚动到的那几行，一次全部构建会卡死界面
                    if (members.isNotEmpty)
                      SliverLayoutBuilder(
                        builder:
                            (
                              BuildContext context,
                              SliverConstraints constraints,
                            ) {
                              final int columns =
                                  ((constraints.crossAxisExtent + _tileGap) /
                                          (_minTileWidth + _tileGap))
                                      .floor()
                                      .clamp(1, 6);
                              final double tileWidth =
                                  (constraints.crossAxisExtent -
                                      _tileGap * (columns - 1)) /
                                  columns;

                              final int rows =
                                  (members.length + columns - 1) ~/ columns;
                              return GappedSliverList(
                                // 末尾多出的一行滚到才构建，构建即向面板取下一页
                                itemCount: rows + (more ? 1 : 0),
                                gap: _tileGap,
                                rowEstimate: _tileEstimate,
                                itemBuilder: (BuildContext context, int row) =>
                                    row == rows
                                    ? _MoreNodes(
                                        loading: loading,
                                        error: loadError,
                                        onLoad: loadMore,
                                      )
                                    : Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        spacing: _tileGap,
                                        children: <Widget>[
                                          for (final String member
                                              in members
                                                  .skip(row * columns)
                                                  .take(columns))
                                            SizedBox(
                                              key: member == group.now
                                                  ? _selectedTileKey
                                                  : null,
                                              width: tileWidth,
                                              child: _buildTile(
                                                connection,
                                                group,
                                                member,
                                                canSelect: canSelect,
                                              ),
                                            ),
                                        ],
                                      ),
                              );
                            },
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _toggleSearch() {
    final bool open = !_searchOpen;
    setState(() {
      _searchOpen = open;
      if (open) {
        _expanded = true;
      }
    });
    if (!open) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _searchOpen) {
        _searchFocus.requestFocus();
      }
    });
  }

  bool _matchesQuery(String member) {
    final String shown = NodeLabels.displayName(member);
    return (shown.isEmpty ? member : shown).toLowerCase().contains(_query);
  }

  ShapeBorder _cardShape({required bool top, required bool bottom}) {
    final Radius radius = Radius.circular(
      AppTheme.isWide(context) ? AppTheme.cardRadius : AppTheme.menuRadius,
    );
    return RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: top ? radius : Radius.zero,
        bottom: bottom ? radius : Radius.zero,
      ),
    );
  }
}

class _MoreNodes extends StatefulWidget {
  const _MoreNodes({
    required this.loading,
    required this.error,
    required this.onLoad,
  });

  final bool loading;
  final String? error;
  final VoidCallback onLoad;

  @override
  State<_MoreNodes> createState() => _MoreNodesState();
}

class _MoreNodesState extends State<_MoreNodes> {
  ScrollPosition? _position;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ScrollPosition? position = Scrollable.maybeOf(context)?.position;
    if (!identical(position, _position)) {
      _position?.removeListener(_loadWhenReached);
      _position = position?..addListener(_loadWhenReached);
    }
  }

  @override
  void dispose() {
    _position?.removeListener(_loadWhenReached);
    super.dispose();
  }

  // 只在这一行真的滚进视口时取下一页：列表为了算滚动条会预先量一遍全部行，
  // 以「构建到这一行」为准就会不等滚动一页接一页取到底
  void _loadWhenReached() {
    final ScrollPosition? position = _position;
    final RenderObject? box = mounted ? context.findRenderObject() : null;
    if (widget.loading ||
        widget.error != null ||
        position == null ||
        box == null ||
        !box.attached) {
      return;
    }
    final double top = RenderAbstractViewport.of(box)
        .getOffsetToReveal(box, 0)
        .offset;
    if (top < position.pixels + position.viewportDimension) {
      widget.onLoad();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? error = widget.error;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadWhenReached());
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: error == null
          ? const SizedBox(
              height: 32,
              child: Center(
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          : Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    L10n.t('加载失败：{0}', <Object>[error]),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton(onPressed: widget.onLoad, child: Text(L10n.t('重试'))),
              ],
            ),
    );
  }
}

class _AutoGroupHint extends StatelessWidget {
  const _AutoGroupHint({required this.connection, required this.group});

  final ConnectionController connection;
  final ProxyGroup group;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String detail = _detail();

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: <Widget>[
          Icon(Icons.auto_awesome_outlined, size: 13, color: scheme.outline),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              detail,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  String _detail() {
    if (group.type == 'Fallback') {
      return L10n.t('本组由内核按列表顺序选用第一个可用节点，点击节点不改变选中项；测延迟会刷新可用性并让内核立即重选');
    }

    final String? fastest = connection.fastestMember(group);
    if (fastest == null || fastest == group.now) {
      return L10n.t('本组由内核按延迟自动选择，点击节点不改变选中项；测延迟会让内核立即重选');
    }
    return L10n.t('本组由内核按延迟自动选择，当前最优为 {0}；点上方测延迟可让内核立即切过去', <Object>[
      NodeLabels.displayName(fastest),
    ]);
  }
}

class _NodeTile extends StatelessWidget {
  const _NodeTile({
    required this.name,
    required this.groupTag,
    required this.via,
    required this.protocol,
    required this.network,
    required this.tls,
    required this.udp,
    required this.selected,
    required this.delay,
    required this.testing,
    required this.unreachable,
    required this.speed,
    required this.speedTesting,
    required this.speedFailed,
    required this.onSelect,
    required this.onTest,
    required this.onSpeedTest,
  });

  final String name;

  final String? groupTag;

  final String? via;
  final String protocol;
  final String network;
  final String tls;
  final String udp;
  final bool selected;
  final int delay;
  final bool testing;
  final bool unreachable;
  final int speed;
  final bool speedTesting;
  final bool speedFailed;
  final VoidCallback? onSelect;
  final VoidCallback onTest;
  final VoidCallback onSpeedTest;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? region = NodeLabels.region(via ?? name);
    final String label = NodeLabels.displayName(name);
    final Color titleColor = scheme.onSurface;

    return Material(
      color: selected
          ? Color.alphaBlend(
              scheme.primary.withValues(alpha: 0.16),
              scheme.surface,
            )
          : scheme.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.tileRadius),
        side: selected ? BorderSide(color: scheme.primary) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onSelect,
        mouseCursor: onSelect == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            4.5,
            AppTheme.trailingIconButtonInset(16) - 4,
            4.5,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Tooltip(
                      message: via == null
                          ? NodeLabels.originalName(name)
                          : '${NodeLabels.originalName(name)} → ${NodeLabels.originalName(via!)}',
                      waitDuration: const Duration(milliseconds: 600),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: <Widget>[
                          if (selected)
                            Positioned(
                              left: -16,
                              top: 0,
                              bottom: 0,
                              child: Icon(
                                Icons.check_circle,
                                size: 12,
                                color: scheme.primary,
                              ),
                            ),
                          Row(
                            children: <Widget>[
                              if (via == null && region != null) ...<Widget>[
                                FlagIcon(code: region),
                                const SizedBox(width: 4),
                              ],
                              Flexible(
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(color: titleColor),
                                ),
                              ),
                              if (groupTag != null) ...<Widget>[
                                const SizedBox(width: 6),
                                TagChip(label: groupTag!),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (via != null)
                      Row(
                        children: <Widget>[
                          if (region != null) ...<Widget>[
                            FlagIcon(code: region),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              NodeLabels.displayName(via!),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                        ],
                      )
                    else
                      TagChip.wrap(
                        protocol: protocol,
                        network: network,
                        tls: tls,
                        udp: udp,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              // 触控盒是 48，两枚照原样叠会把卡片撑到桌面的近两倍。
              SizedBox(
                height: AppTheme.pointerTapTarget * 2,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    SizedBox(
                      height: AppTheme.pointerTapTarget,
                      child: DelayBadge(
                        delay: delay,
                        testing: testing,
                        unreachable: unreachable,
                        onTest: onTest,
                      ),
                    ),
                    SizedBox(
                      height: AppTheme.pointerTapTarget,
                      child: SpeedBadge(
                        bytesPerSecond: speed,
                        testing: speedTesting,
                        failed: speedFailed,
                        onTest: onSpeedTest,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
            style: Theme.of(context).textTheme.bodyLarge
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
