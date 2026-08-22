import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/api/api_exception.dart';
import '../../data/api/panel_api_client.dart';
import '../../data/models/shop.dart';
import '../../l10n/l10n.dart';
import '../app_scope.dart';
import 'overlay_scroll_view.dart';
import 'qr_card.dart';

enum _PayMode { scheme, qrcode, browser }

class PaymentWaitDialog extends StatefulWidget {
  const PaymentWaitDialog({
    super.key,
    required this.api,
    required this.result,
    required this.methodLabel,
    required this.timeoutHint,
  });

  final PanelApiClient api;
  final ShopPurchaseResult result;

  final String methodLabel;

  final String timeoutHint;

  @override
  State<PaymentWaitDialog> createState() => _PaymentWaitDialogState();
}

class _PaymentWaitDialogState extends State<PaymentWaitDialog> {
  static const Duration _interval = Duration(seconds: 5);
  static const Duration _limit = Duration(minutes: 5);

  Timer? _timer;
  DateTime _deadline = DateTime.now().add(_limit);
  String _status = L10n.t('等待支付结果…');
  _PayMode _mode = _PayMode.browser;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_interval, (_) => unawaited(_poll()));
  }

  // AppScope 是 InheritedWidget，initState 里取不到，首次拿到依赖时才能决定形态
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) {
      return;
    }
    _started = true;
    _mode = switch (widget.result.payLaunch(
      supportsPayScheme: AppScope.of(context).platform.supportsPayScheme,
    )) {
      ShopPayLaunch.scheme => _PayMode.scheme,
      ShopPayLaunch.qrcode => _PayMode.qrcode,
      ShopPayLaunch.browser => _PayMode.browser,
    };
    if (_mode != _PayMode.qrcode) {
      unawaited(_launch());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _launch() async {
    final bool opened = await AppScope.of(context).platform.openUrl(
      _mode == _PayMode.scheme
          ? widget.result.appScheme
          : widget.result.paymentUrl,
    );
    if (!mounted || opened) {
      return;
    }
    setState(() {
      if (_mode == _PayMode.scheme && widget.result.paymentUrl.isNotEmpty) {
        _mode = _PayMode.browser;
        _status = L10n.t('未检测到已安装的{0}，可改用浏览器支付。', <Object>[widget.methodLabel]);
        return;
      }
      _status = L10n.t('无法打开支付页面，请稍后重试。');
    });
  }

  Future<void> _poll() async {
    if (DateTime.now().isAfter(_deadline)) {
      _timer?.cancel();
      if (mounted) {
        setState(() => _status = widget.timeoutHint);
      }
      return;
    }
    try {
      final PaymentStatus status = await widget.api.fetchPaymentStatus(
        widget.result.tradeNo,
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

  String get _hint => switch (_mode) {
    _PayMode.qrcode => L10n.t('请用{0}扫描下方二维码，完成支付后订单会自动到账。', <Object>[
      widget.methodLabel,
    ]),
    _PayMode.scheme => L10n.t('已唤起{0}，完成支付后订单会自动到账。', <Object>[
      widget.methodLabel,
    ]),
    _PayMode.browser => L10n.t('已在系统浏览器中打开支付页面，完成支付后订单会自动到账。'),
  };

  String get _retryLabel => switch (_mode) {
    _PayMode.qrcode => L10n.t('改用浏览器支付'),
    _PayMode.scheme => L10n.t('重新唤起{0}', <Object>[widget.methodLabel]),
    _PayMode.browser => L10n.t('重新打开支付页'),
  };

  @override
  Widget build(BuildContext context) {
    final bool canRetry =
        _mode == _PayMode.scheme || widget.result.paymentUrl.isNotEmpty;

    return AlertDialog(
      title: Text(L10n.t('等待支付')),
      content: OverlayScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(_hint),
            if (_mode == _PayMode.qrcode) ...<Widget>[
              const SizedBox(height: 12),
              Center(child: QrCard(data: widget.result.payQrcode)),
            ],
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _status,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(L10n.t('关闭')),
        ),
        if (canRetry)
          OutlinedButton(
            onPressed: () {
              if (_mode == _PayMode.qrcode) {
                setState(() => _mode = _PayMode.browser);
              }
              unawaited(_launch());
            },
            child: Text(_retryLabel),
          ),
        FilledButton(
          onPressed: () {
            _deadline = DateTime.now().add(_limit);
            unawaited(_poll());
          },
          child: Text(L10n.t('我已完成支付')),
        ),
      ],
    );
  }
}
