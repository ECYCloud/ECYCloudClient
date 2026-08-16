import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/api/api_exception.dart';
import '../../data/api/panel_api_client.dart';
import '../../data/models/shop.dart';
import '../app_scope.dart';
import '../format.dart';
import '../shell_navigator.dart';
import '../theme.dart';
import '../widgets/page_header.dart';
import '../widgets/payment_wait_dialog.dart';
import '../widgets/refresh_button.dart';
import '../widgets/rich_html_view.dart';
import '../widgets/section_card.dart';
import '../widgets/switch_tile.dart';
import '../widgets/tag_chip.dart';
import 'purchases_page.dart';
import 'recharge_page.dart';
import '../../l10n/l10n.dart';

enum _PayMethod { balance, alipay, wxpay }

extension on _PayMethod {
  String get epayType => switch (this) {
    _PayMethod.balance => '',
    _PayMethod.alipay => 'alipay',
    _PayMethod.wxpay => 'wxpay',
  };

  String get label => switch (this) {
    _PayMethod.balance => L10n.t('余额'),
    _PayMethod.alipay => L10n.t('支付宝'),
    _PayMethod.wxpay => L10n.t('微信'),
  };
}

class ShopPage extends StatefulWidget {
  const ShopPage({super.key});

  @override
  State<ShopPage> createState() => _ShopPageState();
}

class _ShopPageState extends State<ShopPage> {
  static const List<(String, String)> _tabKeys = <(String, String)>[
    ('plan', '套餐'),
    ('traffic_package', '流量包'),
    ('card_key', '卡密'),
  ];

  ShopCatalog? _catalog;
  String? _error;
  bool _busy = false;
  bool _started = false;
  String _tab = 'plan';
  int _duration = 0;
  DateTime? _cooldownUntil;
  Timer? _ticker;
  Timer? _catalogTicker;

  @override
  void initState() {
    super.initState();
    final String? pending = ShellNavigator.takePendingShopTab();
    if (pending != null) {
      _tab = pending;
    }
    ShellNavigator.bindShopTab(_selectShopTab);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      // 与首页账号刷新同间隔；/shop/products 不在面板限流名单内
      _catalogTicker = Timer.periodic(
        const Duration(seconds: 60),
        (_) => unawaited(_load(silent: true)),
      );
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    ShellNavigator.unbindShopTab(_selectShopTab);
    _ticker?.cancel();
    _catalogTicker?.cancel();
    super.dispose();
  }

  void _selectShopTab(String tab) {
    if (!mounted || _tab == tab) {
      return;
    }
    setState(() => _tab = tab);
  }

  PanelApiClient? get _api => AppScope.of(context).auth.api;

  int get _cooldownRemaining {
    final DateTime? until = _cooldownUntil;
    if (until == null) {
      return 0;
    }
    final int seconds = until.difference(DateTime.now()).inSeconds;
    return seconds > 0 ? seconds : 0;
  }

