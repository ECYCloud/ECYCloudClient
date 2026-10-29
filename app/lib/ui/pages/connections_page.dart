import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/logger.dart';
import '../../state/connection_controller.dart';
import '../app_scope.dart';
import '../format.dart';
import '../node_labels.dart';
import '../theme.dart';
import '../widgets/app_alert_dialog.dart';
import '../widgets/gapped_sliver_list.dart';
import '../widgets/page_header.dart';
import '../widgets/search_field.dart';
import '../widgets/tag_chip.dart';
import '../../l10n/l10n.dart';

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
      builder: (BuildContext context, _) => CustomScrollView(
        slivers: <Widget>[
          PinnedHeaderSliver(
            child: ColoredBox(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: PageHeader(title: L10n.t('连接'), showUserAvatar: false),
            ),
          ),
          if (connection.state != ConnectionPhase.connected)
            SliverFillRemaining(
              child: Center(child: Text(L10n.t('连接后可查看连接明细'))),
            )
          else
            ..._bodySlivers(connection),
        ],
      ),
    );
  }

  List<Widget> _bodySlivers(ConnectionController connection) {
    final List<_Row> active = _matching(connection.connections, active: true);
    final List<_Row> closed = _matching(
      connection.closedConnections,
      active: false,
    );
    final List<_Row> rows = switch (_scope) {
      _Scope.all => <_Row>[...active, ...closed],
      _Scope.active => active,
      _Scope.closed => closed,
    };
    final int activeCount = active.length;
    final int closedCount = closed.length;

    final SegmentedButton<_Scope> scopeFilter = SegmentedButton<_Scope>(
      segments: <ButtonSegment<_Scope>>[
        ButtonSegment<_Scope>(
          value: _Scope.all,
          label: Text(L10n.t('全部 {0}', <Object>[activeCount + closedCount])),
        ),
        ButtonSegment<_Scope>(
          value: _Scope.active,
          label: Text(L10n.t('活跃中 {0}', <Object>[activeCount])),
        ),
        ButtonSegment<_Scope>(
          value: _Scope.closed,
          label: Text(L10n.t('已关闭 {0}', <Object>[closedCount])),
        ),
      ],
      selected: <_Scope>{_scope},
      onSelectionChanged: (Set<_Scope> value) =>
          setState(() => _scope = value.first),
      showSelectedIcon: false,
    );

    final Widget searchActions = SearchField(
      hintText: L10n.t('搜索域名、IP、进程、规则'),
      width: double.infinity,
      onChanged: (String value) =>
          setState(() => _keyword = value.trim().toLowerCase()),
    );

    return <Widget>[
      PinnedHeaderSliver(
        child: ColoredBox(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool narrow = constraints.maxWidth < 640;
              if (narrow) {
                return Padding(
                  padding: AppTheme.pageScrollPadding.copyWith(
                    top: 10,
                    bottom: 10,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      scopeFilter,
                      const SizedBox(height: 8),
                      searchActions,
                    ],
                  ),
                );
              }
              return Padding(
                padding: AppTheme.pageScrollPadding.copyWith(
                  top: 10,
                  bottom: 10,
                ),
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
        ),
      ),
      if (rows.isEmpty)
        SliverFillRemaining(child: Center(child: Text(L10n.t('没有符合条件的连接'))))
      else
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            14,
            2,
            AppTheme.overlayScrollGutter,
            2,
          ),
          sliver: GappedSliverList(
            itemCount: rows.length,
            gap: 2,
            // 地址行与标签行两行文字，加卡片内外边距
            rowEstimate:
                32 +
                2 *
                    MediaQuery.textScalerOf(
                      context,
                    ).scale(Theme.of(context).textTheme.bodyMedium!.fontSize!),
            itemBuilder: (BuildContext context, int index) => _ConnectionRow(
              row: rows[index],
              onTap: () => showDialog<void>(
                context: context,
                builder: (BuildContext context) => _ConnectionDetailDialog(
                  connection: connection,
                  row: rows[index],
                ),
              ),
            ),
          ),
        ),
    ];
  }

  // 轮询每秒整体重建，连接条目在快照或关闭时整份替换，按条目缓存解析结果与搜索串
  static final Expando<_Row> _rowCache = Expando<_Row>();

  List<_Row> _matching(
    List<Map<String, dynamic>> items, {
    required bool active,
  }) {
    final List<_Row> rows = <_Row>[
      for (final Map<String, dynamic> item in items)
        _rowCache[item] ??= _Row(item, active: active),
    ];
    if (_keyword.isEmpty) {
      return rows;
    }
    return rows
        .where((_Row row) => row.haystack.contains(_keyword))
        .toList(growable: false);
  }
}

