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
      final LoginLogListPage result = await api.fetchLoginLogs(
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
        _logKeepDays = result.logKeepDays > 0 ? result.logKeepDays : 30;
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
              title: '登录记录',
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
                '最近 $_logKeepDays 天网站登录记录，请确认均为本人 IP，异常请及时修改登录密码。',
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
                          columns: const <String>[
                            '登录IP',
                            '归属地',
                            '设备',
                            '状态',
                            '登录方式',
                            '登录时间',
                          ],
                          emptyText: '最近 $_logKeepDays 天内还没有登录记录',
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