  Future<void> _load({bool silent = false}) async {
    final PanelApiClient? api = _api;
    if (api == null) {
      return;
    }
    if (!silent || _catalog == null) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      final ShopCatalog catalog = await api.fetchShopProducts();
      if (!mounted) {
        return;
      }
      setState(() {
        _catalog = catalog;
        _busy = false;
        _error = null;
        _duration = _resolveDuration(catalog);
        _setCooldown(catalog.planCooldownRemaining);
      });
      _syncTicker(catalog);
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      if (silent && _catalog != null) {
        return;
      }
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  void _setCooldown(int remaining) {
    _cooldownUntil = remaining > 0
        ? DateTime.now().add(Duration(seconds: remaining))
        : null;
  }

  /// 与网页一致的默认时长：已选 > 后台设置 > 最低天数
  int _resolveDuration(ShopCatalog catalog) {
    final List<int> durations = _durationsOf(catalog);
    if (durations.contains(_duration)) {
      return _duration;
    }
    if (durations.contains(catalog.defaultDuration)) {
      return catalog.defaultDuration;
    }
    return durations.isEmpty ? 0 : durations.first;
  }

  List<int> _durationsOf(ShopCatalog catalog) {
    final Set<int> durations = <int>{
      for (final ShopProduct product in catalog.ofType('plan'))
        if (product.classExpire > 0) product.classExpire,
    };
    return durations.toList()..sort();
  }

  /// 倒计时逐秒刷新，无倒计时商品时不空转
  void _syncTicker(ShopCatalog catalog) {
    final bool needed = catalog.products.any(
      (ShopProduct product) => product.countdowns.isNotEmpty,
    );
    if (needed == (_ticker != null)) {
      return;
    }
    _ticker?.cancel();
    _ticker = needed
        ? Timer.periodic(
            const Duration(seconds: 1),
            (_) => mounted ? setState(() {}) : null,
          )
        : null;
  }

  Future<void> _buyPlan(ShopProduct product) async {
    final PanelApiClient? api = _api;
    if (api == null) {
      return;
    }
    if (_cooldownRemaining > 0) {
      await _showMessage(
        L10n.t('您在24小时内已购买过套餐了，请在 {0} 后再购买新套餐。', <Object>[_cooldownText(_cooldownRemaining)]),
      );
      return;
    }
    try {
      final PlanQuote quote = await api.fetchPlanQuote(shop: product.id);
      if (!mounted) {
        return;
      }
      if (quote.cooldown) {
        setState(() => _setCooldown(quote.cooldownRemaining));
        await _showMessage(quote.cooldownMsg);
        return;
      }
      final _PlanOrder? order = await showDialog<_PlanOrder>(
        context: context,
        builder: (BuildContext context) => _PlanOrderDialog(
          api: api,
          product: product,
          quote: quote,
          balance: _catalog?.money ?? 0,
        ),
      );
      if (order == null || !mounted) {
        return;
      }
      if (order.cooldownMsg.isNotEmpty) {
        setState(() => _setCooldown(order.cooldownRemaining));
        await _showMessage(order.cooldownMsg);
        return;
      }
      await _submit(
        order.method,
        () => api.buyPlan(
          shop: product.id,
          coupon: order.coupon,
          autoRenew: order.autoRenew,
          disableOthers: true,
          epayType: order.method.epayType,
        ),
      );
    } on ApiException catch (e) {
      await _showMessage(e.message);
    }
  }

  Future<void> _buyTrafficPackage(ShopProduct product) async {
    final PanelApiClient? api = _api;
    if (api == null) {
      return;
    }
    try {
      final ProductQuote quote = await api.fetchTrafficPackageQuote(product.id);
      final _PayMethod? method = await _confirmSimpleOrder(
        title: L10n.t('流量包订单确认'),
        note: L10n.t('流量包仅限在当前套餐效期内使用'),
        quote: quote,
        alwaysShowStock: false,
      );
      if (method == null) {
        return;
      }
      await _submit(
        method,
        () =>
            api.buyTrafficPackage(shop: product.id, epayType: method.epayType),
      );
    } on ApiException catch (e) {
      await _showMessage(e.message);
    }
  }

  Future<void> _buyCardKey(ShopProduct product) async {
    final PanelApiClient? api = _api;
    if (api == null) {
      return;
    }
    try {
      final ProductQuote quote = await api.fetchCardKeyQuote(product.id);
      final _PayMethod? method = await _confirmSimpleOrder(
        title: L10n.t('卡密商品订单确认'),
        note: '',
        quote: quote,
        alwaysShowStock: true,
      );
      if (method == null) {
        return;
      }
      await _submit(
        method,
        () => api.buyCardKey(shop: product.id, epayType: method.epayType),
      );
    } on ApiException catch (e) {
      await _showMessage(e.message);
    }
  }

  Future<_PayMethod?> _confirmSimpleOrder({
    required String title,
    required String note,
    required ProductQuote quote,
    required bool alwaysShowStock,
  }) {
    if (!mounted) {
      return Future<_PayMethod?>.value();
    }
    return showDialog<_PayMethod>(
      context: context,
      builder: (BuildContext context) => _SimpleOrderDialog(
        title: title,
        note: note,
        quote: quote,
        alwaysShowStock: alwaysShowStock,
        balance: _catalog?.money ?? 0,
      ),
    );
  }

  Future<void> _submit(
    _PayMethod method,
    Future<ShopPurchaseResult> Function() request,
  ) async {
    try {
      final ShopPurchaseResult result = await request();
      if (!mounted) {
        return;
      }
      if (result.needsOnlinePayment) {
        await _payOnline(result, method);
        return;
      }
      await _showMessage(result.message, cardKey: result.cardKey);
      await _refreshAfterPurchase();
    } on ApiException catch (e) {
      await _showMessage(e.message);
    }
  }

  Future<void> _payOnline(ShopPurchaseResult result, _PayMethod method) async {
    final PanelApiClient? api = _api;
    if (api == null) {
      return;
    }
    final PaymentStatus? status = await showDialog<PaymentStatus>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => PaymentWaitDialog(
        api: api,
        result: result,
        methodLabel: method.label,
        timeoutHint: L10n.t('长时间未收到支付结果，可稍后在购买记录中确认。'),
      ),
    );
    if (status != null) {
      await _showMessage(L10n.t('支付成功，订单已到账。'), cardKey: status.cardKey);
    }
    await _refreshAfterPurchase();
  }

