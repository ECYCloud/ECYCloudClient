import 'package:flutter/material.dart';

import '../../state/connection_controller.dart';
import '../app_scope.dart';
import '../format.dart';
import '../node_labels.dart';
import '../theme.dart';
import '../widgets/page_header.dart';
import '../widgets/search_field.dart';
import '../widgets/tag_chip.dart';

enum _Scope { all, active, closed }

class ConnectionsPage extends StatefulWidget {
  const ConnectionsPage({super.key});

  @override
  State<ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends State<ConnectionsPage> {
  _Scope _scope = _Scope.all;
  String _keyword = '';

  @override
  Widget build(BuildContext context) {
    final ConnectionController connection = AppScope.of(context).connection;

    return ListenableBuilder(
      listenable: connection,
      builder: (BuildContext context, _) => Column(
        children: <Widget>[
          const PageHeader(title: '连接'),
          Expanded(
            child: connection.state == ConnectionPhase.connected
                ? _body(connection)
                : const Center(child: Text('连接后可查看连接明细')),
          ),
        ],
      ),
    );
  }

  Widget _body(ConnectionController connection) {
    final List<_Row> rows = _rows(connection);

    final SegmentedButton<_Scope> scopeFilter = SegmentedButton<_Scope>(
      segments: <ButtonSegment<_Scope>>[
        ButtonSegment<_Scope>(
          value: _Scope.all,
          label: Text(
            '全部 ${connection.connections.length + connection.closedConnections.length}',
          ),
        ),
        ButtonSegment<_Scope>(
          value: _Scope.active,
          label: Text('活跃中 ${connection.connections.length}'),
        ),
        ButtonSegment<_Scope>(
          value: _Scope.closed,
          label: Text('已关闭 ${connection.closedConnections.length}'),
        ),
      ],
      selected: <_Scope>{_scope},
      onSelectionChanged: (Set<_Scope> value) =>
          setState(() => _scope = value.first),
      showSelectedIcon: false,
    );

    final Widget searchActions = SearchField(
      hintText: '搜索域名、IP、进程、规则',
      width: double.infinity,
      onChanged: (String value) =>
          setState(() => _keyword = value.trim().toLowerCase()),
    );

    return Column(
      children: <Widget>[
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool narrow = constraints.maxWidth < 640;
            if (narrow) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: scopeFilter,
                    ),
                    const SizedBox(height: 8),
                    searchActions,
                  ],
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              child: Row(
                children: <Widget>[
                  scopeFilter,
                  const SizedBox(width: 10),
                  Expanded(child: searchActions),
                ],
              ),
            );
          },
        ),
        const Divider(height: 1),
        Expanded(
          child: rows.isEmpty
              ? const Center(child: Text('没有符合条件的连接'))
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (BuildContext context, int index) =>
                      _ConnectionRow(row: rows[index]),
                ),
        ),
      ],
    );
  }

  List<_Row> _rows(ConnectionController connection) {
    final List<_Row> rows = <_Row>[
      if (_scope != _Scope.closed)
        for (final Map<String, dynamic> item in connection.connections)
          _Row(item, active: true),
      if (_scope != _Scope.active)
        for (final Map<String, dynamic> item in connection.closedConnections)
          _Row(item, active: false),
    ];

    if (_keyword.isEmpty) {
      return rows;
    }
    return rows
        .where((_Row row) => row.haystack.contains(_keyword))
        .toList(growable: false);
  }
}

/// 一条连接的展示用视图。内核给的键见 trafficontrol/tracker.go 的 MarshalJSON。
class _Row {
  _Row(Map<String, dynamic> item, {required this.active})
    : meta = item['metadata'] is Map<String, dynamic>
          ? item['metadata'] as Map<String, dynamic>
          : const <String, dynamic>{},
      upload = (item['upload'] as num?)?.toInt() ?? 0,
      download = (item['download'] as num?)?.toInt() ?? 0,
      rule = _text(item['rule']),
      chains = item['chains'] is List
          ? (item['chains'] as List).whereType<String>().toList(growable: false)
          : const <String>[],
      startedAt = DateTime.tryParse(_text(item['start'])),
      closedAt = DateTime.tryParse(_text(item['closedAt']));