class _Row {
  _Row(this.item, {required this.active})
    : id = '${item['id']}',
      source = ConnectionController.connectionSource(item),
      meta = item['metadata'] is Map<String, dynamic>
          ? item['metadata'] as Map<String, dynamic>
          : const <String, dynamic>{},
      upload = (item['upload'] as num?)?.toInt() ?? 0,
      download = (item['download'] as num?)?.toInt() ?? 0,
      rule = _text(item['rule']),
      rulePayload = _text(item['rulePayload']),
      chains = item['chains'] is List
          ? (item['chains'] as List).whereType<String>().toList(growable: false)
          : const <String>[],
      startedAt = DateTime.tryParse(_text(item['start'])),
      closedAt = DateTime.tryParse(_text(item['closedAt']));

  final Map<String, dynamic> item;
  final String id;
  final String source;
  final bool active;
  final Map<String, dynamic> meta;
  final int upload;
  final int download;
  final String rule;
  final String rulePayload;
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
    final String address = host.isNotEmpty ? host : (ip.isEmpty ? '—' : ip);
    return port.isEmpty ? address : '$address:$port';
  }

  String get process {
    final String name = _text(meta['process']);
    if (name.isNotEmpty) {
      return name;
    }
    final String path = _text(meta['processPath']);
    if (path.isEmpty) {
      return '';
    }
    final int slash = path.lastIndexOf(RegExp(r'[\\/]'));
    return slash < 0 ? path : path.substring(slash + 1);
  }

  String get outbound => chains.isEmpty ? '' : chains.first;

  String get chainLabel =>
      chains.reversed.map(NodeLabels.displayName).join(' → ');

  String get lifetime {
    final DateTime? start = startedAt;
    if (start == null) {
      return '';
    }
    return Format.duration((closedAt ?? DateTime.now()).difference(start));
  }

  late final String haystack = <String>[
    target,
    _text(meta['destinationIP']),
    process,
    rule,
    network,
    inbound,
    ...chains.map(NodeLabels.displayName),
  ].join(' ').toLowerCase();

  static String _text(Object? value) => value is String ? value.trim() : '';
}

class _ConnectionRow extends StatelessWidget {
  const _ConnectionRow({required this.row, required this.onTap});

  final _Row row;
  final VoidCallback onTap;

  static const double _markerWidth = 12;
  static const double _markerGap = 8;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color faded = theme.colorScheme.onSurfaceVariant;

