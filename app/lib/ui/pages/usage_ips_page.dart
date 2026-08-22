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
      final UsageIpListPage result = await api.fetchUsageIps(
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
        _logKeepDays = result.logKeepDays > 0 ? result.logKeepDays : 1;
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

  Future<void> _kick(String ip) async {
    final PanelApiClient? api = AppScope.of(context).auth.api;
    if (api == null) {
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(L10n.t('确认移除该设备？')),
        content: Text(L10n.t('将通知 {0} 上的客户端下线，最长 60 秒后生效。', <Object>[ip])),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L10n.t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L10n.t('确定')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    String message;
    try {
      message = await api.kickDevice(ip);
    } on ApiException catch (e) {
      message = e.message;
    }
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
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
              title: L10n.t('最近 {0} 天的使用IP', <Object>[_logKeepDays]),
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
                L10n.t('请确认均为本人 IP，如有异常请及时修改密码。'),
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
            searchHint: L10n.t('IP / 归属地 / 设备 / 版本'),
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
                          minWidth: 1080,
                          columns: <String>[
                            'IP',
                            L10n.t('归属地'),
                            L10n.t('最后使用时间'),
                            L10n.t('在线设备'),
                            L10n.t('客户端版本'),
                            L10n.t('操作'),
                          ],
                          emptyText: L10n.t('最近 {0} 天没有使用记录', <Object>[
                            _logKeepDays,
                          ]),
                          rows: <List<Widget>>[
                            for (final UsageIpItem item in _items)
                              <Widget>[
                                TableText(item.ip),
                                TableText(item.location),
                                TableText(item.datetime, muted: true),
                                TableText(
                                  item.device.isEmpty
                                      ? L10n.t('第三方客户端')
                                      : item.device,
                                ),
                                TableText(item.appVersion, muted: true),
                                item.online && item.device.isNotEmpty
                                    ? TextButton(
                                        onPressed: () =>
                                            unawaited(_kick(item.ip)),
                                        child: Text(L10n.t('移除')),
                                      )
                                    : TableText(
                                        item.device.isEmpty
                                            ? L10n.t('不支持')
                                            : '',
                                        muted: true,
                                      ),
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
