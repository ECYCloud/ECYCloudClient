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
import '../widgets/tag_chip.dart';

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
        _error = e is ApiException ? e.message : '加载失败：$e';
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
    if (status.contains('解锁') ||
        lower.contains('yes') ||
        lower.contains('unlock')) {
      return AppTheme.success;
    }
    if (status.contains('失败') ||
        status.contains('屏蔽') ||
        lower.contains('no')) {
      return AppTheme.danger;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Column(
      children: <Widget>[
        PageHeader(
          title: '解锁检测',
          showUserAvatar: true,
          actions: <Widget>[
            RefreshButton(tooltip: '刷新', onRefresh: _load),
          ],
        ),
        ListToolbar(
          currentPage: _page,
          lastPage: _lastPage,
          total: _total,
          perPage: _perPage,
          searchHint: '搜索节点',
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
                  child: ListView.builder(
                    padding: const EdgeInsets.all(14),
                    itemCount: _results.isEmpty ? 2 : _results.length + 1,
                    itemBuilder: (BuildContext context, int index) {
                      if (index == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: SectionCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                const Text(
                                  '您可以在这里查看节点的流媒体和各大AI平台解锁情况。',
                                ),
                                if (_unlockCheckInterval > 0) ...<Widget>[
                                  const SizedBox(height: 8),
                                  Text(
                                    '每 $_unlockCheckInterval 小时更新一次，测试结果仅供参考，请以实际使用情况为准。',
                                  ),
                                ],
                                const SizedBox(height: 8),
                                Text(
                                  '(YouTube Premium 检测结果如果显示：No，可能无法正常使用Google服务，如需使用Google Play、YouTube Music等请切换到其他节点)',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }
                      if (_results.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.only(top: 80),
                          child: Center(child: Text('暂无解锁检测结果')),
                        );
                      }
                      final UnlockResult item = _results[index - 1];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                item.nodeName,
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(color: scheme.onSurface),
                              ),
                              if (item.createdAt.isNotEmpty) ...<Widget>[
                                const SizedBox(height: 2),
                                Text(
                                  item.createdAt,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: <Widget>[
                                  for (final MapEntry<String, String> entry
                                      in item.unlockItem.entries)
                                    TagChip(
                                      label: '${entry.key}: ${entry.value}',
                                      color: _statusColor(entry.value),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}