  final bool active;
  final Map<String, dynamic> meta;
  final int upload;
  final int download;
  final String rule;
  final List<String> chains;
  final DateTime? startedAt;
  final DateTime? closedAt;

  String get network => _text(meta['network']).toUpperCase();

  String get inbound => _text(meta['type']);

  // host 与 destinationIP 都是必有的键，没有值时是空串而不是 null，
  // 用 ?? 兜不住，会把一批连接显示成只有端口的「:443」
  String get target {
    final String host = _text(meta['host']);
    final String ip = _text(meta['destinationIP']);
    final String port = _text(meta['destinationPort']);
    final String address = host.isNotEmpty
        ? (ip.isEmpty ? host : '$host ($ip)')
        : (ip.isEmpty ? '—' : ip);

    return port.isEmpty ? address : '$address:$port';
  }

  String get process {
    final String path = _text(meta['processPath']);
    if (path.isEmpty) {
      return '';
    }
    final int slash = path.lastIndexOf(RegExp(r'[\\/]'));
    return slash < 0 ? path : path.substring(slash + 1);
  }

  String get outbound => chains.isEmpty ? '' : chains.first;

  String get lifetime {
    final DateTime? start = startedAt;
    if (start == null) {
      return '';
    }
    return Format.duration((closedAt ?? DateTime.now()).difference(start));
  }

  late final String haystack = <String>[
    target,
    process,
    rule,
    network,
    inbound,
    ...chains,
  ].join(' ').toLowerCase();

  static String _text(Object? value) => value is String ? value.trim() : '';
}

class _ConnectionRow extends StatelessWidget {
  const _ConnectionRow({required this.row});

  final _Row row;

  // 状态点固定占位：活跃与已关闭两种图标尺寸不同，不定宽会让各行文字左边缘错开
  static const double _markerWidth = 12;
  static const double _markerGap = 8;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color faded = theme.colorScheme.onSurfaceVariant;

    return Opacity(
      opacity: row.active ? 1 : 0.65,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // 状态点与首行同在一个 Row 里居中，才能跟文字对齐；
                  // 放在外层 Row 里只会顶在整块内容的最上沿
                  Row(
                    children: <Widget>[
                      SizedBox(
                        width: _markerWidth,
                        height: _markerWidth,
                        child: Center(
                          child: Icon(
                            row.active
                                ? Icons.circle
                                : Icons.remove_circle_outline,
                            size: row.active ? 8 : 12,
                            color: row.active ? AppTheme.success : faded,
                          ),
                        ),
                      ),
                      const SizedBox(width: _markerGap),
                      Expanded(
                        child: Text(
                          row.target,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Padding(
                    padding: const EdgeInsets.only(
                      left: _markerWidth + _markerGap,
                    ),
                    child: Wrap(
                      spacing: 5,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        if (row.network.isNotEmpty) TagChip(label: row.network),
                        if (row.outbound.isNotEmpty)
                          TagChip(
                            icon: Icons.call_made,
                            label: row.chains.reversed
                                .map(NodeLabels.displayName)
                                .join(' → '),
                            color: theme.colorScheme.primary,
                          ),
                        if (row.process.isNotEmpty)
                          TagChip(icon: Icons.memory, label: row.process),
                        if (row.rule.isNotEmpty)
                          Text(
                            row.rule,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: faded,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  '↑ ${Format.bytes(row.upload)}　↓ ${Format.bytes(row.download)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  row.active ? row.lifetime : '已关闭 · ${row.lifetime}',
                  style: theme.textTheme.bodySmall?.copyWith(color: faded),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
