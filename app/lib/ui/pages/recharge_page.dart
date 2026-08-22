import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/api/api_exception.dart';
import '../../data/api/panel_api_client.dart';
import '../../data/models/account.dart';
import '../../data/models/shop.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/icon_image.dart';
import '../widgets/page_header.dart';
import '../widgets/payment_wait_dialog.dart';
import '../widgets/refresh_button.dart';
import '../widgets/section_card.dart';
import 'login_page.dart';
import '../../l10n/l10n.dart';

class RechargePage extends StatefulWidget {
  const RechargePage({super.key});

  @override
  State<RechargePage> createState() => _RechargePageState();
}

class _RechargePageState extends State<RechargePage> {
  final TextEditingController _code = TextEditingController();
  final TextEditingController _amount = TextEditingController();

  RechargeInfo? _info;
  String? _error;
  bool _busy = false;
  bool _started = false;

  PanelApiClient? get _api => AppScope.of(context).auth.api;

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
    _code.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final PanelApiClient? api = _api;
    if (api == null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final RechargeInfo info = await api.fetchRechargeInfo();
      if (!mounted) {
        return;
      }
      setState(() {
        _info = info;
        _busy = false;
      });
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  Future<void> _redeem() async {
    final PanelApiClient? api = _api;
    final String code = _code.text.trim();
    if (api == null || code.isEmpty || _busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final String msg = await api.redeemRechargeCode(code);
      if (!mounted) {
        return;
      }
      _code.clear();
      await showDialog<void>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: Text(L10n.t('兑换成功')),
          content: Text(msg.isEmpty ? L10n.t('兑换码已使用，余额已到账。') : msg),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(L10n.t('确定')),
            ),
          ],
        ),
      );
      if (!mounted) {
        return;
      }
      await AppScope.of(context).auth.refreshProfile();
      await _load();
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _pay(String type) async {
    final PanelApiClient? api = _api;
    final double? price = double.tryParse(_amount.text.trim());
    if (api == null || price == null || price <= 0 || _busy) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.t('请输入有效金额')),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final ShopPurchaseResult result = await api.rechargeWithEpay(
        price: price,
        type: type,
      );
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      if (!result.needsOnlinePayment) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.message.isEmpty ? L10n.t('充值已提交') : result.message,
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
        await AppScope.of(context).auth.refreshProfile();
        await _load();
        return;
      }
      final PaymentStatus? status = await showDialog<PaymentStatus>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) => PaymentWaitDialog(
          api: api,
          result: result,
          methodLabel: type == 'wxpay' ? L10n.t('微信') : L10n.t('支付宝'),
          timeoutHint: L10n.t('长时间未收到支付结果，可稍后在余额记录中确认。'),
        ),
      );
      if (!mounted) {
        return;
      }
      if (status != null) {
        await showDialog<void>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: Text(L10n.t('支付成功')),
            content: Text(L10n.t('支付成功，余额已到账')),
            actions: <Widget>[
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(L10n.t('确定')),
              ),
            ],
          ),
        );
      }
      if (!mounted) {
        return;
      }
      await AppScope.of(context).auth.refreshProfile();
      await _load();
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final RechargeInfo? info = _info;

    return Scaffold(
      body: Column(
        children: <Widget>[
          SafeArea(
            bottom: false,
            child: PageHeader(
              title: L10n.t('余额充值'),
              showBackButton: true,
              showUserAvatar: true,
              actions: <Widget>[
                RefreshButton(tooltip: L10n.t('刷新'), onRefresh: _load),
              ],
            ),
          ),
          Expanded(
            child: _busy && info == null
                ? const Center(child: CircularProgressIndicator())
                : _error != null && info == null
                ? Center(child: Text(_error!))
                : info == null
                ? const SizedBox.shrink()
                : ListView(
                    padding: AppTheme.pageScrollPadding,
                    children: <Widget>[
                      SectionCard(
                        icon: Icons.account_balance_wallet_outlined,
                        title: L10n.t('账户余额'),
                        child: Column(
                          children: <Widget>[
                            InfoRow(
                              label: L10n.t('当前余额'),
                              value: '¥ ${info.money.toStringAsFixed(2)}',
                            ),
                            InfoRow(
                              label: L10n.t('累计充值'),
                              value: '¥ ${info.totalTopUp}',
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      SectionCard(
                        icon: Icons.confirmation_number_outlined,
                        title: L10n.t('充值码兑换'),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            TextField(
                              controller: _code,
                              inputFormatters: <TextInputFormatter>[
                                asciiOnlyFormatter,
                              ],
                              decoration: InputDecoration(
                                labelText: L10n.t('充值码'),
                                prefixIcon: Icon(Icons.vpn_key_outlined),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Align(
                              alignment: Alignment.centerRight,
                              child: FilledButton(
                                onPressed: _busy ? null : _redeem,
                                child: Text(L10n.t('兑换')),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (info.hasEpay) ...<Widget>[
                        const SizedBox(height: 10),
                        SectionCard(
                          icon: Icons.payment_outlined,
                          title: L10n.t('在线充值'),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              TextField(
                                controller: _amount,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: InputDecoration(
                                  labelText: L10n.t('充值金额'),
                                  prefixIcon: Icon(Icons.currency_yuan),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: <Widget>[
                                  Expanded(
                                    child: TextButton.icon(
                                      onPressed: _busy
                                          ? null
                                          : () => unawaited(_pay('alipay')),
                                      icon: const LocalIcon(
                                        assets: <String>['assets/alipay.png'],
                                        width: 18,
                                        fallback: Icon(
                                          Icons.account_balance_wallet,
                                          size: 16,
                                        ),
                                      ),
                                      label: Text(L10n.t('支付宝')),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: TextButton.icon(
                                      onPressed: _busy
                                          ? null
                                          : () => unawaited(_pay('wxpay')),
                                      icon: const LocalIcon(
                                        assets: <String>['assets/wxpay.png'],
                                        width: 18,
                                        fallback: Icon(Icons.chat, size: 16),
                                      ),
                                      label: Text(L10n.t('微信支付')),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
