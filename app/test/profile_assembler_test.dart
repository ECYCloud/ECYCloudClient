import 'package:ecycloud_client/domain/config/local_template.dart';
import 'package:ecycloud_client/domain/config/profile_assembler.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> remoteProfile() => <String, dynamic>{
  'mixed-port': 7893,
  // 面板那份配置是给通用 Clash 客户端用的，另外三个入站端口它也写了实值
  'port': 7890,
  'socks-port': 7891,
  'redir-port': 7892,
  'allow-lan': true,
  'mode': 'global',
  'log-level': 'debug',
  'ipv6': true,
  'external-controller': '127.0.0.1:9090',
  'secret': 'panel-secret',
  'sniffer': <String, dynamic>{'enable': true},
  'ntp': <String, dynamic>{'enable': true, 'server': 'time.apple.com'},
  'hosts': <String, dynamic>{'example.test': '127.0.0.1'},
  'dns': <String, dynamic>{
    'enable': true,
    // 面板把内核当 DNS 服务器对外提供，本客户端不需要
    'listen': '0.0.0.0:1053',
    'nameserver': <String>['223.6.6.6'],
  },
  'tun': <String, dynamic>{'enable': false, 'device': 'panel-tun'},
  'proxies': <Object>[
    <String, dynamic>{
      'name': 'node-12',
      'type': 'trojan',
      'server': 'a.example.com',
      'port': 443,
      'password': 'p',
    },
  ],
  'proxy-groups': <Object>[
    <String, dynamic>{
      'name': '主节点',
      'type': 'select',
      'proxies': <String>['node-12', 'DIRECT'],
    },
  ],
  'rule-providers': <String, dynamic>{
    'geosite-cn': <String, dynamic>{
      'type': 'http',
      'behavior': 'domain',
      'format': 'mrs',
      'url': 'https://example.com/cn.mrs',
      'path': './rules/geosite-cn.mrs',
    },
    'local-list': <String, dynamic>{
      'type': 'file',
      'behavior': 'classical',
      'path': './rules/local.yaml',
    },
  },
  'rules': <String>['RULE-SET,geosite-cn,DIRECT', 'MATCH,主节点'],
};

LocalTemplate template({bool tunEnabled = true, bool ipv6Enabled = true}) {
  return LocalTemplate(
    LocalTemplateOptions(
      tunEnabled: tunEnabled,
      tunStrictRoute: false,
      mixedPort: 12334,
      allowLan: false,
      ipv6Enabled: ipv6Enabled,
      logLevel: 'warning',
    ),
    const ClashApiOptions(port: 19090, secret: 'secret'),
  );
}

