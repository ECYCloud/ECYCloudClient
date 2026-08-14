import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/api/api_exception.dart';
import '../../data/api/panel_api_client.dart';
import '../../data/models/account.dart';
import '../app_scope.dart';
import '../format.dart';
import '../shell_navigator.dart';
import '../theme.dart';
import '../widgets/page_header.dart';
import '../widgets/refresh_button.dart';
import '../widgets/section_card.dart';
import '../widgets/simple_data_table.dart';

/// 与网页 trafficlog.tpl 列一致的可排序字段。
enum _TrafficSortCol { date, upload, download, rate, usage, nodeName }

enum _TrafficSortType { date, traffic, rate, string }

_TrafficSortType _sortTypeOf(_TrafficSortCol col) => switch (col) {
  _TrafficSortCol.date => _TrafficSortType.date,
  _TrafficSortCol.upload ||
  _TrafficSortCol.download ||
  _TrafficSortCol.usage => _TrafficSortType.traffic,
  _TrafficSortCol.rate => _TrafficSortType.rate,
  _TrafficSortCol.nodeName => _TrafficSortType.string,
};

/// 对齐网页 `sortKey`：流量串 / 倍率 / 日期 / 文本。
Comparable<Object> _sortKey(String text, _TrafficSortType type) {
  final String raw = text.trim();
  switch (type) {
    case _TrafficSortType.traffic:
      final String s = raw.replaceAll(RegExp(r'\s+'), '');
      final Match? m = RegExp(
        r'^(-?\d+(?:\.\d+)?)([A-Za-z]+)$',
      ).firstMatch(s);
      if (m == null) {
        return double.tryParse(s) ?? 0;
      }
      const Map<String, int> units = <String, int>{
        'B': 0,
        'KB': 1,
        'MB': 2,
        'GB': 3,
        'TB': 4,
        'PB': 5,
        'EB': 6,
        'ZB': 7,
        'YB': 8,
      };
      final double n = double.tryParse(m.group(1)!) ?? 0;
      final int p = units[m.group(2)!.toUpperCase()] ?? 0;
      double scale = 1;
      for (int i = 0; i < p; i++) {
        scale *= 1024;
      }
      return n * scale;
    case _TrafficSortType.rate:
      final Match? r = RegExp(r'-?\d+(?:\.\d+)?').firstMatch(raw);
      return r == null ? 0.0 : (double.tryParse(r.group(0)!) ?? 0);
    case _TrafficSortType.date:
      final Match? d = RegExp(r'\d{4}-\d{2}-\d{2}').firstMatch(raw);
      return d?.group(0) ?? raw;
    case _TrafficSortType.string:
      return raw.toLowerCase();
  }
}

int _compareSortKeys(Object a, Object b, _TrafficSortType type, bool asc) {
  final int c;
  if (type == _TrafficSortType.date || type == _TrafficSortType.string) {
    c = a.toString().compareTo(b.toString());
  } else {
    c = (a as num).compareTo(b as num);
  }
  return asc ? c : -c;
}

class TrafficLogPage extends StatefulWidget {
  const TrafficLogPage({super.key});

  @override
  State<TrafficLogPage> createState() => _TrafficLogPageState();
}

