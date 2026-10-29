import 'dart:convert';

import 'package:ecycloud_client/domain/config/local_template.dart';
import 'package:ecycloud_client/domain/config/profile_assembler.dart';
import 'package:ecycloud_client/domain/config/profile_inspector.dart';
import 'package:ecycloud_client/domain/config/speed_probe_config.dart';
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
    'ipv6': true,
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
  'listeners': <Object>[
    <String, dynamic>{'name': 'panel-in', 'type': 'mixed', 'port': 10800},
  ],
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
  Map<String, dynamic> providerProfile() {
    final Map<String, dynamic> remote = remoteProfile();
    remote['proxy-providers'] = <String, dynamic>{
      'ecy-panel-nodes': <String, dynamic>{
        'type': 'file',
        'path': 'ecy-panel-nodes.json',
        'payload': remote['proxies'],
      },
    };
    remote['proxies'] = <Object>[];
    (remote['proxy-groups'] as List).first
      ..['proxies'] = <String>['DIRECT']
      ..['filter'] = r'^(?!DIRECT$).*`^DIRECT$'
      ..['use'] = <String>['ecy-panel-nodes'];
    return remote;
  }

  test('节点文件校验使用候选内容，选择恢复可引用节点文件成员', () {
    final Map<String, dynamic> remote = providerProfile();
    final AssembledProfile result = const ProfileAssembler().assemble(
      remote: remote,
      template: template(),
      selectorDefaults: <String, String>{'主节点': 'node-12'},
    );
    expect(ProfileInspector.inspect(remote), isEmpty);
    expect(
      AssembledProfile.membersOf(
        remote,
        (remote['proxy-groups'] as List).first as Map,
      ),
      <String>['node-12', 'DIRECT'],
    );
    expect(
      (result.config['proxy-groups'] as List).first['default-selected'],
      'node-12',
    );
    expect(result.config['proxy-providers']['ecy-panel-nodes']['type'], 'file');
    final Map validation = jsonDecode(result.validationJson) as Map;
    expect(validation['proxy-providers']['ecy-panel-nodes']['type'], 'inline');
    expect(
      validation['proxy-providers']['ecy-panel-nodes']['payload'],
      AssembledProfile.nodesOf(remote),
    );
  });

  test('仅节点变化允许独立更新，规则、DNS、组结构变化必须全量应用', () {
    final Map<String, dynamic> before = providerProfile();
    final Map<String, dynamic> after = providerProfile();
    after['proxy-providers']['ecy-panel-nodes']['payload'][0]['port'] = 8443;
    (after['proxy-groups'] as List).first['default-selected'] = 'DIRECT';
    expect(AssembledProfile.canUpdateNodes(before, after), isTrue);
    for (final String key in <String>['rules', 'dns', 'proxy-groups']) {
      final Map<String, dynamic> changed = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(after)) as Map,
      );
      if (key == 'rules') changed[key] = <String>['MATCH,DIRECT'];
      if (key == 'dns') changed[key]['enhanced-mode'] = 'fake-ip';
      if (key == 'proxy-groups') {
        (changed[key] as List).first['proxies'] = <String>['REJECT'];
      }
      expect(
        AssembledProfile.canUpdateNodes(before, changed),
        isFalse,
        reason: key,
      );
    }
    expect(AssembledProfile.canUpdateNodes(remoteProfile(), after), isFalse);
  });

  test('节点文件损坏、空内容与不存在的组订阅均拒绝', () {
    for (final String field in <String>['path', 'payload']) {
      final Map<String, dynamic> remote = providerProfile();
      remote['proxy-providers']['ecy-panel-nodes'][field] = field == 'path'
          ? 'other.json'
          : <Object>[];
      expect(ProfileInspector.inspect(remote), isNotEmpty);
    }
    final Map<String, dynamic> remote = providerProfile();
    (remote['proxy-groups'] as List).first['use'] = <String>['missing'];
    expect(ProfileInspector.inspect(remote), anyElement(contains('missing')));
  });

  test('面板不能启用额外入站服务和内核自管防火墙', () {
    final Map<String, dynamic> remote = remoteProfile()
      ..['iptables'] = <String, dynamic>{'enable': true}
      ..['ss-config'] = 'ss://aes-128-gcm:fixture@:18081'
      ..['vmess-config'] = 'vmess://fixture@:18082'
      ..['tuic-server'] = <String, dynamic>{
        'enable': true,
        'listen': '0.0.0.0:18083',
        'users': <String, String>{'fixture': 'fixture-password'},
      };
    final Map<String, dynamic> config = const ProfileAssembler()
        .assemble(remote: remote, template: template())
        .config;
    expect(config['ss-config'], '');
    expect(config['vmess-config'], '');
    expect(config['tuic-server'], <String, dynamic>{'enable': false});
    expect(config['iptables'], <String, dynamic>{'enable': false});
    expect(config['proxies'], remote['proxies']);
  });

  test('面板校时不能修改操作系统时钟', () {
    final Map<String, dynamic> remote = remoteProfile();
    remote['ntp'] = <String, dynamic>{
      'enable': true,
      'server': 'time.example.test',
      'write-to-system': true,
    };
    final AssembledProfile profile = const ProfileAssembler().assemble(
      remote: remote,
      template: template(),
    );
    expect(profile.config['ntp']['write-to-system'], isFalse);
    expect(profile.config['ntp']['server'], 'time.example.test');
    expect(remote['ntp']['write-to-system'], isTrue);
  });
  const ProfileAssembler assembler = ProfileAssembler();

  test('规则与节点订阅路径不能越界或覆盖客户端文件', () {
    for (final String section in <String>[
      'rule-providers',
      'proxy-providers',
    ]) {
      for (final String path in <String>[
        '../credentials.json',
        '/etc/shadow',
        r'C:\Windows\win.ini',
        r'..\credentials.json',
        'rules/../../config.json',
        'config.json',
        './CONFIG.JSON.bak',
        'cache.db',
        './proxy-snapshot.json',
        'rules/../config.json',
        'config.json.',
        'rules/nul.yaml',
        'rules/evil\u0000.mrs',
      ]) {
        final Map<String, dynamic> remote = remoteProfile();
        remote[section] = <String, dynamic>{
          'geosite-cn': <String, dynamic>{
            'type': 'http',
            'behavior': 'domain',
            'format': 'mrs',
            'url': 'https://example.com/rules.mrs',
            'path': path,
          },
        };
        expect(
          () => assembler.assemble(remote: remote, template: template()),
          throwsA(isA<ProfileFormatException>()),
          reason: '$section: $path',
        );
      }
    }
  });

  test('面板独占的节点与分流段原样保留', () {
    final Map<String, dynamic> config = assembler
        .assemble(remote: remoteProfile(), template: template())
        .config;

    expect(config['proxies'], remoteProfile()['proxies']);
    final List<dynamic> groups = config['proxy-groups'] as List<dynamic>;
    expect(groups.take(groups.length - 1), remoteProfile()['proxy-groups']);
    expect(groups.last, containsPair('name', SpeedProbeConfig.groupName));
    expect((groups.last as Map)['proxies'], <String>['DIRECT', 'node-12']);
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

    expect(config['sniffer'], containsPair('enable', true));
    expect(config['ntp'], containsPair('server', 'time.apple.com'));
    expect(config['hosts'], containsPair('example.test', '127.0.0.1'));
    expect(config['dns'], containsPair('nameserver', <String>['223.6.6.6']));
  });

  test('分流模式由客户端覆盖面板', () {
    expect(
      assembler
          .assemble(remote: remoteProfile(), template: template())
          .config['mode'],
      'rule',
    );

    final LocalTemplate global = LocalTemplate(
      const LocalTemplateOptions(
        tunEnabled: true,
        tunStrictRoute: false,
        mixedPort: 12334,
        allowLan: false,
        ipv6Enabled: true,
        logLevel: 'warning',
        routeMode: 'global',
      ),
      const ClashApiOptions(port: 19090, secret: 'secret'),
    );
    expect(
      assembler
          .assemble(remote: remoteProfile(), template: global)
          .config['mode'],
      'global',
    );
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
    expect(config['mode'], 'rule');
    expect(config['ipv6'], isTrue);
    expect(config['profile'], containsPair('store-selected', true));
  });

  test('只留 mixed-port 一个入站，面板写的另外几个端口一律关掉', () {
    final Map<String, dynamic> config = assembler
        .assemble(remote: remoteProfile(), template: template())
        .config;

    expect(config['mixed-port'], 12334);
    for (final String key in const <String>[
      'port',
      'socks-port',
      'redir-port',
      'tproxy-port',
    ]) {
      expect(config[key], 0, reason: '$key 必须被关掉');
    }
  });

  test('丢掉面板 listeners，只保留客户端回环测速入口', () {
    final Map<String, dynamic> config = assembler
        .assemble(remote: remoteProfile(), template: template())
        .config;
    final List<dynamic> listeners = config['listeners'] as List<dynamic>;
    expect(listeners, hasLength(1));
    expect(
      listeners.single,
      containsPair('name', SpeedProbeConfig.listenerName),
    );
    expect(listeners.single, containsPair('listen', '127.0.0.1'));
    expect(listeners.single, containsPair('proxy', SpeedProbeConfig.groupName));
    expect(config['tunnels'], isEmpty);
  });

  test('面板的 dns 段保留，但独立 DNS 监听挖掉', () {
    final Map<String, dynamic> dns =
        assembler
                .assemble(remote: remoteProfile(), template: template())
                .config['dns']
            as Map<String, dynamic>;

    expect(dns['listen'], '');
    expect(dns['ipv6'], isTrue);
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

  test('关闭 IPv6 盖掉面板，并保留 TUN 的 IPv6 地址', () {
    final Map<String, dynamic> config = assembler
        .assemble(
          remote: remoteProfile(),
          template: template(ipv6Enabled: false),
        )
        .config;
    final Map<String, dynamic> tun = config['tun'] as Map<String, dynamic>;
    final Map<String, dynamic> dns = config['dns'] as Map<String, dynamic>;

    expect(config['ipv6'], isFalse);
    expect(dns['ipv6'], isFalse);
    expect(tun['inet6-address'], hasLength(1));
    expect(tun['route-exclude-address'], contains('192.168.0.0/16'));
    expect(tun['route-exclude-address'], contains('::1/128'));
  });

  test('自定义 TUN 排除网段追加到内置列表', () {
    final LocalTemplate custom = LocalTemplate(
      const LocalTemplateOptions(
        tunEnabled: true,
        tunStrictRoute: false,
        mixedPort: 12334,
        allowLan: false,
        ipv6Enabled: true,
        logLevel: 'warning',
        tunExcludeAddresses: <String>['192.168.56.0/24', '10.0.0.0/8'],
      ),
      const ClashApiOptions(port: 19090, secret: 'secret'),
    );

    final Map<String, dynamic> tun =
        assembler
                .assemble(remote: remoteProfile(), template: custom)
                .config['tun']
            as Map<String, dynamic>;
    final List<dynamic> excluded =
        tun['route-exclude-address'] as List<dynamic>;

    expect(excluded, contains('192.168.56.0/24'));
    expect(
      excluded.where((Object? item) => item == '10.0.0.0/8'),
      hasLength(1),
    );
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

  test('用户上次选择写入 select 组的 default-selected，不改成员列表', () {
    final Map<String, dynamic> remote = remoteProfile();
    final AssembledProfile profile = assembler.assemble(
      remote: remote,
      template: template(),
      selectorDefaults: const <String, String>{'主节点': 'node-12'},
    );
    final Map<String, dynamic> group =
        (profile.config['proxy-groups'] as List<dynamic>).first
            as Map<String, dynamic>;
    expect(group['proxies'], <String>['node-12', 'DIRECT']);
    expect(group['default-selected'], 'node-12');
    expect(profile.config['profile'], containsPair('store-selected', false));
    expect(profile.config['profile'], containsPair('store-fake-ip', true));
    expect(
      (remote['proxy-groups'] as List<dynamic>).first,
      isNot(containsPair('default-selected', 'node-12')),
    );
  });

  test('校验副本隔离持久化地址池，运行配置及面板原文保持不变', () {
    final Map<String, dynamic> remote = remoteProfile();
    final String original = jsonEncode(remote);
    final AssembledProfile profile = assembler.assemble(
      remote: remote,
      template: template(),
    );
    final Map<String, dynamic> validation =
        jsonDecode(profile.validationJson) as Map<String, dynamic>;
    final Map<String, dynamic> runtime =
        jsonDecode(profile.json) as Map<String, dynamic>;

    expect(validation['profile'], containsPair('store-fake-ip', false));
    expect(runtime['profile'], containsPair('store-fake-ip', true));
    expect(profile.config['profile'], runtime['profile']);
    validation['profile'] = runtime['profile'];
    expect(validation, runtime);
    expect(jsonEncode(remote), original);
  });

  test('识别启用的 fake-IP 配置以避开全量热载', () {
    for (final String mode in <String>['fake-ip', 'FAKE-IP', 'redir-host']) {
      final Map<String, dynamic> remote = remoteProfile();
      (remote['dns'] as Map<String, dynamic>)['enhanced-mode'] = mode;
      final AssembledProfile profile = assembler.assemble(
        remote: remote,
        template: template(),
      );
      expect(profile.usesFakeIp, mode != 'redir-host');
      (remote['dns'] as Map<String, dynamic>)['enable'] = false;
      expect(
        assembler.assemble(remote: remote, template: template()).usesFakeIp,
        isFalse,
      );
    }
  });

  test('面板名称与内部测速名称冲突时在缓存前拒绝', () {
    for (final String section in <String>['proxies', 'proxy-groups']) {
      final Map<String, dynamic> remote = remoteProfile();
      (remote[section] as List).add(<String, dynamic>{
        'name': SpeedProbeConfig.groupName,
        'type': section == 'proxies' ? 'direct' : 'select',
        if (section == 'proxy-groups') 'proxies': <String>['DIRECT'],
      });
      expect(
        () => ProfileInspector.ensureValid(remote),
        throwsA(isA<ProfileFormatException>()),
      );
      expect(
        () => assembler.assemble(remote: remote, template: template()),
        throwsA(isA<ProfileAssemblyException>()),
      );
    }
  });

  test('default-selected 不是分组成员时不写入', () {
    final Map<String, dynamic> config = assembler
        .assemble(
          remote: remoteProfile(),
          template: template(),
          selectorDefaults: const <String, String>{'主节点': 'node-missing'},
        )
        .config;
    final Map<String, dynamic> group =
        (config['proxy-groups'] as List<dynamic>).first as Map<String, dynamic>;
    expect(group.containsKey('default-selected'), isFalse);
    expect(config['profile'], containsPair('store-selected', true));
  });

  test('面板未下发节点或缺少分流规则时拒绝生成配置', () {
    expect(
      () => assembler.assemble(
        remote: <String, dynamic>{'proxies': <Object>[]},
        template: template(),
      ),
      throwsA(isA<ProfileFormatException>()),
    );

    final Map<String, dynamic> withoutRules = remoteProfile()..remove('rules');
    expect(
      () => assembler.assemble(remote: withoutRules, template: template()),
      throwsA(isA<ProfileFormatException>()),
    );
  });

  test('规范的面板配置通过结构检查', () {
    expect(ProfileInspector.inspect(remoteProfile()), isEmpty);
  });

  test('规则引用不存在的 rule-providers 或策略时列出具体问题', () {
    final Map<String, dynamic> remote = remoteProfile();
    remote['rules'] = <String>[
      'RULE-SET,missing-set,DIRECT',
      'DOMAIN,example.com,不存在的组',
    ];

    final List<String> issues = ProfileInspector.inspect(remote);
    expect(issues, anyElement(contains('missing-set')));
    expect(issues, anyElement(contains('不存在的组')));
    expect(issues, anyElement(contains('兜底')));
  });

  test('classical 的 rule-providers 不能用 mrs', () {
    final Map<String, dynamic> remote = remoteProfile();
    (remote['rule-providers']
        as Map<String, dynamic>)['broken'] = <String, dynamic>{
      'type': 'http',
      'behavior': 'classical',
      'format': 'mrs',
      'url': 'https://example.com/a.mrs',
      'path': './rules/broken.mrs',
    };

    expect(ProfileInspector.inspect(remote), anyElement(contains('mrs')));
  });

  test('策略组成员必须指向已有节点或组', () {
    final Map<String, dynamic> remote = remoteProfile();
    remote['proxy-groups'] = <Object>[
      <String, dynamic>{
        'name': '主节点',
        'type': 'select',
        'proxies': <String>['no-such-node', 'DIRECT'],
      },
    ];

    expect(
      ProfileInspector.inspect(remote),
      anyElement(contains('no-such-node')),
    );
  });

  test('节点名重复或规则不是一行文字时列出具体问题', () {
    final Map<String, dynamic> remote = remoteProfile();
    (remote['proxies'] as List<Object>).add(<String, dynamic>{
      'name': 'node-12',
      'type': 'trojan',
      'server': 'b.example.com',
      'port': 443,
      'password': 'p',
    });
    remote['rules'] = <Object>['MATCH,主节点', 1];

    final List<String> issues = ProfileInspector.inspect(remote);
    expect(issues, anyElement(contains('node-12')));
    expect(issues, anyElement(contains('不是一行文字')));
  });
}
