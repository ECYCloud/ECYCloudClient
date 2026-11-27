import 'package:ecycloud_client/domain/kernel/clash_api_client.dart';
import 'package:ecycloud_client/state/connection_controller.dart';
import 'package:flutter_test/flutter_test.dart';

// 内核拨号失败日志只带策略组名，客户端要补出实际节点，用户上传的运行日志才能定位到节点
void main() {
  const List<ProxyGroup> groups = <ProxyGroup>[
    ProxyGroup(
      name: 'Google服务',
      type: 'Selector',
      now: '主节点',
      members: <String>['主节点', 'DIRECT'],
    ),
    ProxyGroup(
      name: '主节点',
      type: 'Selector',
      now: 'node-hk-1',
      members: <String>['node-hk-1', 'node-hk-2', '自动选择'],
    ),
    ProxyGroup(
      name: '自动选择',
      type: 'URLTest',
      now: 'node-hk-2',
      members: <String>['node-hk-1', 'node-hk-2'],
    ),
    ProxyGroup(
      name: '流媒体',
      type: 'Selector',
      now: '自动选择',
      members: <String>['自动选择'],
    ),
  ];
  const Map<String, List<String>> endpoints = <String, List<String>>{
    'chtcht.ecydns.com:10002': <String>['node-hk-1'],
    'shared.example.test:443': <String>['node-hk-1', 'node-hk-2'],
  };

  String annotate(String message) =>
      ConnectionController.dialNode(message, groups, endpoints);

  test('报错带节点地址时按地址补出节点', () {
    expect(
      annotate(
        '[UDP] dial Google服务 (match RuleSet/google) 172.19.0.1:56589 --> '
        'taskassist-pa.googleapis.com:443 error: chtcht.ecydns.com:10002 '
        'connect error: context deadline exceeded',
      ),
      '[UDP] dial Google服务 → node-hk-1 (match RuleSet/google) '
      '172.19.0.1:56589 --> taskassist-pa.googleapis.com:443 error: '
      'chtcht.ecydns.com:10002 connect error: context deadline exceeded',
    );
  });

  test('地址大小写不同也能对上', () {
    expect(
      annotate(
        '[TCP] dial 主节点 (match Match/) 172.19.0.1:47670 --> '
        'hermes.twitch.tv:443 error: CHTCHT.ecydns.com:10002 connect error: '
        'context deadline exceeded',
      ),
      startsWith('[TCP] dial 主节点 → node-hk-1 (match Match/)'),
    );
  });

  test('多个节点共用地址时取选中链上的节点', () {
    expect(
      annotate(
        '[TCP] dial 主节点 (match Match/) 1.1.1.1:1 --> a.test:443 error: '
        'shared.example.test:443 connect error: EOF',
      ),
      startsWith('[TCP] dial 主节点 → node-hk-1 '),
    );
  });

  test('共用地址又分不出节点时保持原样', () {
    const String raw =
        '[TCP] dial 流媒体 (match Match/) 1.1.1.1:1 --> a.test:443 error: '
        'shared.example.test:443 connect error: EOF';
    expect(annotate(raw), raw);
  });

  test('报错不带地址时沿手动选择组找到节点', () {
    expect(
      annotate(
        '[TCP] dial Google服务 (match RuleSet/google) 1.1.1.1:1 --> '
        'a.test:443 error: context deadline exceeded',
      ),
      startsWith('[TCP] dial Google服务 → node-hk-1 (match'),
    );
  });

  test('遇到自动测速组停在组名，不猜可能已过时的选中节点', () {
    expect(
      annotate(
        '[TCP] dial 流媒体 (match Match/) 1.1.1.1:1 --> a.test:443 error: '
        'context deadline exceeded',
      ),
      startsWith('[TCP] dial 流媒体 → 自动选择 (match'),
    );
  });

  test('直连、无规则与非拨号日志保持原样', () {
    for (final String raw in <String>[
      '[TCP] dial DIRECT (match GeoIP/cn) 172.19.0.1:51882 --> '
          '116.130.175.194:13861 error: dial tcp 116.130.175.194:13861: '
          'i/o timeout',
      '[TCP] dial 未知组 1.1.1.1:1 --> a.test:443 error: EOF',
      '[TCP] 1.1.1.1:1 --> a.test:443 match Match using 主节点 → node-hk-1',
    ]) {
      expect(annotate(raw), raw);
    }
  });

  test('没有匹配规则的拨号失败同样补出节点', () {
    expect(
      annotate(
        '[TCP] dial 主节点 1.1.1.1:1 --> a.test:443 error: '
        'chtcht.ecydns.com:10002 connect error: EOF',
      ),
      '[TCP] dial 主节点 → node-hk-1 1.1.1.1:1 --> a.test:443 error: '
      'chtcht.ecydns.com:10002 connect error: EOF',
    );
  });
}
