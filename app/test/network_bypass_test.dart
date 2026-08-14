import 'package:ecycloud_client/domain/config/network_bypass.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('系统代理默认绕过按平台给出既有列表', () {
    expect(defaultSystemProxyBypass('windows'), contains('<local>'));
    expect(defaultSystemProxyBypass('windows'), contains('169.254.*'));
    expect(defaultSystemProxyBypass('macos'), contains('*.local'));
    expect(defaultSystemProxyBypass('linux'), contains('127.0.0.0/8'));
  });

  test('自定义绕过追加到默认列表且去重', () {
    final List<String> resolved = resolvedSystemProxyBypass('windows', <String>[
      'example.com',
      'localhost',
      ' 192.168.56.* ',
    ]);
    expect(resolved, contains('example.com'));
    expect(resolved, contains('192.168.56.*'));
    expect(resolved.where((String item) => item == 'localhost'), hasLength(1));
  });

  test('CIDR 只接受带前缀长度的 IPv4/IPv6', () {
    expect(isIpCidr('192.168.56.0/24'), isTrue);
    expect(isIpCidr('fd00::/8'), isTrue);
    expect(isIpCidr('::1/128'), isTrue);
    expect(isIpCidr('192.168.56.0'), isFalse);
    expect(isIpCidr('192.168.56.*'), isFalse);
    expect(isIpCidr('example.com'), isFalse);
    expect(isIpCidr('10.0.0.0/33'), isFalse);
  });

  test('逗号分号换行都能拆成多条', () {
    expect(splitNetworkSegments('a;b, c\nd'), <String>['a', 'b', 'c', 'd']);
  });
}
