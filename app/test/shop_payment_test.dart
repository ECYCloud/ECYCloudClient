import 'package:ecycloud_client/data/models/shop.dart';
import 'package:flutter_test/flutter_test.dart';

ShopPurchaseResult parse(Map<String, dynamic> data) =>
    ShopPurchaseResult.fromEnvelope(<String, dynamic>{
      'msg': '正在跳转到支付页面...',
      'data': data,
    });

void main() {
  test('余额支付没有任何支付凭据', () {
    final ShopPurchaseResult result = parse(<String, dynamic>{
      'card_key': 'ABC-123',
    });

    expect(result.needsOnlinePayment, isFalse);
    expect(result.appScheme, '');
    expect(result.cardKey, 'ABC-123');
  });

  test('只有收银台链接时仍算在线支付，但没有可唤起的 scheme', () {
    final ShopPurchaseResult result = parse(<String, dynamic>{
      'tradeno': '2026081612000012345',
      'payment_url': 'https://pay.example.com/submit.php?pid=1&sign=x',
    });

    expect(result.needsOnlinePayment, isTrue);
    expect(result.appScheme, '');
  });

  test('微信收款码本身就是可唤起的 scheme', () {
    final ShopPurchaseResult result = parse(<String, dynamic>{
      'tradeno': '2026081612000012345',
      'payment_url': 'https://pay.example.com/submit.php?pid=1&sign=x',
      'pay_qrcode': 'weixin://wxpay/bizpayurl?pr=04IPMKM',
    });

    expect(result.payQrcode, 'weixin://wxpay/bizpayurl?pr=04IPMKM');
    expect(result.appScheme, 'weixin://wxpay/bizpayurl?pr=04IPMKM');
  });

  test('支付宝收款码是 https，画二维码可用但不能拿去唤起', () {
    final ShopPurchaseResult result = parse(<String, dynamic>{
      'tradeno': '2026081612000012345',
      'pay_qrcode': 'https://qr.alipay.com/bax001',
    });

    expect(result.needsOnlinePayment, isTrue);
    expect(result.appScheme, '');
  });

  test('手机有 scheme 时唤起 App', () {
    final ShopPurchaseResult result = parse(<String, dynamic>{
      'tradeno': '2026081612000012345',
      'pay_scheme': 'alipays://platformapi/startapp?appId=20000067',
      'pay_qrcode': 'https://qr.alipay.com/bax001',
    });

    expect(
      result.payLaunch(supportsPayScheme: true),
      ShopPayLaunch.scheme,
    );
  });

  test('电视即使有 scheme 也走二维码', () {
    final ShopPurchaseResult result = parse(<String, dynamic>{
      'tradeno': '2026081612000012345',
      'pay_scheme': 'alipays://platformapi/startapp?appId=20000067',
      'pay_qrcode': 'https://qr.alipay.com/bax001',
    });

    expect(
      result.payLaunch(supportsPayScheme: false),
      ShopPayLaunch.qrcode,
    );
  });

  test('电视没有收款码时退回浏览器', () {
    final ShopPurchaseResult result = parse(<String, dynamic>{
      'tradeno': '2026081612000012345',
      'payment_url': 'https://pay.example.com/submit.php?pid=1&sign=x',
    });

    expect(
      result.payLaunch(supportsPayScheme: false),
      ShopPayLaunch.browser,
    );
  });

  test('唤起链接优先于收款码', () {
    final ShopPurchaseResult result = parse(<String, dynamic>{
      'tradeno': '2026081612000012345',
      'pay_qrcode': 'https://qr.alipay.com/bax001',
      'pay_scheme': 'alipays://platformapi/startapp?appId=20000067',
    });

    expect(result.appScheme, 'alipays://platformapi/startapp?appId=20000067');
  });
}
