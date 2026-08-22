import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/api/api_exception.dart';
import '../../data/api/panel_api_client.dart';
import '../../data/models/account.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/list_toolbar.dart';
import '../widgets/page_header.dart';
import '../widgets/refresh_button.dart';
import '../widgets/section_card.dart';
import '../widgets/simple_data_table.dart';
import '../../l10n/l10n.dart';

class UnlockPage extends StatefulWidget {
  const UnlockPage({super.key});

  @override
  State<UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends State<UnlockPage> {
  final List<UnlockResult> _results = <UnlockResult>[];
  int _page = 1;
  int _lastPage = 1;
  int _total = 0;
  int _perPage = 10;
  int _unlockCheckInterval = 0;
  String _search = '';
  String? _error;
  bool _busy = false;
  bool _started = false;
  Timer? _searchDebounce;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final PanelApiClient? api = AppScope.of(context).auth.api;
    if (api == null || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final UnlockListPage result = await api.fetchUnlockResults(
        page: _page,
        length: _perPage,
        search: _search,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _results
          ..clear()
          ..addAll(result.results);
        _page = result.currentPage;
        _lastPage = result.lastPage;
        _total = result.total;
        _perPage = result.perPage > 0 ? result.perPage : _perPage;
        _unlockCheckInterval = result.unlockCheckInterval;
        _busy = false;
      });
    } on Object catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = e is ApiException
            ? e.message
            : L10n.t('加载失败：{0}', <Object>[e]);
        _busy = false;
      });
    }
  }

  void _onSearch(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      _search = value.trim();
      _page = 1;
      unawaited(_load());
    });
  }

  Color? _statusColor(String status) {
    final String lower = status.toLowerCase();
    if (status.startsWith('Yes') ||
        status.contains('解锁') ||
        lower.contains('yes') ||
        lower.contains('unlock')) {
      return AppTheme.success;
    }
    if (status.startsWith('Unknow') || lower.startsWith('unknow')) {
      return AppTheme.warning;
    }
    if (status.startsWith('No') ||
        status.contains('失败') ||
        status.contains('屏蔽') ||
        lower.startsWith('no')) {
      return AppTheme.danger;
    }
    if (status.startsWith('仅限自制') ||
        status.startsWith('仅限网页') ||
        status.startsWith('仅限App')) {
      return const Color(0xFF9C27B0);
    }
    return null;
  }

  Widget _statusText(UnlockResult item, String key) {
    final String value = item.unlockItem[key] ?? '';
    return TableText(value, color: _statusColor(value));
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Column(
      children: <Widget>[
        PageHeader(
          title: L10n.t('解锁检测'),
          showUserAvatar: true,
          actions: <Widget>[
            RefreshButton(tooltip: L10n.t('刷新'), onRefresh: _load),
          ],
        ),
        ListToolbar(
          currentPage: _page,
          lastPage: _lastPage,
          total: _total,
          perPage: _perPage,
          searchHint: L10n.t('搜索节点'),
          onSearchChanged: _onSearch,
          onPerPageChanged: (int value) {
            _perPage = value;
            _page = 1;
            unawaited(_load());
          },
          onPageChanged: (int page) {
            _page = page;
            unawaited(_load());
          },
        ),
        Expanded(
          child: _busy && _results.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _error != null && _results.isEmpty
              ? Center(child: Text(_error!))
              : RefreshIndicator(
                  onRefresh: _load,
                  notificationPredicate: (ScrollNotification n) =>
                      n.metrics.axis == Axis.vertical,
                  child: NestedScrollView(
                    headerSliverBuilder: (BuildContext context, bool _) {
                      return <Widget>[
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: AppTheme.pageScrollPadding.copyWith(
                              bottom: 0,
                            ),
                            child: SectionCard(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    L10n.t(
                                      '您可以在这里查看节点的流媒体和各大AI平台解锁情况。',
                                    ),
                                  ),
                                  if (_unlockCheckInterval > 0) ...<Widget>[
                                    const SizedBox(height: 8),
                                    Text(
                                      L10n.t(
                                        '每 {0} 小时更新一次，测试结果仅供参考，请以实际使用情况为准。',
                                        <Object>[_unlockCheckInterval],
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 8),
                                  Text(
                                    L10n.t(
                                      '(YouTube Premium 检测结果如果显示：No，可能无法正常使用Google服务，如需使用Google Play、YouTube Music等请切换到其他节点)',
                                    ),
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SliverToBoxAdapter(child: SizedBox(height: 12)),
                      ];
                    },
                    body: Padding(
                      padding: AppTheme.pageScrollPadding.copyWith(top: 0),
                      child: SimpleDataTable(
                        stickyHeader: true,
                        minWidth: 1280,
                        columnWidths: const <int, TableColumnWidth>{
                          0: IntrinsicColumnWidth(),
                        },
                        columns: <String>[
                          L10n.t('节点'),
                          L10n.t('YouTube Premium'),
                          L10n.t('Netflix'),
                          L10n.t('Prime Video'),
                          L10n.t('Disney Plus'),
                          L10n.t('TikTok'),
                          L10n.t('HBO Max'),
                          L10n.t('OpenAI'),
                          L10n.t('Gemini'),
                          L10n.t('Claude'),
                          L10n.t('更新时间'),
                        ],
                        emptyText: _search.isEmpty
                            ? L10n.t('暂无解锁检测结果')
                            : L10n.t('没有匹配结果'),
                        rows: <List<Widget>>[
                          for (final UnlockResult item in _results)
                            <Widget>[
                              TableText(
                                item.nodeName,
                                bold: true,
                                maxLines: 1,
                              ),
                              _statusText(item, 'YouTube_Premium'),
                              _statusText(item, 'Netflix'),
                              _statusText(item, 'AmazonPrime'),
                              _statusText(item, 'DisneyPlus'),
                              _statusText(item, 'TikTok'),
                              _statusText(item, 'HBOMax'),
                              _statusText(item, 'OpenAI'),
                              _statusText(item, 'Gemini'),
                              _statusText(item, 'Claude'),
                              TableText(item.createdAt, muted: true),
                            ],
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
