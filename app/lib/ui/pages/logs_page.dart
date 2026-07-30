import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/logger.dart';
import '../theme.dart';
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

  // 逐档筛选，null 为不筛。按钮读起来是「日志类型」，用「不低于该级别」的阈值语义
  // 会让选 info 时仍混进一堆 error，看着像筛选没生效
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

  // 过滤只在数据或条件变化时做一次，不放在 build 里按帧重算
  List<LogEntry> _filter() => Logger.instance.entries
      .where(
        (LogEntry entry) =>
            (_level == null || entry.level == _level) &&
            (_keyword.isEmpty ||
                entry.message.toLowerCase().contains(_keyword) ||
                entry.source.toLowerCase().contains(_keyword)),
      )
      .toList(growable: false)
      .reversed
      .toList(growable: false);

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

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<LogEntry> visible = _visible;

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          child: Row(
            children: <Widget>[
              SegmentedButton<LogLevel?>(
                segments: <ButtonSegment<LogLevel?>>[
                  const ButtonSegment<LogLevel?>(
                    value: null,
                    label: Text('全部'),
                  ),
                  for (final LogLevel level in LogLevel.values)
                    ButtonSegment<LogLevel?>(
                      value: level,
                      label: Text(level.label),
                    ),
                ],
                selected: <LogLevel?>{_level},
                onSelectionChanged: (Set<LogLevel?> value) {
                  _level = value.first;
                  _refresh();
                },
                showSelectedIcon: false,
              ),
              const SizedBox(width: 10),
              Text('${visible.length} 条', style: theme.textTheme.bodySmall),
              const Spacer(),
              // 级别按钮占的宽度是固定的，窗口收窄时只能让搜索框先让位
              Flexible(
                child: SearchField(
                  hintText: '搜索日志内容',
                  onChanged: (String value) {
                    _keyword = value.trim().toLowerCase();
                    _refresh();
                  },
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: '复制当前列表',
                icon: const Icon(Icons.copy_all_outlined, size: 16),
                visualDensity: VisualDensity.compact,
                onPressed: () => Clipboard.setData(
                  ClipboardData(
                    text: visible
                        .map((LogEntry entry) => entry.toString())
                        .join('\n'),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: visible.isEmpty
              ? const Center(child: Text('没有符合条件的日志'))
              : SelectionArea(
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    itemCount: visible.length,
                    // 每行都是可选中文本时滚动会明显掉帧：选区命中测试要为每个
                    // 子节点各建一份，条目一多就顶不住。列表整体套一个
                    // SelectionArea，行内用普通 Text
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
                                entry.message,
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
