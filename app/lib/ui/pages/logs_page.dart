import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/logger.dart';
import '../../l10n/l10n.dart';
import '../../state/connection_controller.dart';
import '../app_scope.dart';
import '../node_labels.dart';
import '../theme.dart';
import '../widgets/gapped_sliver_list.dart';
import '../widgets/page_header.dart';
import '../widgets/search_field.dart';
import '../widgets/tag_chip.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  // 内核 info 级别下每秒能刷几十条，每条都重建一次列表会把滚动帧吃光；
  // 攒够这个间隔再整体刷新，滚动期间的帧预算留给列表本身
  static const Duration _refreshInterval = Duration(milliseconds: 400);

  List<LogEntry> _visible = const <LogEntry>[];

  LogLevel? _level;
  String _keyword = '';
  Timer? _pending;
  bool _active = true;
  late ConnectionController _connection;

  @override
  void initState() {
    super.initState();
    Logger.instance.addListener(_onEntry);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _connection = AppScope.of(context).connection;
    _active = ShellChrome.maybeOf(context)?.active ?? true;
    _visible = _filter();
  }

  @override
  void dispose() {
    Logger.instance.removeListener(_onEntry);
    _pending?.cancel();
    super.dispose();
  }

  // 搜索范围与行内显示一致：级别、时间、来源、正文（含节点显示名）与入站类型
  List<LogEntry> _filter() {
    final Map<String, String> inbound = _keyword.isEmpty
        ? const <String, String>{}
        : _inboundTypes(_connection);
    return Logger.instance.entries
        .where(
          (LogEntry entry) =>
              (_level == null || entry.level == _level) &&
              (_keyword.isEmpty ||
                  '${entry.level.label} ${_time(entry.time)} ${entry.source} '
                          '${entry.message} ${_shown(entry)} '
                          '${inbound[_inboundKey(entry)] ?? ''}'
                      .toLowerCase()
                      .contains(_keyword)),
        )
        .toList(growable: false)
        .reversed
        .toList(growable: false);
  }

  static String? _inboundKey(LogEntry entry) =>
      _connectionSource.firstMatch(entry.message)?.group(1);

  static String _shown(LogEntry entry) =>
      NodeLabels.annotateText(entry.message);

  // 内核连接日志形如 `[TCP] 198.18.0.1:61593(进程) --> 目标`，只带源地址
  static final RegExp _connectionSource = RegExp(
    r'^\[(?:TCP|UDP)\] (\[[^\]]+\]:\d+|[^\s(]+:\d+)',
  );

  static Map<String, String> _inboundTypes(ConnectionController connection) =>
      <String, String>{
        for (final Map<String, dynamic> item in <Map<String, dynamic>>[
          ...connection.closedConnections.reversed,
          ...connection.connections,
        ])
          if (item['metadata'] case final Map<String, dynamic> meta
              when '${meta['type'] ?? ''}'.isNotEmpty)
            ConnectionController.connectionSource(item): '${meta['type']}',
      };

  void _refresh() {
    _pending?.cancel();
    _pending = null;
    setState(() => _visible = _filter());
  }

  // 隐藏时不过滤也不重建，切回本页时 didChangeDependencies 会按最新日志重算
  void _onEntry(LogEntry entry) {
    if (!mounted || !_active || _pending != null) {
      return;
    }
    _pending = Timer(_refreshInterval, () => mounted ? _refresh() : null);
  }

  static Color _color(LogLevel level, ColorScheme scheme) => switch (level) {
    LogLevel.error => AppTheme.danger,
    LogLevel.warn => AppTheme.warning,
    LogLevel.info => scheme.onSurface,
    _ => scheme.onSurfaceVariant,
  };

  // silent 只是内核的落盘门槛，没有条目会记在这一级，列进来选中必然是空列表
  static const List<LogLevel> _filterable = <LogLevel>[
    LogLevel.debug,
    LogLevel.info,
    LogLevel.warn,
    LogLevel.error,
  ];

  // 铺满整行由 SegmentedButton 自己等分，不能塞进横向滚动条：那样它按自然宽度排版，
  // 窄屏放不下的档位会被裁在屏幕外，也看不出还能横滑
  Widget _levelFilter({required bool compact}) => SegmentedButton<LogLevel?>(
    segments: <ButtonSegment<LogLevel?>>[
      ButtonSegment<LogLevel?>(value: null, label: Text(L10n.t('全部'))),
      for (final LogLevel level in _filterable)
        ButtonSegment<LogLevel?>(value: level, label: Text(level.label)),
    ],
    selected: <LogLevel?>{_level},
    onSelectionChanged: (Set<LogLevel?> value) {
      _level = value.first;
      _refresh();
    },
    showSelectedIcon: false,
    style: compact
        ? SegmentedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            visualDensity: VisualDensity.compact,
          )
        : null,
  );

  Widget _searchActions(ThemeData theme, List<LogEntry> visible) => Row(
    children: <Widget>[
      Text(
        L10n.t('{0} 条', <Object>[visible.length]),
        style: theme.textTheme.bodySmall,
      ),
      const SizedBox(width: 10),
      Expanded(
        child: SearchField(
          hintText: L10n.t('搜索日志内容'),
          width: double.infinity,
          onChanged: (String value) {
            _keyword = value.trim().toLowerCase();
            _refresh();
          },
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<LogEntry> visible = _visible;

    return ShellListenableBuilder(
      listenable: _connection,
      builder: (BuildContext context, _) => LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool narrow = constraints.maxWidth < 640;
          return _list(
            theme,
            scheme,
            visible,
            _filterBar(theme, visible, narrow: narrow),
            _inboundTypes(_connection),
            narrow: narrow,
          );
        },
      ),
    );
  }

  Widget _filterBar(
    ThemeData theme,
    List<LogEntry> visible, {
    required bool narrow,
  }) {
    if (narrow) {
      return Padding(
        padding: AppTheme.pageScrollPadding.copyWith(top: 10, bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _levelFilter(compact: true),
            const SizedBox(height: 8),
            _searchActions(theme, visible),
          ],
        ),
      );
    }
    return Padding(
      padding: AppTheme.pageScrollPadding.copyWith(top: 10, bottom: 10),
      child: Row(
        children: <Widget>[
          _levelFilter(compact: false),
          const SizedBox(width: 10),
          Expanded(child: _searchActions(theme, visible)),
        ],
      ),
    );
  }

  Widget _list(
    ThemeData theme,
    ColorScheme scheme,
    List<LogEntry> visible,
    Widget filter,
    Map<String, String> inboundTypes, {
    required bool narrow,
  }) {
    return CustomScrollView(
      slivers: <Widget>[
        PinnedHeaderSliver(
          child: ColoredBox(
            color: theme.scaffoldBackgroundColor,
            child: Column(
              children: <Widget>[
                PageHeader(title: L10n.t('日志'), showUserAvatar: false),
                filter,
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            14,
            2,
            AppTheme.overlayScrollGutter,
            2,
          ),
          sliver: DecoratedSliver(
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(AppTheme.cardRadius),
            ),
            sliver: visible.isEmpty
                ? SliverFillRemaining(
                    child: Center(child: Text(L10n.t('没有符合条件的日志'))),
                  )
                : GappedSliverList(
                    itemCount: visible.length,
                    gap: 2,
                    // 一行正文加上下内边距；窄屏级别、时间、来源单独占一行
                    rowEstimate:
                        14 +
                        (narrow ? 2 : 1) *
                            MediaQuery.textScalerOf(context)
                                .scale(theme.textTheme.bodyMedium!.fontSize!),
                    itemBuilder: (BuildContext context, int index) {
                      final LogEntry entry = visible[index];
                      final TextStyle messageStyle = theme.textTheme.bodyMedium!
                          .copyWith(color: _color(entry.level, scheme));
                      final double lineSize = messageStyle.fontSize!;
                      final String? inbound = inboundTypes[_inboundKey(entry)];
                      final String shown = _shown(entry);
                      final List<InlineSpan> spans = NodeLabels.flagSpans(
                        shown,
                      );
                      final TextStyle metaStyle = theme.textTheme.bodySmall!
                          .copyWith(fontSize: lineSize);
                      final Widget level = Text(
                        entry.level.label,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: lineSize,
                          fontWeight: FontWeight.w600,
                          color: _color(entry.level, scheme),
                        ),
                      );
                      final Widget time = Text(
                        _time(entry.time),
                        style: metaStyle,
                      );
                      final Widget source = Text(
                        entry.source,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: metaStyle,
                      );
                      // 节点名里的国旗与连接页一样画成旗帜图标；搜索、复制与日志文件仍是原文
                      final Widget message =
                          inbound == null && spans.length == 1
                          ? Text(shown, style: messageStyle)
                          : Text.rich(
                              TextSpan(
                                children: <InlineSpan>[
                                  if (inbound != null)
                                    WidgetSpan(
                                      alignment: PlaceholderAlignment.middle,
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                          right: 6,
                                        ),
                                        child: TagChip(label: inbound),
                                      ),
                                    ),
                                  ...spans,
                                ],
                              ),
                              style: messageStyle,
                            );
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 7,
                        ),
                        // 窄屏三列定宽会把正文挤到一百多宽：级别、时间、来源放一行，正文另起一行占满
                        child: narrow
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Row(
                                    spacing: 8,
                                    children: <Widget>[
                                      level,
                                      time,
                                      Flexible(child: source),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  message,
                                ],
                              )
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  SizedBox(width: 72, child: level),
                                  const SizedBox(width: 6),
                                  // 时间按字形实际宽度排：Linux 回退字体比 62 宽，定宽会压到来源上
                                  time,
                                  const SizedBox(width: 8),
                                  SizedBox(width: 82, child: source),
                                  Expanded(child: message),
                                ],
                              ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  static String _time(DateTime value) =>
      '${_two(value.hour)}:${_two(value.minute)}:${_two(value.second)}';

  static String _two(int value) => value.toString().padLeft(2, '0');
}