class _TrafficLogPageState extends State<TrafficLogPage> {
  TrafficLogBundle? _bundle;
  String? _error;
  bool _busy = false;
  bool _started = false;
  String? _expandedDay;
  _TrafficSortCol? _daySortCol;
  bool _daySortAsc = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final PanelApiClient? api = AppScope.of(context).auth.api;
    if (api == null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final TrafficLogBundle bundle = await api.fetchTrafficLog();
      if (!mounted) {
        return;
      }
      setState(() {
        _bundle = bundle;
        _busy = false;
      });
    } on Object catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = e is ApiException ? e.message : '加载失败：$e';
        _busy = false;
      });
    }
  }

  List<String> _allDays(TrafficLogBundle bundle) {
    final List<String> days = bundle.traffic.keys.toList();
    final _TrafficSortCol? col = _daySortCol;
    if (col == null) {
      days.sort((String a, String b) => b.compareTo(a));
      return days;
    }
    final _TrafficSortType type = _sortTypeOf(col);
    days.sort((String a, String b) {
      final Object va = _daySortValue(bundle, a, col);
      final Object vb = _daySortValue(bundle, b, col);
      return _compareSortKeys(va, vb, type, _daySortAsc);
    });
    return days;
  }

  Object _daySortValue(
    TrafficLogBundle bundle,
    String day,
    _TrafficSortCol col,
  ) {
    final TrafficDayTotal? t = bundle.traffic[day];
    switch (col) {
      case _TrafficSortCol.date:
        return _sortKey(day, _TrafficSortType.date);
      case _TrafficSortCol.upload:
        return _sortKey(t?.totalUpload ?? '0B', _TrafficSortType.traffic);
      case _TrafficSortCol.download:
        return _sortKey(t?.totalDownload ?? '0B', _TrafficSortType.traffic);
      case _TrafficSortCol.rate:
        return _sortKey(t?.rateInfo ?? '', _TrafficSortType.rate);
      case _TrafficSortCol.usage:
        return _sortKey(t?.totalUsage ?? '0B', _TrafficSortType.traffic);
      case _TrafficSortCol.nodeName:
        return '';
    }
  }

  void _onDaySort(_TrafficSortCol col) {
    setState(() {
      if (_daySortCol == col) {
        _daySortAsc = !_daySortAsc;
      } else {
        _daySortCol = col;
        _daySortAsc = true;
      }
    });
  }

  void _toggleDay(String day) {
    setState(() {
      _expandedDay = _expandedDay == day ? null : day;
    });
  }

  Future<void> _showTrafficInfo() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('流量记录说明'),
        content: const SingleChildScrollView(
          child: Text(
            '如果您手动测试了一些节点的延迟或者您使用了包含自动选择和故障转移策略的订阅，如：Clash / Stash、'
            'Surge等自带分流策略的订阅链接，以及Quantumult X、Shadowrocket、Loon等带自动测试的分流规则，'
            '会每隔一段时间测试一次延迟(通常是每5分钟左右)，以检查最低延迟的节点以及节点存活性，'
            '这部分测试也会被计入流量，通常每个节点在一小时内自动测试延迟所消耗的流量在1-5KB左右。\n\n'
            '如需关闭自动测试可在本客户端的账户信息 → 自定义策略 → 分组策略中关闭自动选择和故障转移策略组。',
          ),
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('我知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TrafficLogBundle? bundle = _bundle;
    final List<String> days =
        bundle == null ? const <String>[] : _allDays(bundle);
    final String? expandedDay =
        _expandedDay != null && days.contains(_expandedDay)
        ? _expandedDay
        : null;
    final int keepDays = bundle?.logKeepDays ?? 30;

    return Scaffold(
      body: Column(
        children: <Widget>[
          SafeArea(
            bottom: false,
            child: PageHeader(
              title: '流量记录',
              showBackButton: true,
              showUserAvatar: true,
              actions: <Widget>[
                RefreshButton(tooltip: '刷新', onRefresh: _load),
              ],
            ),
          ),
          Expanded(
            child: _busy && bundle == null
                ? const Center(child: CircularProgressIndicator())
                : _error != null && bundle == null
                ? Center(child: Text(_error!))
                : bundle == null
                ? const SizedBox.shrink()
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.all(14),
                      children: <Widget>[
                        SectionCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                '此处只展示最近 $keepDays 天的每日流量记录。',
                                style: theme.textTheme.bodyMedium,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '当天的流量数据为实时统计，历史数据为每日汇总记录。点击日期可查看节点使用详情。',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: <Widget>[
                                  Text(
                                    '我没有使用某些节点，为什么这些节点也会消耗流量？',
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                  TextButton(
                                    style: AppTheme.inlineTextLink(scheme),
                                    onPressed: _showTrafficInfo,
                                    child: const Text('查看说明'),
                                  ),
                                ],
                              ),
                              Wrap(
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: <Widget>[
                                  Text(
                                    '流量不够用？前往 ',
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                  TextButton(
                                    style: AppTheme.inlineTextLink(scheme),
                                    onPressed: () {
                                      Navigator.of(context).popUntil(
                                        (Route<dynamic> route) => route.isFirst,
                                      );
                                      ShellNavigator.openShopTraffic(context);
                                    },
                                    child: const Text('商店'),
                                  ),
                                  Text(
                                    ' 选购流量包',
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        _TrafficDayTable(
                          bundle: bundle,
                          days: days,
                          expandedDay: expandedDay,
                          keepDays: keepDays,
                          onToggleDay: _toggleDay,
                          daySortCol: _daySortCol,
                          daySortAsc: _daySortAsc,
                          onDaySort: _onDaySort,
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _TrafficDayTable extends StatefulWidget {
  const _TrafficDayTable({
    required this.bundle,
    required this.days,
    required this.expandedDay,
    required this.keepDays,
    required this.onToggleDay,
    required this.daySortCol,
    required this.daySortAsc,
    required this.onDaySort,
  });

  final TrafficLogBundle bundle;
  final List<String> days;
  final String? expandedDay;
  final int keepDays;
  final ValueChanged<String> onToggleDay;
  final _TrafficSortCol? daySortCol;
  final bool daySortAsc;
  final ValueChanged<_TrafficSortCol> onDaySort;

  @override
  State<_TrafficDayTable> createState() => _TrafficDayTableState();
}

class _TrafficDayTableState extends State<_TrafficDayTable> {
  static const List<(_TrafficSortCol, String)> _dayHeaders =
      <(_TrafficSortCol, String)>[
        (_TrafficSortCol.date, '日期'),
        (_TrafficSortCol.upload, '实际上传流量'),
        (_TrafficSortCol.download, '实际下载流量'),
        (_TrafficSortCol.rate, '倍率'),
        (_TrafficSortCol.usage, '结算流量'),
      ];
  static const List<(_TrafficSortCol, String)> _nodeHeaders =
      <(_TrafficSortCol, String)>[
        (_TrafficSortCol.nodeName, '节点名称'),
        (_TrafficSortCol.upload, '实际上传流量'),
        (_TrafficSortCol.download, '实际下载流量'),
        (_TrafficSortCol.rate, '倍率'),
        (_TrafficSortCol.usage, '结算流量'),
      ];
  static const double _minWidth = 800;
  static const EdgeInsets _pad = EdgeInsets.symmetric(
    horizontal: 16,
    vertical: 12,
  );

  _TrafficSortCol? _nodeSortCol;
  bool _nodeSortAsc = true;

  void _onNodeSort(_TrafficSortCol col) {
    setState(() {
      if (_nodeSortCol == col) {
        _nodeSortAsc = !_nodeSortAsc;
      } else {
        _nodeSortCol = col;
        _nodeSortAsc = true;
      }
    });
  }

  List<TrafficNodeItem> _sortedNodes(String day) {
    final List<TrafficNodeItem> nodes = List<TrafficNodeItem>.of(
      widget.bundle.nodeTraffic[day] ?? const <TrafficNodeItem>[],
    );
    final _TrafficSortCol? col = _nodeSortCol;
    if (col == null) {
      return nodes;
    }
    final _TrafficSortType type = _sortTypeOf(col);
    nodes.sort((TrafficNodeItem a, TrafficNodeItem b) {
      final Object va = _nodeSortValue(a, col);
      final Object vb = _nodeSortValue(b, col);
      return _compareSortKeys(va, vb, type, _nodeSortAsc);
    });
    return nodes;
  }

  Object _nodeSortValue(TrafficNodeItem node, _TrafficSortCol col) {
    switch (col) {
      case _TrafficSortCol.nodeName:
        return _sortKey(node.nodeName, _TrafficSortType.string);
      case _TrafficSortCol.upload:
        return node.dailyUpload.toDouble();
      case _TrafficSortCol.download:
        return node.dailyDownload.toDouble();
      case _TrafficSortCol.rate:
        return node.nodeTrafficRate;
      case _TrafficSortCol.usage:
        return node.dailyUsage.toDouble();
      case _TrafficSortCol.date:
        return '';
    }
  }

  Widget _sortLabel({
    required ThemeData theme,
    required ColorScheme scheme,
    required String title,
    required _TrafficSortCol col,
    required _TrafficSortCol? activeCol,
    required bool asc,
    required VoidCallback onTap,
  }) {
    final bool active = activeCol == col;
    final Color base = scheme.onSurfaceVariant;
    TextStyle arrowStyle(bool highlight) => theme.textTheme.labelSmall!
        .copyWith(
          color: base.withValues(alpha: highlight ? 1 : (active ? 0.45 : 0.65)),
          fontWeight: FontWeight.w600,
          height: 1,
        );
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              title,
              style: theme.textTheme.labelMedium!.copyWith(
                color: base,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 4),
            Text('↑', style: arrowStyle(active && asc)),
            Text('↓', style: arrowStyle(active && !asc)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final BorderSide line = BorderSide(
      color: scheme.outlineVariant,
      width: 0.5,
    );
    final TrafficLogBundle bundle = widget.bundle;
    final List<String> days = widget.days;
    final String? expandedDay = widget.expandedDay;
    final int keepDays = widget.keepDays;

    if (days.isEmpty) {
      return Card(
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Center(
            child: Text(
              '您最近 $keepDays 天内还没有流量使用记录',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < _minWidth) {
          return _mobileList(
            context: context,
            theme: theme,
            scheme: scheme,
            bundle: bundle,
            days: days,
            expandedDay: expandedDay,
          );
        }

        final double tableWidth = constraints.maxWidth;
        final double colW = tableWidth / _dayHeaders.length;
        final Map<int, TableColumnWidth> widths = <int, TableColumnWidth>{
          for (int i = 0; i < _dayHeaders.length; i++)
            i: FixedColumnWidth(colW),
        };

        TableRow cells(List<Widget> children, {Decoration? decoration}) {
          return TableRow(
            decoration: decoration,
            children: <Widget>[
              for (final Widget child in children)
                Padding(padding: _pad, child: child),
            ],
          );
        }

        Widget segment(List<TableRow> rows, {bool topBorder = false}) {
          return Table(
            columnWidths: widths,
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            border: topBorder ? TableBorder(top: line) : null,
            children: rows,
          );
        }

        return Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              segment(<TableRow>[
                cells(
                  <Widget>[
                    for (final (_TrafficSortCol, String) h in _dayHeaders)
                      _sortLabel(
                        theme: theme,
                        scheme: scheme,
                        title: h.$2,
                        col: h.$1,
                        activeCol: widget.daySortCol,
                        asc: widget.daySortAsc,
                        onTap: () => widget.onDaySort(h.$1),
                      ),
                  ],
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(
                      alpha: 0.45,
                    ),
                  ),
                ),
              ]),
              for (final String day in days) ...<Widget>[
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => widget.onToggleDay(day),
                    child: segment(<TableRow>[
                      cells(
                        <Widget>[
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Icon(
                                  expandedDay == day
                                      ? Icons.expand_more
                                      : Icons.chevron_right,
                                  size: 18,
                                ),
                                Text(day, style: theme.textTheme.bodySmall),
                              ],
                            ),
                          ),
                          TableText(bundle.traffic[day]?.totalUpload ?? '0B'),
                          TableText(
                            bundle.traffic[day]?.totalDownload ?? '0B',
                          ),
                          TableText(bundle.traffic[day]?.rateInfo ?? '无'),
                          TableText(
                            bundle.traffic[day]?.totalUsage ?? '0B',
                            bold: true,
                          ),
                        ],
                        decoration: expandedDay == day
                            ? _expandedRowDecoration(scheme)
                            : null,
                      ),
                    ], topBorder: true),
                  ),
                ),
                if (expandedDay == day)
                  _nodeDetail(
                    context: context,
                    day: day,
                    cells: cells,
                    segment: segment,
                  ),
              ],
              segment(<TableRow>[
                cells(<Widget>[
                  const TableText('累计使用流量', bold: true),
                  TableText(bundle.totalUpload, bold: true),
                  TableText(bundle.totalDownload, bold: true),
                  TableText(bundle.totalRateInfo, bold: true),
                  TableText(bundle.totalUsage, bold: true),
                ]),
              ], topBorder: true),
            ],
          ),
        );
      },
    );
  }

  // 色值须与 Website trafficlog.tpl / dark-theme.css 的 .traffic-row.selected 一致
  BoxDecoration _expandedRowDecoration(ColorScheme scheme) {
    final bool dark = scheme.brightness == Brightness.dark;
    return BoxDecoration(
      color: dark ? const Color(0x8C1E3A5F) : const Color(0xFFEAF3FF),
      border: Border(
        left: BorderSide(
          color: dark ? const Color(0xFF64B5F6) : const Color(0xFF1976D2),
          width: 3,
        ),
      ),
    );
  }

  Widget _kv(
    ThemeData theme,
    ColorScheme scheme,
    String label,
    Widget value,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: value),
        ],
      ),
    );
  }

  Widget _mobileList({
    required BuildContext context,
    required ThemeData theme,
    required ColorScheme scheme,
    required TrafficLogBundle bundle,
    required List<String> days,
    required String? expandedDay,
  }) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < days.length; i++) ...<Widget>[
            if (i > 0) Divider(height: 1, color: scheme.outlineVariant),
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => widget.onToggleDay(days[i]),
                child: DecoratedBox(
                  decoration: expandedDay == days[i]
                      ? _expandedRowDecoration(scheme)
                      : const BoxDecoration(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _kv(
                          theme,
                          scheme,
                          '日期',
                          Row(
                            children: <Widget>[
                              Icon(
                                expandedDay == days[i]
                                    ? Icons.expand_more
                                    : Icons.chevron_right,
                                size: 18,
                              ),
                              Expanded(
                                child: TableText(days[i], bold: true),
                              ),
                            ],
                          ),
                        ),
                        _kv(
                          theme,
                          scheme,
                          '实际上传流量',
                          TableText(
                            bundle.traffic[days[i]]?.totalUpload ?? '0B',
                          ),
                        ),
                        _kv(
                          theme,
                          scheme,
                          '实际下载流量',
                          TableText(
                            bundle.traffic[days[i]]?.totalDownload ?? '0B',
                          ),
                        ),
                        _kv(
                          theme,
                          scheme,
                          '倍率',
                          TableText(
                            bundle.traffic[days[i]]?.rateInfo ?? '无',
                          ),
                        ),
                        _kv(
                          theme,
                          scheme,
                          '结算流量',
                          TableText(
                            bundle.traffic[days[i]]?.totalUsage ?? '0B',
                            bold: true,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (expandedDay == days[i])
              _mobileNodeDetail(
                context: context,
                theme: theme,
                scheme: scheme,
                day: days[i],
              ),
          ],
          Divider(height: 1, color: scheme.outlineVariant),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _kv(
                  theme,
                  scheme,
                  '日期',
                  const TableText('累计使用流量', bold: true),
                ),
                _kv(
                  theme,
                  scheme,
                  '实际上传流量',
                  TableText(bundle.totalUpload, bold: true),
                ),
                _kv(
                  theme,
                  scheme,
                  '实际下载流量',
                  TableText(bundle.totalDownload, bold: true),
                ),
                _kv(
                  theme,
                  scheme,
                  '倍率',
                  TableText(bundle.totalRateInfo, bold: true),
                ),
                _kv(
                  theme,
                  scheme,
                  '结算流量',
                  TableText(bundle.totalUsage, bold: true),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _mobileNodeDetail({
    required BuildContext context,
    required ThemeData theme,
    required ColorScheme scheme,
    required String day,
  }) {
    final List<TrafficNodeItem> nodes =
        widget.bundle.nodeTraffic[day] ?? const <TrafficNodeItem>[];
    return ColoredBox(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.28),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (nodes.isEmpty)
              Text(
                '该日期没有节点使用数据',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              for (int i = 0; i < nodes.length; i++) ...<Widget>[
                if (i > 0) Divider(height: 1, color: scheme.outlineVariant),
                _kv(
                  theme,
                  scheme,
                  '节点名称',
                  TableText(nodes[i].nodeName, bold: true),
                ),
                _kv(
                  theme,
                  scheme,
                  '实际上传流量',
                  TableText(Format.bytes(nodes[i].dailyUpload)),
                ),
                _kv(
                  theme,
                  scheme,
                  '实际下载流量',
                  TableText(Format.bytes(nodes[i].dailyDownload)),
                ),
                _kv(theme, scheme, '倍率', TableText(nodes[i].nodeRateStr)),
                _kv(
                  theme,
                  scheme,
                  '结算流量',
                  TableText(Format.bytes(nodes[i].dailyUsage), bold: true),
                ),
              ],
          ],
        ),
      ),
    );
  }

  Widget _nodeDetail({
    required BuildContext context,
    required String day,
    required TableRow Function(List<Widget> children, {Decoration? decoration})
        cells,
    required Widget Function(List<TableRow> rows, {bool topBorder}) segment,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<TrafficNodeItem> nodes = _sortedNodes(day);

    return ColoredBox(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.28),
      child: segment(
        <TableRow>[
          cells(
            <Widget>[
              for (final (_TrafficSortCol, String) h in _nodeHeaders)
                _sortLabel(
                  theme: theme,
                  scheme: scheme,
                  title: h.$2,
                  col: h.$1,
                  activeCol: _nodeSortCol,
                  asc: _nodeSortAsc,
                  onTap: () => _onNodeSort(h.$1),
                ),
            ],
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
            ),
          ),
          if (nodes.isEmpty)
            cells(<Widget>[
              Text(
                '该日期没有节点使用数据',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox.shrink(),
              const SizedBox.shrink(),
              const SizedBox.shrink(),
              const SizedBox.shrink(),
            ])
          else
            for (final TrafficNodeItem node in nodes)
              cells(<Widget>[
                TableText(node.nodeName, bold: true),
                TableText(Format.bytes(node.dailyUpload)),
                TableText(Format.bytes(node.dailyDownload)),
                TableText(node.nodeRateStr),
                TableText(Format.bytes(node.dailyUsage), bold: true),
              ]),
        ],
        topBorder: true,
      ),
    );
  }
}