  Future<void> _refreshAfterPurchase() async {
    if (!mounted) {
      return;
    }
    final AppScope scope = AppScope.of(context);
    await _load();
    await scope.auth.refreshProfile();
  }

  Future<void> _openRecharge() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const RechargePage(),
      ),
    );
    if (!mounted) {
      return;
    }
    await _refreshAfterPurchase();
  }

  Future<void> _showMessage(String message, {String cardKey = ''}) async {
    if (!mounted || (message.isEmpty && cardKey.isEmpty)) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) =>
          _MessageDialog(message: message, cardKey: cardKey),
    );
  }

  static String _cooldownText(int seconds) {
    final StringBuffer text = StringBuffer();
    final int hours = seconds ~/ 3600;
    final int minutes = seconds % 3600 ~/ 60;
    final int rest = seconds % 60;
    if (hours > 0) {
      text.write(L10n.t('{0}小时', <Object>[hours]));
    }
    if (minutes > 0) {
      text.write(L10n.t('{0}分钟', <Object>[minutes]));
    }
    if (rest > 0) {
      text.write(L10n.t('{0}秒', <Object>[rest]));
    }
    return text.toString();
  }

  @override
  Widget build(BuildContext context) {
    final ShopCatalog? catalog = _catalog;

    return Column(
      children: <Widget>[
        PageHeader(
          title: L10n.t('商店'),
          showUserAvatar: true,
          actions: <Widget>[
            RefreshButton(tooltip: L10n.t('刷新商品'), onRefresh: _load),
          ],
        ),
        Expanded(
          child: RefreshIndicator(onRefresh: _load, child: _body(catalog)),
        ),
      ],
    );
  }

  Widget _body(ShopCatalog? catalog) {
    if (catalog == null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: <Widget>[
          const SizedBox(height: 100),
          if (_busy)
            const Center(child: CircularProgressIndicator())
          else if (_error != null)
            Text(_error!, textAlign: TextAlign.center)
          else
            Center(child: Text(L10n.t('暂无商品'))),
        ],
      );
    }

    final List<int> durations = _tab == 'plan'
        ? _durationsOf(catalog)
        : const <int>[];
    final List<ShopProduct> products = <ShopProduct>[
      for (final ShopProduct product in catalog.ofType(_tab))
        if (durations.isEmpty || product.classExpire == _duration) product,
    ];

    final ThemeData theme = Theme.of(context);
    final TextStyle? noticeStyle = theme.textTheme.bodyMedium;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(14),
      children: <Widget>[
        SectionCard(
          icon: Icons.account_balance_wallet_outlined,
          title: L10n.t('账户余额'),
          action: TextButton(
            style: AppTheme.inlineTextLink(theme.colorScheme),
            onPressed: () => unawaited(_openRecharge()),
            child: Text(L10n.t('余额充值')),
          ),
          child: InfoRow(
            label: L10n.t('当前余额'),
            value: '¥ ${catalog.money.toStringAsFixed(2)}',
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          icon: Icons.info_outline,
          title: L10n.t('注意事项'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _ShopNotice(
                icon: Icons.campaign_outlined,
                child: Text(
                  L10n.t('每周六日所有的套餐、流量包将进行9折促销。'),
                  style: noticeStyle?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _ShopNotice(
                icon: Icons.campaign_outlined,
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    Text(L10n.t('接独享节点定制，请 '), style: noticeStyle),
                    TextButton(
                      style: AppTheme.inlineTextLink(theme.colorScheme),
                      onPressed: () => ShellNavigator.go(
                        context,
                        ShellNavigator.ticketsTab,
                      ),
                      child: Text(L10n.t('提交工单')),
                    ),
                    Text(
                      L10n.t(' 发送需求。请说明你的使用场景/需求，需要定制的地区，是否要优化线路等。'),
                      style: noticeStyle,
                    ),
                  ],
                ),
              ),
              _ShopNotice(
                icon: Icons.campaign_outlined,
                child: Text(L10n.t('旧套餐未过期购买新套餐视为更换套餐，会自动计算所需差价。')),
              ),
              _ShopNotice(
                icon: Icons.campaign_outlined,
                child: Text(L10n.t('流量不够用可以购买流量包，可和套餐流量叠加。')),
              ),
              _ShopNotice(
                icon: Icons.campaign_outlined,
                child: Text(L10n.t('购买新套餐或续费时会重置您的账户流量，也包括流量包内的流量。')),
              ),
              _ShopNotice(
                icon: Icons.campaign_outlined,
                child: Text(L10n.t('套餐内流量、流量包仅限在当前套餐有效期内使用，过期即失效。')),
              ),
              _ShopNotice(
                icon: Icons.campaign_outlined,
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    Text(L10n.t('自动续费可在 '), style: noticeStyle),
                    TextButton(
                      style: AppTheme.inlineTextLink(theme.colorScheme),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (BuildContext context) =>
                              const PurchasesPage(),
                        ),
                      ),
                      child: Text(L10n.t('购买记录')),
                    ),
                    Text(L10n.t(' 中关闭。'), style: noticeStyle),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: SegmentedButton<String>(
            segments: <ButtonSegment<String>>[
              for (final (String type, String label) in _tabKeys)
                ButtonSegment<String>(
                  value: type,
                  label: Text(L10n.t(label)),
                ),
            ],
            selected: <String>{_tab},
            onSelectionChanged: (Set<String> selection) =>
                setState(() => _tab = selection.first),
            showSelectedIcon: false,
          ),
        ),
        if (durations.length > 1) ...<Widget>[
          const SizedBox(height: 12),
          Center(
            child: SegmentedButton<int>(
              segments: <ButtonSegment<int>>[
                for (final int duration in durations)
                  ButtonSegment<int>(
                    value: duration,
                    label: Text(L10n.t('{0}天', <Object>[duration])),
                  ),
              ],
              selected: <int>{_duration},
              onSelectionChanged: (Set<int> selection) =>
                  setState(() => _duration = selection.first),
              showSelectedIcon: false,
            ),
          ),
        ],
        const SizedBox(height: 12),
        _grid(<Widget>[
          for (final ShopProduct product in products)
            switch (_tab) {
              'plan' => _PlanCard(product: product, onBuy: _buyPlan),
              'traffic_package' => _CompactCard(
                product: product,
                onBuy: _buyTrafficPackage,
              ),
              _ => _CompactCard(product: product, onBuy: _buyCardKey),
            },
        ]),
        if (products.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 60),
            child: Center(child: Text(L10n.t('暂无商品'))),
          ),
      ],
    );
  }

  Widget _grid(List<Widget> cards) {
    if (cards.isEmpty) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        const double spacing = 10;
        const double minWidth = 320;
        final int columns = (constraints.maxWidth / minWidth).floor().clamp(
          1,
          3,
        );
        final double width =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: <Widget>[
            for (final Widget card in cards)
              SizedBox(width: width, child: card),
          ],
        );
      },
    );
  }
}