    return Opacity(
      opacity: row.active ? 1 : 0.65,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Material(
          color: theme.colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            mouseCursor: SystemMouseCursors.click,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
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
                              if (row.inbound.isNotEmpty)
                                TagChip(label: row.inbound),
                              if (row.network.isNotEmpty)
                                TagChip(label: row.network),
                              if (row.outbound.isNotEmpty)
                                TagChip(
                                  icon: Icons.call_made,
                                  label: row.chainLabel,
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
                        row.active
                            ? row.lifetime
                            : L10n.t('已关闭 · {0}', <Object>[row.lifetime]),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: faded,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectionDetailDialog extends StatefulWidget {
  const _ConnectionDetailDialog({required this.connection, required this.row});

  final ConnectionController connection;
  final _Row row;

  @override
  State<_ConnectionDetailDialog> createState() =>
      _ConnectionDetailDialogState();
}

class _ConnectionDetailDialogState extends State<_ConnectionDetailDialog> {
  late _Row _row = widget.row;
  List<Map<String, dynamic>>? _snapshot;
  DateTime? _sampledAt;
  int _uploadSpeed = 0;
  int _downloadSpeed = 0;
  bool _closing = false;
  String? _closeError;

  @override
  void initState() {
    super.initState();
    widget.connection.addListener(_onUpdate);
  }

  @override
  void dispose() {
    widget.connection.removeListener(_onUpdate);
    super.dispose();
  }

  // 速率按相邻两次连接快照的计数差分；快照列表只在轮询落地时整体替换
  void _onUpdate() {
    final List<Map<String, dynamic>> snapshot = widget.connection.connections;
    if (!mounted || identical(snapshot, _snapshot) || !_row.active) {
      return;
    }
    final DateTime now = DateTime.now();
    final DateTime? last = _sampledAt;
    _snapshot = snapshot;
    _sampledAt = now;
    final Map<String, dynamic>? live = _find(snapshot);
    if (live == null) {
      final Map<String, dynamic>? closed = _find(
        widget.connection.closedConnections,
      );
      setState(() {
        _row = _Row(closed ?? _row.item, active: false);
        _uploadSpeed = 0;
        _downloadSpeed = 0;
      });
      return;
    }
    final _Row next = _Row(live, active: true);
    final double seconds = last == null
        ? 0
        : now.difference(last).inMilliseconds / 1000;
    setState(() {
      if (seconds > 0) {
        _uploadSpeed = (max(0, next.upload - _row.upload) / seconds).round();
        _downloadSpeed = (max(0, next.download - _row.download) / seconds)
            .round();
      }
      _row = next;
    });
  }

  Map<String, dynamic>? _find(List<Map<String, dynamic>> items) {
    for (final Map<String, dynamic> item in items) {
      if ('${item['id']}' == _row.id) {
        return item;
      }
    }
    return null;
  }

  Future<void> _close() async {
    setState(() {
      _closing = true;
      _closeError = null;
    });
    try {
      await widget.connection.clash?.closeConnection(_row.id);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on Object catch (e) {
      Logger.instance.warn('connections', '关闭连接失败: $e');
      if (mounted) {
        setState(() {
          _closing = false;
          _closeError = L10n.t('关闭连接失败：{0}', <Object>['$e']);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final _Row row = _row;
    final DateTime? start = row.startedAt?.toLocal();
    final String processPath = _Row._text(row.meta['processPath']);
    final String remote = _Row._text(row.meta['remoteDestination']);
    final String network = _Row._text(row.meta['network']);
    final List<(String, String)> fields = <(String, String)>[
      (L10n.t('主机'), row.target),
      (L10n.t('下载量'), Format.bytes(row.download)),
      (L10n.t('上传量'), Format.bytes(row.upload)),
      (L10n.t('下载速度'), Format.speed(_downloadSpeed)),
      (L10n.t('上传速度'), Format.speed(_uploadSpeed)),
      (L10n.t('链路'), row.chainLabel),
      (
        L10n.t('规则'),
        row.rulePayload.isEmpty ? row.rule : '${row.rule}(${row.rulePayload})',
      ),
      (
        L10n.t('进程'),
        processPath.isEmpty || processPath == row.process
            ? row.process
            : '${row.process} ($processPath)',
      ),
      (
        L10n.t('连接时间'),
        start == null ? '' : '${Format.date(start)} ${Format.clock(start)}',
      ),
      (L10n.t('源地址'), row.source),
      (
        L10n.t('目标地址'),
        remote.isNotEmpty ? remote : _Row._text(row.meta['destinationIP']),
      ),
      (L10n.t('目标端口'), _Row._text(row.meta['destinationPort'])),
      (
        L10n.t('类型'),
        network.isEmpty ? row.inbound : '${row.inbound}($network)',
      ),
    ];

    return AppAlertDialog(
      title: Text(L10n.t('连接详情')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 6,
        children: <Widget>[
          for (final (String label, String value) in fields)
            Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(
                    text: '$label: ',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  TextSpan(text: value.isEmpty ? '—' : value),
                ],
              ),
              textAlign: TextAlign.start,
            ),
          if (_closeError != null)
            Text(
              _closeError!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
        ],
      ),
      actions: <Widget>[
        if (row.active)
          FilledButton(
            onPressed: _closing ? null : _close,
            child: Text(L10n.t('关闭连接')),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(L10n.t('关闭')),
        ),
      ],
    );
  }
}
