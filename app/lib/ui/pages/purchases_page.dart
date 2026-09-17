import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../data/api/api_exception.dart';
import '../../data/api/panel_api_client.dart';
import '../../data/models/account.dart';
import '../../state/auth_controller.dart';
import '../app_scope.dart';
import '../auto_refresh_mixin.dart';
import '../theme.dart';
import '../widgets/list_toolbar.dart';
import '../widgets/page_header.dart';
import '../widgets/refresh_button.dart';
import '../widgets/rich_html_view.dart';
import '../widgets/simple_data_table.dart';
import 'account_page.dart';
import '../../l10n/l10n.dart';

class PurchasesPage extends StatefulWidget {
  const PurchasesPage({super.key});

  @override
  State<PurchasesPage> createState() => _PurchasesPageState();
}

class _PurchasesPageState extends State<PurchasesPage>
    with AutoRefreshMixin<PurchasesPage> {
  final List<PurchaseRecord> _items = <PurchaseRecord>[];
  int _page = 1;
  int _lastPage = 1;
  int _total = 0;
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
      startAutoRefresh(() => _load(silent: true));
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    final PanelApiClient? api = AppScope.of(context).auth.api;
    if (api == null || (silent && _busy)) {
      return;
    }
    if (!silent) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    await loadLatest(
      () => api.fetchPurchases(
        page: _page,
        length: ListToolbar.pageSize,
        search: _search,
      ),
      silent: silent,
      onData: (PurchaseListPage result) {
        setState(() {
          _items
            ..clear()
            ..addAll(result.purchases);
          _page = result.currentPage;
          _lastPage = result.lastPage;
          _total = result.total;
          if (!silent) {
            _busy = false;
          }
          _error = null;
        });
      },
      onError: (Object e) {
        setState(() {
          _error = e is ApiException
              ? e.message
              : L10n.t('加载失败：{0}', <Object>[e]);
          _busy = false;
        });
      },
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
              title: L10n.t('购买记录'),
              showBackButton: true,
              showUserAvatar: true,
              actions: <Widget>[
                RefreshButton(tooltip: L10n.t('刷新'), onRefresh: _load),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: AppTheme.pageScrollPadding.copyWith(left: 0, top: 0),
                children: <Widget>[
                  ListToolbar(
                    currentPage: _page,
                    lastPage: _lastPage,
                    total: _total,
                    searchHint: L10n.t('订单号 / 商品名'),
                    onSearchChanged: _onSearch,
                    onPageChanged: (int page) {
                      _page = page;
                      unawaited(_load());
                    },
                  ),
                  if (_busy && _items.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 80),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_error != null && _items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 80),
                      child: Center(child: Text(_error!)),
                    )
                  else
                    Padding(
                      padding: EdgeInsets.only(
                        left: AppTheme.pageScrollPadding.left,
                      ),
                      child: SimpleDataTable(
                        minWidth: 1280,
                        columns: <String>[
                          L10n.t('操作'),
                          L10n.t('订单号'),
                          L10n.t('商品名称'),
                          L10n.t('购买价格'),
                          L10n.t('商品详情'),
                          L10n.t('购买时间'),
                          L10n.t('套餐过期时间'),
                          L10n.t('自动续费时间'),
                        ],
                        emptyText: L10n.t('暂无购买记录'),
                        rows: <List<Widget>>[
                          for (final PurchaseRecord item in _items)
                            <Widget>[
                              item.canToggle
                                  ? TextButton(
                                      onPressed: () => unawaited(
                                        _toggle(item, !item.autoRenew),
                                      ),
                                      child: Text(
                                        item.autoRenew
                                            ? L10n.t('关闭自动续费')
                                            : L10n.t('开启自动续费'),
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
                                  : _PurchaseDetail(item.content),
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

class _PurchaseDetail extends StatefulWidget {
  const _PurchaseDetail(this.html);

  final String html;

  @override
  State<_PurchaseDetail> createState() => _PurchaseDetailState();
}

class _PurchaseDetailState extends State<_PurchaseDetail> {
  bool _expanded = false;
  bool _overflows = false;

  @override
  Widget build(BuildContext context) {
    final TextStyle style = Theme.of(context).textTheme.bodyMedium!;
    final double fontSize = style.fontSize ?? 13;
    final Color muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _ClampedHtml(
          maxHeight: 3 * 1.5 * fontSize,
          expanded: _expanded,
          onOverflow: (bool overflows) {
            if (_overflows == overflows) {
              return;
            }
            setState(() => _overflows = overflows);
          },
          child: RichHtmlView(
            widget.html,
            textStyle: style.copyWith(height: 1.5),
          ),
        ),
        if (_overflows)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  customBorder: AppTheme.pillShape,
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          L10n.t(_expanded ? '收起详情' : '查看详情'),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(fontSize: 12, color: muted),
                        ),
                        AnimatedRotation(
                          turns: _expanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(
                            Icons.expand_more,
                            size: 12,
                            color: muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ClampedHtml extends SingleChildRenderObjectWidget {
  const _ClampedHtml({
    required this.maxHeight,
    required this.expanded,
    required this.onOverflow,
    required super.child,
  });

  final double maxHeight;
  final bool expanded;
  final ValueChanged<bool> onOverflow;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _ClampedHtmlRender(
      maxHeight: maxHeight,
      expanded: expanded,
      onOverflow: onOverflow,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _ClampedHtmlRender renderObject,
  ) {
    renderObject
      ..maxHeight = maxHeight
      ..expanded = expanded
      ..onOverflow = onOverflow;
  }
}

class _ClampedHtmlRender extends RenderProxyBox {
  _ClampedHtmlRender({
    required this._maxHeight,
    required this._expanded,
    required this.onOverflow,
  });

  double _maxHeight;
  bool _expanded;
  ValueChanged<bool> onOverflow;
  bool? _lastOverflow;

  set maxHeight(double value) {
    if (_maxHeight == value) {
      return;
    }
    _maxHeight = value;
    markNeedsLayout();
  }

  set expanded(bool value) {
    if (_expanded == value) {
      return;
    }
    _expanded = value;
    markNeedsLayout();
  }

  void _report(bool overflows) {
    if (_lastOverflow == overflows) {
      return;
    }
    _lastOverflow = overflows;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      onOverflow(overflows);
    });
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    final RenderBox? child = this.child;
    if (child == null) {
      return 0;
    }
    final double height = child.getMaxIntrinsicHeight(width);
    if (_expanded || height <= _maxHeight) {
      return height;
    }
    return _maxHeight;
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      _report(false);
      return;
    }
    child.layout(
      constraints.copyWith(maxHeight: double.infinity, minHeight: 0),
      parentUsesSize: true,
    );
    final bool overflows = child.size.height > _maxHeight + 0.5;
    _report(overflows);
    final double height = _expanded || !overflows
        ? child.size.height
        : _maxHeight;
    size = constraints.constrain(Size(child.size.width, height));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final RenderBox? child = this.child;
    if (child == null) {
      return;
    }
    if (!_expanded && child.size.height > size.height + 0.5) {
      context.pushClipRect(needsCompositing, offset, Offset.zero & size, (
        PaintingContext context,
        Offset offset,
      ) {
        context.paintChild(child, offset);
      });
      return;
    }
    context.paintChild(child, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (child == null) {
      return false;
    }
    return result.addWithPaintOffset(
      offset: Offset.zero,
      position: position,
      hitTest: (BoxHitTestResult result, Offset transformed) {
        return child!.hitTest(result, position: transformed);
      },
    );
  }
}