void main() {
  const ProfileAssembler assembler = ProfileAssembler();

  test('面板独占的节点与分流段原样保留', () {
    final Map<String, dynamic> config = assembler
        .assemble(remote: remoteProfile(), template: template())
        .config;

    expect(config['proxies'], remoteProfile()['proxies']);
    expect(config['proxy-groups'], remoteProfile()['proxy-groups']);
    expect(config['rules'], <String>[
      'RULE-SET,geosite-cn,DIRECT',
      'MATCH,主节点',
    ]);
    expect(config['rule-providers'], remoteProfile()['rule-providers']);
  });

  test('面板维护的通用段不被客户端顶替', () {
    final Map<String, dynamic> config = assembler
        .assemble(remote: remoteProfile(), template: template())
        .config;

    expect(config['mode'], 'global');
    expect(config['ipv6'], isTrue);
    expect(config['sniffer'], containsPair('enable', true));
    expect(config['ntp'], containsPair('server', 'time.apple.com'));
    expect(config['hosts'], containsPair('example.test', '127.0.0.1'));
    expect(config['dns'], containsPair('nameserver', <String>['223.6.6.6']));
  });

  test('面板缺失的通用段由本地模板补默认值', () {
    final Map<String, dynamic> sparse = remoteProfile()
      ..remove('mode')
      ..remove('ipv6')
      ..remove('dns');

    final Map<String, dynamic> config = assembler
        .assemble(remote: sparse, template: template(ipv6Enabled: false))
        .config;

    expect(config['mode'], 'rule');
    expect(config['ipv6'], isFalse);
    expect(config['unified-delay'], isTrue);
    expect(config['dns'], containsPair('enhanced-mode', 'fake-ip'));
  });

  test('控制面与界面开关一律盖掉面板的值', () {
    final Map<String, dynamic> config = assembler
        .assemble(remote: remoteProfile(), template: template())
        .config;

    expect(config['external-controller'], '127.0.0.1:19090');
    expect(config['secret'], 'secret');
    expect(config['mixed-port'], 12334);
    expect(config['allow-lan'], isFalse);
    expect(config['bind-address'], '127.0.0.1');
    expect(config['log-level'], 'warning');
    expect(config['profile'], containsPair('store-selected', true));
  });

  test('只留 mixed-port 一个入站，面板写的另外几个端口一律关掉', () {
    final Map<String, dynamic> config = assembler
        .assemble(remote: remoteProfile(), template: template())
        .config;

    expect(config['mixed-port'], 12334);
    // 0 即不监听。照抄面板的 7890 会与用户机上别的 Clash 客户端撞车，
    // 且这些口界面从不显示、allow-lan 打开时还会跟着对局域网敞开
    for (final String key in const <String>[
      'port',
      'socks-port',
      'redir-port',
      'tproxy-port',
    ]) {
      expect(config[key], 0, reason: '$key 必须被关掉');
    }
  });

  test('面板的 dns 段保留，但独立 DNS 监听挖掉', () {
    final Map<String, dynamic> dns =
        assembler
                .assemble(remote: remoteProfile(), template: template())
                .config['dns']
            as Map<String, dynamic>;

    // 空串即不监听。0.0.0.0 会绕过 allow-lan 开关对局域网敞开
    expect(dns['listen'], '');
    // 面板那些有价值的键不能被连带丢掉
    expect(dns['nameserver'], <String>['223.6.6.6']);
    expect(dns['enable'], isTrue);
  });

  test('跨源一律收紧：名单不为空且关掉私有网络', () {
    final Map<String, dynamic> cors =
        assembler
                .assemble(
                  remote: <String, dynamic>{
                    ...remoteProfile(),
                    'external-controller-cors': <String, dynamic>{
                      'allow-origins': <String>['*'],
                      'allow-private-network': true,
                    },
                  },
                  template: template(),
                )
                .config['external-controller-cors']
            as Map<String, dynamic>;

    // 空列表在 cors 库里等于放开全部，这里必须点名一个来源
    expect(cors['allow-origins'], isNotEmpty);
    expect(cors['allow-origins'], isNot(contains('*')));
    expect(cors['allow-private-network'], isFalse);
  });

  test('允许局域网时监听地址随之放开', () {
    final LocalTemplate lan = LocalTemplate(
      const LocalTemplateOptions(
        tunEnabled: true,
        tunStrictRoute: false,
        mixedPort: 12334,
        allowLan: true,
        ipv6Enabled: true,
        logLevel: 'warning',
      ),
      const ClashApiOptions(port: 19090, secret: 'secret'),
    );

    final Map<String, dynamic> config = assembler
        .assemble(remote: remoteProfile(), template: lan)
        .config;

    expect(config['allow-lan'], isTrue);
    expect(config['bind-address'], '*');
  });

  test('TUN 段整体由客户端接管，面板的设置不残留', () {
    final Map<String, dynamic> tun =
        assembler
                .assemble(remote: remoteProfile(), template: template())
                .config['tun']
            as Map<String, dynamic>;

    expect(tun['enable'], isTrue);
    expect(tun['device'], 'ECYCloud');
    expect(tun['auto-route'], isTrue);
  });

  test('关闭 IPv6 也保留 TUN 的 IPv6 地址，并排除私有网段', () {
    final Map<String, dynamic> tun =
        assembler
                .assemble(
                  remote: remoteProfile(),
                  template: template(ipv6Enabled: false),
                )
                .config['tun']
            as Map<String, dynamic>;

    expect(tun['inet6-address'], hasLength(1));
    expect(tun['route-exclude-address'], contains('192.168.0.0/16'));
    expect(tun['route-exclude-address'], contains('::1/128'));
  });

  test('分应用名单落在 tun 段，未选模式时整键不出现', () {
    final Map<String, dynamic> off =
        assembler
                .assemble(remote: remoteProfile(), template: template())
                .config['tun']
            as Map<String, dynamic>;

    expect(off.containsKey('include-package'), isFalse);
    expect(off.containsKey('exclude-package'), isFalse);

    final LocalTemplate perApp = LocalTemplate(
      const LocalTemplateOptions(
        tunEnabled: true,
        tunStrictRoute: false,
        mixedPort: 12334,
        allowLan: false,
        ipv6Enabled: true,
        logLevel: 'warning',
        tunIncludePackages: <String>['com.example.one'],
      ),
      const ClashApiOptions(port: 19090, secret: 'secret'),
    );

    final Map<String, dynamic> included =
        assembler
                .assemble(remote: remoteProfile(), template: perApp)
                .config['tun']
            as Map<String, dynamic>;

    expect(included['include-package'], <String>['com.example.one']);
    expect(included.containsKey('exclude-package'), isFalse);
  });

  test('关闭 TUN 只改 enable，不删整段', () {
    final Map<String, dynamic> tun =
        assembler
                .assemble(
                  remote: remoteProfile(),
                  template: template(tunEnabled: false),
                )
                .config['tun']
            as Map<String, dynamic>;

    expect(tun['enable'], isFalse);
    expect(tun.containsKey('stack'), isTrue);
  });

  test('只把 http 类型的 provider 计入启动进度分母', () {
    final AssembledProfile profile = assembler.assemble(
      remote: remoteProfile(),
      template: template(),
    );

    expect(profile.remoteProviderCount, 1);
  });

  test('proxy-providers 与 rule-providers 一并计入分母', () {
    final Map<String, dynamic> remote = remoteProfile();
    remote['proxy-providers'] = <String, dynamic>{
      'sub': <String, dynamic>{'type': 'http', 'url': 'https://x/sub'},
      'local': <String, dynamic>{'type': 'file', 'path': './local.yaml'},
    };

    final AssembledProfile profile = assembler.assemble(
      remote: remote,
      template: template(),
    );

    expect(profile.remoteProviderCount, 2);
  });

  test('面板未下发节点或缺少分流规则时拒绝生成配置', () {
    expect(
      () => assembler.assemble(
        remote: <String, dynamic>{'proxies': <Object>[]},
        template: template(),
      ),
      throwsA(isA<ProfileAssemblyException>()),
    );

    final Map<String, dynamic> withoutRules = remoteProfile()..remove('rules');
    expect(
      () => assembler.assemble(remote: withoutRules, template: template()),
      throwsA(isA<ProfileAssemblyException>()),
    );
  });
}
