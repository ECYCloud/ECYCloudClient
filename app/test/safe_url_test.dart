import 'package:ecycloud_client/core/safe_url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('openUrl 放行 http(s) / mailto / tg 与支付 App scheme', () {
    expect(SafeUrl.canOpen('https://example.com/pay'), isTrue);
    expect(SafeUrl.canOpen('HTTP://example.com'), isTrue);
    expect(SafeUrl.canOpen('mailto:support@example.com'), isTrue);
    expect(SafeUrl.canOpen('tg://user?id=1'), isTrue);
    expect(SafeUrl.canOpen('weixin://wxpay/bizpayurl?pr=04IPMKM'), isTrue);
    expect(SafeUrl.canOpen('alipays://platformapi/startapp?appId=2021'), isTrue);
    expect(SafeUrl.canOpen('file:///C:/Windows/System32/calc.exe'), isFalse);
    expect(SafeUrl.canOpen('javascript:alert(1)'), isFalse);
    expect(SafeUrl.canOpen('ms-msdt:id'), isFalse);
    expect(SafeUrl.canOpen('intent://scan/#Intent;end'), isFalse);
    expect(SafeUrl.canOpen(r'\\evil\share\malware.exe'), isFalse);
    expect(SafeUrl.canOpen('/user/ticket'), isFalse);
    expect(SafeUrl.canOpen(''), isFalse);
  });

  test('HTML 链接不放行 tg，图片与视频只放行 http(s)', () {
    expect(SafeUrl.canOpenLink('https://example.com'), isTrue);
    expect(SafeUrl.canOpenLink('mailto:a@b.com'), isTrue);
    expect(SafeUrl.canOpenLink('tg://user?id=1'), isFalse);
    expect(SafeUrl.canOpenLink('weixin://wxpay/bizpayurl?pr=04IPMKM'), isFalse);
    expect(SafeUrl.canOpenLink('file:///etc/passwd'), isFalse);
    expect(SafeUrl.canLoad('https://cdn.example.com/a.png'), isTrue);
    expect(SafeUrl.canLoad('mailto:a@b.com'), isFalse);
    expect(SafeUrl.canLoad('data:image/svg+xml;base64,PHN2Zz4='), isFalse);
  });
}
