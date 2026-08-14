import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/api/api_exception.dart';
import '../../data/api/panel_api_client.dart';
import '../../data/models/account.dart';
import '../app_scope.dart';
import '../widgets/list_toolbar.dart';
import '../widgets/page_header.dart';
import '../widgets/refresh_button.dart';
import '../widgets/simple_data_table.dart';

class UsageIpsPage extends StatefulWidget {
  const UsageIpsPage({super.key});

  @override
  State<UsageIpsPage> createState() => _UsageIpsPageState();
}

class _UsageIpsPageState extends State<UsageIpsPage> {
  final List<UsageIpItem> _items = <UsageIpItem>[];
  int _page = 1;
  int _lastPage = 1;
  int _total = 0;
  int _perPage = 10;
  int _logKeepDays = 1;
  String? _error;
  bool _busy = false;
  bool _started = false;

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
    if (api == null || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final UsageIpListPage result = await api.fetchUsageIps(
        page: _page,
        length: _perPage,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _items
          ..clear()
          ..addAll(result.items);
        _page = result.currentPage;
        _lastPage = result.lastPage;
        _total = result.total;
        _perPage = result.perPage > 0 ? result.perPage : _perPage;
        _logKeepDays = result.logKeepDays > 0 ? result.logKeepDays : 1;
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

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      body: Column(
        children: <Widget>[
          SafeArea(
            bottom: false,
            child: PageHeader(
              title: '最近 $_logKeepDays 天的使用IP',
              showBackButton: true,
              showUserAvatar: true,
              actions: <Widget>[
                RefreshButton(tooltip: '刷新', onRefresh: _load),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '请确认均为本人 IP，异常请及时重置订阅与节点密码。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          ListToolbar(
            currentPage: _page,
            lastPage: _lastPage,
            total: _total,
            perPage: _perPage,
            showSearch: false,
            onSearchChanged: (_) {},
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
            child: _busy && _items.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _error != null && _items.isEmpty
                ? Center(child: Text(_error!))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.all(14),
                      children: <Widget>[
                        SimpleDataTable(
                          columns: const <String>['IP', '归属地', '最后使用时间'],
                          emptyText: '最近 $_logKeepDays 天没有使用记录',
                          rows: <List<Widget>>[
                            for (final UsageIpItem item in _items)
                              <Widget>[
                                TableText(item.ip),
                                TableText(item.location),
                                TableText(item.datetime, muted: true),
                              ],
                          ],
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