class _ShopNotice extends StatelessWidget {
  const _ShopNotice({required this.icon, required this.child});

  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            icon,
            size: 18,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.product, required this.onBuy});

  final ShopProduct product;
  final ValueChanged<ShopProduct> onBuy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool unlimitedExpire = product.classExpire == 36500;

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.06),
              border: Border(
                bottom: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.6),
                ),
              ),
            ),
            child: Column(
              spacing: 8,
              children: <Widget>[
                Text(
                  product.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge,
                ),
                _ProductChips(
                  product: product,
                  alignment: WrapAlignment.center,
                  alwaysShowRegistration: true,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '¥ ${product.price}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                  ),
                ),
                if (product.classExpire > 1 && !unlimitedExpire)
                  Text(
                    L10n.t('≈ {0} 元 / 天', <Object>[
                      (product.amount / product.classExpire).toStringAsFixed(2),
                    ]),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                if (product.hasLimitedSale)
                  Text(
                    L10n.t('原价 ¥ {0}', <Object>[product.basePrice]),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      decoration: TextDecoration.lineThrough,
                    ),
                  ),
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    for (final (String label, String value)
                        in <(String, String)>[
                          (L10n.t('等级'), 'VIP ${product.userClass}'),
                          (
                            L10n.t('在线IP数'),
                            product.connector == 0
                                ? L10n.t('无限制')
                                : L10n.t('{0} 个', <Object>[product.connector]),
                          ),
                          (
                            L10n.t('网络速率'),
                            product.speedLimit == 0
                                ? L10n.t('无限制')
                                : '${Format.number(product.speedLimit)} Mbps',
                          ),
                        ])
                      Expanded(
                        child: Column(
                          spacing: 2,
                          children: <Widget>[
                            Text(
                              value,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium,
                            ),
                            Text(label, style: theme.textTheme.bodySmall),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                // 与上方三等分指标行同一栅格：标签落在左列、取值落在右列，
                // 列宽不一致就会出现与上方内容错位的视觉效果
                for (final (String label, String value) in <(String, String)>[
                  (
                    L10n.t('VIP有效期'),
                    unlimitedExpire ? L10n.t('不限时') : L10n.t('{0} 天', <Object>[product.classExpire]),
                  ),
                  (
                    product.classExpire == 1 ? L10n.t('试用流量') : L10n.t('每月流量'),
                    product.bandwidth == 10000
                        ? L10n.t('无限制')
                        : '${Format.number(product.bandwidth)} GB',
                  ),
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2.5),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        const Spacer(),
                        Expanded(
                          child: Text(
                            value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                for (final String service in product.contentExtra)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Icon(
                          Icons.check_circle_outline,
                          size: 13,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            service,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: product.inStock ? () => onBuy(product) : null,
                  child: Text(product.inStock ? L10n.t('购买') : L10n.t('已售罄')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactCard extends StatelessWidget {
  const _CompactCard({required this.product, required this.onBuy});

  final ShopProduct product;
  final ValueChanged<ShopProduct> onBuy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(product.name, style: theme.textTheme.titleSmall),
              ),
              const SizedBox(width: 8),
              Text(
                '¥ ${product.price}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          if (product.hasLimitedSale)
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                L10n.t('原价 ¥ {0}', <Object>[product.basePrice]),
                style: theme.textTheme.bodySmall?.copyWith(
                  decoration: TextDecoration.lineThrough,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 8),
          _ProductChips(product: product),
          if (product.description.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                title: Text(L10n.t('商品描述'), style: theme.textTheme.bodySmall),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[RichHtmlView(product.description)],
              ),
            ),
          ],
          const SizedBox(height: 10),
          FilledButton(
            onPressed: product.inStock ? () => onBuy(product) : null,
            child: Text(product.inStock ? L10n.t('购买') : L10n.t('已售罄')),
          ),
        ],
      ),
    );
  }
}

class _ProductChips extends StatelessWidget {
  const _ProductChips({
    required this.product,
    this.alignment = WrapAlignment.start,
    this.alwaysShowRegistration = false,
  });

  final ShopProduct product;
  final WrapAlignment alignment;

  // 网页套餐卡三态显示注册天数（含「不限注册天数」），流量包 / 卡密仅有限制时才显示
  final bool alwaysShowRegistration;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Wrap(
      alignment: alignment,
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        TagChip(
          icon: Icons.inventory_2_outlined,
          label: L10n.t('库存{0}', <Object>[product.stock]),
          color: product.inStock ? AppTheme.success : AppTheme.danger,
        ),
        if (product.isTrafficPackage)
          TagChip(
            icon: Icons.data_usage,
            label: '${Format.number(product.bandwidth)} GB',
            color: scheme.primary,
          ),
        TagChip(
          icon: Icons.shopping_cart_outlined,
          label: product.purchaseLimit > 0
              ? L10n.t('限购{0}次', <Object>[product.purchaseLimit])
              : L10n.t('不限购'),
        ),
        if (product.newUserDaysLimit > 0)
          TagChip(
            icon: Icons.person_add_alt,
            label: L10n.t('需注册未满{0}天', <Object>[product.newUserDaysLimit]),
          )
        else if (product.minRegistrationDays > 0)
          TagChip(
            icon: Icons.person_add_alt,
            label: L10n.t('需注册满{0}天', <Object>[product.minRegistrationDays]),
          )
        else if (alwaysShowRegistration)
          TagChip(icon: Icons.person_add_alt, label: L10n.t('不限注册天数')),
        for (final ShopCountdown countdown in product.countdowns)
          TagChip(
            icon: Icons.schedule,
            label:
                '${countdown.label} ${_countdownText(countdown.endsAt.difference(DateTime.now()))}',
            color: AppTheme.warning,
          ),
      ],
    );
  }

  static String _countdownText(Duration remaining) {
    if (remaining.isNegative) {
      return L10n.t('00天00时00分00秒');
    }
    final String days = '${remaining.inDays}'.padLeft(2, '0');
    final String hours = '${remaining.inHours % 24}'.padLeft(2, '0');
    final String minutes = '${remaining.inMinutes % 60}'.padLeft(2, '0');
    final String seconds = '${remaining.inSeconds % 60}'.padLeft(2, '0');
    return L10n.t('{0}天{1}时{2}分{3}秒', <Object>[days, hours, minutes, seconds]);
  }
}

class _PlanOrder {
  const _PlanOrder({
    required this.coupon,
    required this.autoRenew,
    required this.method,
  }) : cooldownMsg = '',
       cooldownRemaining = 0;

  const _PlanOrder.cooldown(this.cooldownMsg, this.cooldownRemaining)
    : coupon = '',
      autoRenew = false,
      method = _PayMethod.balance;

  final String coupon;
  final bool autoRenew;
  final _PayMethod method;
  final String cooldownMsg;
  final int cooldownRemaining;
}

class _PlanOrderDialog extends StatefulWidget {
  const _PlanOrderDialog({
    required this.api,
    required this.product,
    required this.quote,
    required this.balance,
  });

  final PanelApiClient api;
  final ShopProduct product;
  final PlanQuote quote;
  final double balance;

  @override
  State<_PlanOrderDialog> createState() => _PlanOrderDialogState();
}

class _PlanOrderDialogState extends State<_PlanOrderDialog> {
  final TextEditingController _coupon = TextEditingController();

  late PlanQuote _quote = widget.quote;
  late _PayMethod _method = _PaymentPicker.initial(
    _quote.amount,
    widget.balance,
  );
  String _appliedCoupon = '';
  String _couponMsg = '';
  bool _applying = false;
  bool _autoRenew = true;

  @override
  void dispose() {
    _coupon.dispose();
    super.dispose();
  }

  Future<void> _applyCoupon() async {
    final String coupon = _coupon.text.trim();
    if (coupon.isEmpty) {
      setState(() => _couponMsg = L10n.t('请输入优惠码'));
      return;
    }
    setState(() {
      _applying = true;
      _couponMsg = L10n.t('正在验证优惠码...');
    });
    try {
      final PlanQuote quote = await widget.api.fetchPlanQuote(
        shop: widget.product.id,
        coupon: coupon,
      );
      if (!mounted) {
        return;
      }
      if (quote.cooldown) {
        Navigator.of(
          context,
        ).pop(_PlanOrder.cooldown(quote.cooldownMsg, quote.cooldownRemaining));
        return;
      }
      setState(() {
        _quote = quote;
        _applying = false;
        _appliedCoupon = quote.couponApplied ? coupon : '';
        _couponMsg = quote.couponMsg.isNotEmpty
            ? quote.couponMsg
            : quote.couponApplied && quote.credit > 0
            ? L10n.t('优惠码应用成功，优惠 {0}%', <Object>[quote.credit])
            : quote.couponApplied
            ? L10n.t('优惠码应用成功')
            : '';
        _method = _PaymentPicker.initial(quote.amount, widget.balance);
      });
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _applying = false;
        _couponMsg = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PlanQuote quote = _quote;

    return AlertDialog(
      title: Text(L10n.t('套餐订单确认')),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(L10n.t('商品名称：{0}', <Object>[quote.name])),
              const SizedBox(height: 4),
              Text(
                _totalText(quote.total, quote.basePrice, quote.hasLimitedSale),
                style: theme.textTheme.titleSmall,
              ),
              if (quote.hasStockLimit) ...<Widget>[
                const SizedBox(height: 4),
                Text(L10n.t('库存：{0}', <Object>[quote.stock])),
              ],
              if (quote.hasTrafficResetFee) ...<Widget>[
                const SizedBox(height: 10),
                _DetailBlock(
                  title: L10n.t('流量重置费用'),
                  lines: <String>[
                    L10n.t('现有套餐：{0} 已使用：{1} / {2}（{3}%）', <Object>[quote.trafficCurrentShopName, Format.bytes(quote.trafficUsed), Format.bytes(quote.trafficTotal), quote.trafficUsagePercent.toStringAsFixed(2)]),
                    L10n.t('新套餐：{0} 计费基准价：{1} 元', <Object>[quote.name, quote.trafficBillingBasePrice]),
                    L10n.t(
                      '流量重置费：{0} x {1}%{2} = {3} 元',
                      <Object>[
                        quote.trafficBillingBasePrice,
                        quote.trafficFeePercent.toStringAsFixed(2),
                        quote.trafficFeeIsCapped ? L10n.t('（费用上限）') : '',
                        quote.trafficResetFee,
                      ],
                    ),
                    L10n.t('费用规则：按已用流量比例计算，50% 封顶'),
                  ],
                ),
              ],
              if (quote.hasValidOrder &&
                  quote.upgradeMsg.isNotEmpty) ...<Widget>[
                const SizedBox(height: 10),
                _DetailBlock(
                  title: L10n.t('剩余价值抵扣'),
                  lines: <String>[quote.upgradeMsg],
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _coupon,
                      decoration: InputDecoration(
                        labelText: L10n.t('优惠码'),
                        hintText: L10n.t('如有优惠码请在此输入'),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _applying ? null : _applyCoupon,
                    child: Text(L10n.t('应用')),
                  ),
                ],
              ),
              if (_couponMsg.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Text(_couponMsg, style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: 12),
              _PaymentPicker(
                total: quote.amount,
                balance: widget.balance,
                value: _method,
                onChanged: (_PayMethod method) =>
                    setState(() => _method = method),
              ),
              if (widget.product.autoRenew != 0)
                SwitchTile(
                  icon: Icons.autorenew,
                  title: L10n.t('到期时自动续费'),
                  value: _autoRenew,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (bool value) => setState(() => _autoRenew = value),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(L10n.t('取消')),
        ),
        FilledButton(
          onPressed: _applying
              ? null
              : () => Navigator.of(context).pop(
                  _PlanOrder(
                    coupon: _appliedCoupon,
                    autoRenew: _autoRenew,
                    method: quote.amount <= 0 ? _PayMethod.balance : _method,
                  ),
                ),
          child: Text(L10n.t('购买')),
        ),
      ],
    );
  }
}

class _SimpleOrderDialog extends StatefulWidget {
  const _SimpleOrderDialog({
    required this.title,
    required this.note,
    required this.quote,
    required this.alwaysShowStock,
    required this.balance,
  });

  final String title;
  final String note;
  final ProductQuote quote;
  final bool alwaysShowStock;
  final double balance;

  @override
  State<_SimpleOrderDialog> createState() => _SimpleOrderDialogState();
}

class _SimpleOrderDialogState extends State<_SimpleOrderDialog> {
  late _PayMethod _method = _PaymentPicker.initial(
    widget.quote.amount,
    widget.balance,
  );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ProductQuote quote = widget.quote;

    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.note.isNotEmpty) ...<Widget>[
            Text(widget.note, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
          ],
          Text(L10n.t('商品名称：{0}', <Object>[quote.name])),
          const SizedBox(height: 4),
          Text(
            _totalText(quote.total, quote.basePrice, quote.hasLimitedSale),
            style: theme.textTheme.titleSmall,
          ),
          if (widget.alwaysShowStock || quote.hasStockLimit) ...<Widget>[
            const SizedBox(height: 4),
            Text(L10n.t('库存：{0}', <Object>[quote.stock])),
          ],
          const SizedBox(height: 12),
          _PaymentPicker(
            total: quote.amount,
            balance: widget.balance,
            value: _method,
            onChanged: (_PayMethod method) =>
                setState(() => _method = method),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(L10n.t('取消')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(quote.amount <= 0 ? _PayMethod.balance : _method),
          child: Text(L10n.t('确定')),
        ),
      ],
    );
  }
}

/// 与网页一致：0 元订单只走余额；余额不足时余额选项不可选，默认支付宝
class _PaymentPicker extends StatelessWidget {
  const _PaymentPicker({
    required this.total,
    required this.balance,
    required this.value,
    required this.onChanged,
  });

  final double total;
  final double balance;
  final _PayMethod value;
  final ValueChanged<_PayMethod> onChanged;

  static _PayMethod initial(double total, double balance) =>
      total <= 0 || balance >= total ? _PayMethod.balance : _PayMethod.alipay;

  @override
  Widget build(BuildContext context) {
    if (total <= 0) {
      return const SizedBox.shrink();
    }
    final ThemeData theme = Theme.of(context);
    final bool affordable = balance >= total;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(L10n.t('选择支付方式'), style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<_PayMethod>(
          segments: <ButtonSegment<_PayMethod>>[
            ButtonSegment<_PayMethod>(
              value: _PayMethod.balance,
              label: Text(L10n.t('余额')),
              icon: const Icon(Icons.account_balance_wallet_outlined),
              enabled: affordable,
            ),
            ButtonSegment<_PayMethod>(
              value: _PayMethod.alipay,
              label: Text(L10n.t('支付宝')),
            ),
            ButtonSegment<_PayMethod>(
              value: _PayMethod.wxpay,
              label: Text(L10n.t('微信支付')),
            ),
          ],
          selected: <_PayMethod>{value},
          onSelectionChanged: (Set<_PayMethod> selection) =>
              onChanged(selection.first),
          showSelectedIcon: false,
        ),
        const SizedBox(height: 6),
        Text(
          affordable
              ? L10n.t('当前余额：¥ {0}', <Object>[balance.toStringAsFixed(2)])
              : L10n.t('当前余额：¥ {0}，余额不足，请选择在线支付', <Object>[balance.toStringAsFixed(2)]),
          style: theme.textTheme.bodySmall?.copyWith(
            color: affordable ? null : theme.colorScheme.error,
          ),
        ),
      ],
    );
  }
}

