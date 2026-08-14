import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/api/api_exception.dart';
import '../../data/api/panel_api_client.dart';
import '../../data/models/account.dart';
import '../../state/auth_controller.dart';
import '../app_scope.dart';
import '../widgets/list_toolbar.dart';
import '../widgets/page_header.dart';
import '../widgets/refresh_button.dart';
import '../widgets/rich_html_view.dart';
import '../widgets/simple_data_table.dart';
import 'account_page.dart';

class PurchasesPage extends StatefulWidget {
  const PurchasesPage({super.key});

  @override
  State<PurchasesPage> createState() => _PurchasesPageState();
}

class _PurchasesPageState extends State<PurchasesPage> {
  final List<PurchaseRecord> _items = <PurchaseRecord>[];
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
      final PurchaseListPage result = await api.fetchPurchases(
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
          ..addAll(result.purchases);
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

  Future<void> _toggle(PurchaseRecord item, bool enable) async {
    final AuthController auth = AppScope.of(context).auth;
    await togglePurchaseAutoRenewDialog(
      context,
      auth: auth,
      purchaseId: item.id,
      enable: enable,
    );
    if (mounted) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: <Widget>[
          SafeArea(
            bottom: false,
            child: PageHeader(
              title: '购买记录',
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
            searchHint: '订单号 / 商品名',
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
                          minWidth: 1280,
                          columns: const <String>[
                            '操作',
                            '订单号',
                            '商品名称',
                            '购买价格',
                            '商品详情',
                            '购买时间',
                            '套餐过期时间',
                            '自动续费时间',
                          ],
                          emptyText: '暂无购买记录',
                          rows: <List<Widget>>[
                            for (final PurchaseRecord item in _items)
                              <Widget>[
                                item.canToggle
                                    ? TextButton(
                                        onPressed: () => unawaited(
                                          _toggle(item, !item.autoRenew),
                                        ),
                                        child: Text(
                                          item.autoRenew ? '关闭自动续费' : '开启自动续费',
                                        ),
                                      )
                                    : const TableText('-', muted: true),
                                TableText(item.orderNo),
                                TableText(
                                  item.shopName.isEmpty
                                      ? item.name
                                      : item.shopName,
                                  bold: true,
                                ),
                                TableMoney(item.price),
                                item.content.isEmpty
                                    ? const TableText('-', muted: true)
                                    : RichHtmlView(item.content),
                                TableText(item.datetime, muted: true),
                                TableText(
                                  item.expTime.isEmpty || item.expTime == '-'
                                      ? '-'
                                      : item.expTime,
                                  muted: true,
                                ),
                                TableText(
                                  !item.autoRenew ||
                                          item.renew == null ||
                                          item.renew!.isEmpty
                                      ? '-'
                                      : item.renew!,
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
