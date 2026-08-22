import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/logger.dart';
import '../../l10n/l10n.dart';
import '../node_labels.dart';
import '../theme.dart';
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

  final ScrollController _scroll = ScrollController();
  List<LogEntry> _visible = const <LogEntry>[];

  LogLevel? _level;
  String _keyword = '';
  Timer? _pending;

  @override
  void initState() {
    super.initState();
    _visible = _filter();
    Logger.instance.addListener(_onEntry);
  }

  @override
  void dispose() {
    Logger.instance.removeListener(_onEntry);
    _pending?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  List<LogEntry> _filter() => Logger.instance.entries
      .where(
        (LogEntry entry) =>
            (_level == null || entry.level == _level) &&
            (_keyword.isEmpty ||
                entry.source.toLowerCase().contains(_keyword) ||
                entry.message.toLowerCase().contains(_keyword) ||
                NodeLabels.annotateText(
                  entry.message,
                ).toLowerCase().contains(_keyword)),
      )
      .toList(growable: false)
      .reversed
      .toList(growable: false);

  static String _shown(LogEntry entry) =>
      NodeLabels.annotateText(entry.message);

  void _refresh() {
    _pending?.cancel();
    _pending = null;
    setState(() => _visible = _filter());
  }

  void _onEntry(LogEntry entry) {
    if (!mounted || _pending != null) {
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
  Widget _levelFilter(ThemeData theme, {required bool compact}) =>
      SegmentedButton<LogLevel?>(
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
                // 必须从主题派生：给裸 TextStyle 会与默认样式的 inherit 不一致，
                // 选中动画插值时抛断言
                textStyle: theme.textTheme.labelLarge?.copyWith(fontSize: 12),
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
      const SizedBox(width: 4),
      IconButton(
        tooltip: L10n.t('复制当前列表'),
        icon: const Icon(Icons.copy_all_outlined, size: 16),
        visualDensity: VisualDensity.compact,
        onPressed: () => Clipboard.setData(
          ClipboardData(
            text: visible
                .map(
                  (LogEntry entry) =>
                      '${entry.time.toIso8601String()} [${entry.level.label}] [${entry.source}] ${_shown(entry)}',
                )
                .join('\n'),
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<LogEntry> visible = _visible;

    return Column(
      children: <Widget>[
        PageHeader(title: L10n.t('日志')),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // 与 Shell 宽屏断点一致：窄屏级别条会吃光整行，搜索/复制必须换行
            final bool narrow = constraints.maxWidth < 640;
            if (narrow) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _levelFilter(theme, compact: true),
                    const SizedBox(height: 8),
                    _searchActions(theme, visible),
                  ],
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              child: Row(
                children: <Widget>[
                  _levelFilter(theme, compact: false),
                  const SizedBox(width: 10),
                  Expanded(child: _searchActions(theme, visible)),
                ],
              ),
            );
          },
        ),
        const Divider(height: 1),
        Expanded(
          child: visible.isEmpty
              ? Center(child: Text(L10n.t('没有符合条件的日志')))
              : SelectionArea(
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(
                      14,
                      6,
                      AppTheme.overlayScrollGutter,
                      6,
                    ),
                    itemCount: visible.length,
                    // 每行都是可选中文本时滚动会明显掉帧：选区命中测试要为每个
                    // 子节点各建一份，条目一多就顶不住
                    itemBuilder: (BuildContext context, int index) {
                      final LogEntry entry = visible[index];

                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2.5),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            TagChip(
                              label: entry.level.label,
                              color: _color(entry.level, scheme),
                            ),
                            const SizedBox(width: 6),
                            SizedBox(
                              width: 62,
                              child: Text(
                                _time(entry.time),
                                style: _mono(scheme.onSurfaceVariant),
                              ),
                            ),
                            SizedBox(
                              width: 82,
                              child: Text(
                                entry.source,
                                overflow: TextOverflow.ellipsis,
                                style: _mono(scheme.onSurfaceVariant),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                _shown(entry),
                                style: _mono(_color(entry.level, scheme)),
                              ),
                            ),
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

  static TextStyle _mono(Color color) =>
      TextStyle(fontFamily: 'Consolas', fontSize: 12, color: color);

  static String _time(DateTime value) =>
      '${_two(value.hour)}:${_two(value.minute)}:${_two(value.second)}';

  static String _two(int value) => value.toString().padLeft(2, '0');
}
