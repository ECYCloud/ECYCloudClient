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

class BalanceRecordsPage extends StatefulWidget {
  const BalanceRecordsPage({super.key});

  @override
  State<BalanceRecordsPage> createState() => _BalanceRecordsPageState();
}

class _BalanceRecordsPageState extends State<BalanceRecordsPage> {
  final List<BalanceTransactionItem> _items = <BalanceTransactionItem>[];
  int _page = 1;
  int _lastPage = 1;
  int _total = 0;
  int _perPage = 10;
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
      final BalanceListPage result = await api.fetchBalanceTransactions(
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: <Widget>[
          SafeArea(
            bottom: false,
            child: PageHeader(
              title: '余额记录',
              showBackButton: true,
              showUserAvatar: true,
              actions: <Widget>[
                RefreshButton(tooltip: '刷新', onRefresh: _load),
              ],
            ),
          ),
          ListToolbar(
            currentPage: _page,
            lastPage: _lastPage,
            total: _total,
            perPage: _perPage,
            searchHint: '订单号',
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
                      padding: const EdgeInsets.all(14),
                      children: <Widget>[
                        SimpleDataTable(
                          columns: const <String>[
                            '订单号',
                            '类型',
                            '金额',
                            '时间',
                          ],
                          emptyText: '暂无余额记录',
                          rows: <List<Widget>>[
                            for (final BalanceTransactionItem item in _items)
                              <Widget>[
                                TableText(item.orderNo),
                                TableText(item.typeText),
                                TableMoney(item.amount),
                                TableText(item.createdAt, muted: true),
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
