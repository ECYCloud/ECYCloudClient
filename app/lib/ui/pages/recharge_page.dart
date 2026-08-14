import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/api/api_exception.dart';
import '../../data/api/panel_api_client.dart';
import '../../data/models/account.dart';
import '../../data/models/shop.dart';
import '../app_scope.dart';
import '../widgets/page_header.dart';
import '../widgets/refresh_button.dart';
import '../widgets/section_card.dart';
import 'login_page.dart';

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
          title: const Text('兑换成功'),
          content: Text(msg.isEmpty ? '兑换码已使用，余额已到账。' : msg),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('确定'),
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
        const SnackBar(
          content: Text('请输入有效金额'),
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
            content: Text(result.message.isEmpty ? '充值已提交' : result.message),
            behavior: SnackBarBehavior.floating,
          ),
        );
        await AppScope.of(context).auth.refreshProfile();
        await _load();
        return;
      }
      await AppScope.of(context).platform.openUrl(result.paymentUrl);
      if (!mounted) {
        return;
      }
      final PaymentStatus? status = await showDialog<PaymentStatus>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) => _PaymentWaitDialog(
          api: api,
          tradeNo: result.tradeNo,
          paymentUrl: result.paymentUrl,
        ),
      );
      if (!mounted) {
        return;
      }
      if (status != null) {
        await showDialog<void>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('支付成功'),
            content: const Text('支付成功，余额已到账'),
            actions: <Widget>[
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('确定'),
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
              title: '余额充值',
              showBackButton: true,
              showUserAvatar: true,
              actions: <Widget>[
                RefreshButton(tooltip: '刷新', onRefresh: _load),
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
                    padding: const EdgeInsets.all(14),
                    children: <Widget>[
                SectionCard(
                  icon: Icons.account_balance_wallet_outlined,
                  title: '账户余额',
                  child: Column(
                    children: <Widget>[
                      InfoRow(
                        label: '当前余额',
                        value: '¥ ${info.money.toStringAsFixed(2)}',
                      ),
                      InfoRow(label: '累计充值', value: '¥ ${info.totalTopUp}'),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                SectionCard(
                  icon: Icons.confirmation_number_outlined,
                  title: '充值码兑换',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      TextField(
                        controller: _code,
                        inputFormatters: <TextInputFormatter>[
                          asciiOnlyFormatter,
                        ],
                        decoration: const InputDecoration(
                          labelText: '充值码',
                          prefixIcon: Icon(Icons.vpn_key_outlined),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton(
                          onPressed: _busy ? null : _redeem,
                          child: const Text('兑换'),
                        ),
                      ),
                    ],
                  ),
                ),
                if (info.hasEpay) ...<Widget>[
                  const SizedBox(height: 10),
                  SectionCard(
                    icon: Icons.payment_outlined,
                    title: '在线充值',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        TextField(
                          controller: _amount,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: '充值金额',
                            prefixIcon: Icon(Icons.attach_money),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () => unawaited(_pay('alipay')),
                                icon: const Icon(Icons.account_balance_wallet, size: 16),
                                label: const Text('支付宝'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton.tonalIcon(
                                onPressed: _busy
                                    ? null
                                    : () => unawaited(_pay('wxpay')),
                                icon: const Icon(Icons.chat, size: 16),
                                label: const Text('微信支付'),
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

class _PaymentWaitDialog extends StatefulWidget {
  const _PaymentWaitDialog({
    required this.api,
    required this.tradeNo,
    required this.paymentUrl,
  });

  final PanelApiClient api;
  final String tradeNo;
  final String paymentUrl;

  @override
  State<_PaymentWaitDialog> createState() => _PaymentWaitDialogState();
}

class _PaymentWaitDialogState extends State<_PaymentWaitDialog> {
  static const Duration _interval = Duration(seconds: 5);
  static const Duration _limit = Duration(minutes: 5);

  Timer? _timer;
  DateTime _deadline = DateTime.now().add(_limit);
  String _status = '等待支付结果…';

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_interval, (_) => unawaited(_poll()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (DateTime.now().isAfter(_deadline)) {
      _timer?.cancel();
      if (mounted) {
        setState(() => _status = '长时间未收到支付结果，可稍后在余额记录中确认。');
      }
      return;
    }
    try {
      final PaymentStatus status = await widget.api.fetchPaymentStatus(
        widget.tradeNo,
      );
      if (!mounted || !status.paid) {
        return;
      }
      _timer?.cancel();
      Navigator.of(context).pop(status);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _status = e.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('等待支付'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('已在系统浏览器中打开支付页面，完成支付后余额会自动到账。'),
          const SizedBox(height: 12),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text(
                _status,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        OutlinedButton(
          onPressed: () => unawaited(
            AppScope.of(context).platform.openUrl(widget.paymentUrl),
          ),
          child: const Text('重新打开支付页'),
        ),
        FilledButton(
          onPressed: () {
            _deadline = DateTime.now().add(_limit);
            unawaited(_poll());
          },
          child: const Text('我已完成支付'),
        ),
      ],
    );
  }
}
