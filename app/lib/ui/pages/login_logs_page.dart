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
import '../widgets/simple_data_table.dart';
import '../../l10n/l10n.dart';

class LoginLogsPage extends StatefulWidget {
  const LoginLogsPage({super.key});

  @override
  State<LoginLogsPage> createState() => _LoginLogsPageState();
}

class _LoginLogsPageState extends State<LoginLogsPage> {
  final List<LoginLogItem> _items = <LoginLogItem>[];
  int _page = 1;
  int _lastPage = 1;
  int _total = 0;
  int _perPage = 10;
  int _logKeepDays = 30;
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
      final LoginLogListPage result = await api.fetchLoginLogs(
        page: _page,
        length: _perPage,
        search: _search,
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
        _logKeepDays = result.logKeepDays > 0 ? result.logKeepDays : 30;
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

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      body: Column(
        children: <Widget>[
          SafeArea(
            bottom: false,
            child: PageHeader(
              title: L10n.t('登录记录'),
              showBackButton: true,
              showUserAvatar: true,
              actions: <Widget>[
                RefreshButton(tooltip: L10n.t('刷新'), onRefresh: _load),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                L10n.t('最近 {0} 天网站登录记录，请确认均为本人 IP，异常请及时修改登录密码。', <Object>[
                  _logKeepDays,
                ]),
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
            searchHint: L10n.t('IP / 归属地 / 设备'),
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
            child: _busy && _items.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _error != null && _items.isEmpty
                ? Center(child: Text(_error!))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: AppTheme.pageScrollPadding,
                      children: <Widget>[
                        SimpleDataTable(
                          columns: <String>[
                            L10n.t('登录IP'),
                            L10n.t('归属地'),
                            L10n.t('设备'),
                            L10n.t('状态'),
                            L10n.t('登录方式'),
                            L10n.t('登录时间'),
                          ],
                          emptyText: L10n.t('最近 {0} 天内还没有登录记录', <Object>[
                            _logKeepDays,
                          ]),
                          rows: <List<Widget>>[
                            for (final LoginLogItem item in _items)
                              <Widget>[
                                TableText(item.ip),
                                TableText(item.location),
                                TableText(item.device),
                                TableText(item.type),
                                TableText(item.method),
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