class _DetailBlock extends StatelessWidget {
  const _DetailBlock({required this.title, required this.lines});

  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          for (final String line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text(line, style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

class _MessageDialog extends StatelessWidget {
  const _MessageDialog({required this.message, required this.cardKey});

  final String message;
  final String cardKey;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(L10n.t('提示')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 服务端 msg 给网页用，卡密已嵌在 HTML 里；客户端另有 card_key，去掉重复
            RichHtmlView(
              cardKey.isEmpty
                  ? message
                  : _messageWithoutCardKey(message, cardKey),
            ),
            if (cardKey.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              SelectableText(
                cardKey,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => unawaited(_copy(context)),
                  icon: const Icon(Icons.copy, size: 16),
                  label: Text(L10n.t('复制卡密')),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(L10n.t('我知道了')),
        ),
      ],
    );
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: cardKey));
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(L10n.t('已复制卡密')),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  static String _messageWithoutCardKey(String message, String cardKey) {
    String cleaned = message.replaceAll(
      RegExp(r'<code\b[^>]*>[\s\S]*?</code>', caseSensitive: false),
      '',
    );
    if (cardKey.isNotEmpty) {
      cleaned = cleaned.replaceAll(cardKey, '');
    }
    return cleaned
        .replaceAll(RegExp(r'(?:<br\s*/?>\s*)+$', caseSensitive: false), '')
        .trim();
  }
}

String _totalText(String total, String basePrice, bool hasLimitedSale) =>
    basePrice.isNotEmpty && basePrice != total
    ? L10n.t('总金额：{0} 元（{1}：{2} 元）', <Object>[
        total,
        hasLimitedSale ? L10n.t('限时价格') : L10n.t('原价'),
        basePrice,
      ])
    : L10n.t('总金额：{0} 元', <Object>[total]);
