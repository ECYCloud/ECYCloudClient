import 'package:ecycloud_client/domain/config/local_template.dart';
import 'package:ecycloud_client/domain/config/profile_assembler.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> remoteProfile() => <String, dynamic>{
  'log': <String, dynamic>{'level': 'debug', 'output': 'sing-box.log'},
  'dns': <String, dynamic>{'servers': <Object>[], 'final': 'panel-dns'},
  'inbounds': <Object>[
    <String, dynamic>{'type': 'socks', 'tag': 'panel-socks'},
  ],
  'experimental': <String, dynamic>{
    'clash_api': <String, dynamic>{'external_controller': '127.0.0.1:9090'},
  },
  'ntp': <String, dynamic>{'enabled': true, 'server': 'time.apple.com'},
  'outbounds': <Object>[
    <String, dynamic>{'type': 'direct', 'tag': 'direct'},
    <String, dynamic>{'type': 'selector', 'tag': '主节点'},
  ],
  'route': <String, dynamic>{
    'rules': <Object>[
      <String, dynamic>{'action': 'sniff'},
    ],
    'rule_set': <Object>[
      <String, dynamic>{'tag': 'geoip-cn', 'type': 'remote'},
      <String, dynamic>{'tag': 'geosite-cn', 'type': 'remote'},
    ],
    'final': '主节点',
    'auto_detect_interface': false,
    'default_domain_resolver': <String, dynamic>{'server': 'panel-dns'},
  },
};

LocalTemplate template({bool tunEnabled = true, bool ipv6Enabled = true}) {
  return LocalTemplate(
    LocalTemplateOptions(
      tunEnabled: tunEnabled,
      tunStrictRoute: false,
      mixedPort: 12334,
      allowLan: false,
      ipv6Enabled: ipv6Enabled,
      logLevel: 'warn',
    ),
    const ClashApiOptions(port: 19090, secret: 'secret'),
    r'C:\ProgramData\ECYCloud\cache.db',
  );
}

void main() {
  const ProfileAssembler assembler = ProfileAssembler();

  test('面板的 outbounds 与 route 规则保留，并前置 ICMP 直连', () {
    final AssembledProfile profile = assembler.assemble(
      remote: remoteProfile(),
      template: template(),
    );

    expect(profile.outboundTags, <String>['direct', '主节点']);
    final Map<String, dynamic> route =
        profile.config['route'] as Map<String, dynamic>;
    expect(route['final'], '主节点');
    expect(
      route['rule_set'],
      isA<List<Object?>>().having((List<Object?> l) => l.length, '长度', 2),
    );
    final List<Object?> rules = route['rules'] as List<Object?>;
    expect(rules.first, <String, dynamic>{
      'network': 'icmp',
      'outbound': 'direct',
    });
    expect(rules.skip(1).toList(), <Object>[
      <String, dynamic>{'action': 'sniff'},
    ]);
  });

  test('已有 ICMP 规则时不重复插入、也不覆盖非 direct 目标', () {
    final Map<String, dynamic> remote = remoteProfile();
    (remote['route'] as Map<String, dynamic>)['rules'] = <Object>[
      <String, dynamic>{'network': 'icmp', 'outbound': 'wg-home'},
      <String, dynamic>{'action': 'sniff'},
    ];
    final Map<String, dynamic> route =
        assembler.assemble(remote: remote, template: template()).config['route']
            as Map<String, dynamic>;
    final List<Object?> routeRules = route['rules'] as List<Object?>;
    expect(routeRules.first, <String, dynamic>{
      'network': 'icmp',
      'outbound': 'wg-home',
    });
    expect(
      routeRules.whereType<Map<String, dynamic>>().where(
        (Map<String, dynamic> r) => r['network'] == 'icmp',
      ),
      hasLength(1),
    );
  });

  test('ws 出站剥掉 early data，其余传输配置不动', () {
    final Map<String, dynamic> remote = remoteProfile();
    (remote['outbounds'] as List<Object?>).add(<String, dynamic>{
      'type': 'vless',
      'tag': 'cdn',
      'server': 'cdn.example.com',
      'transport': <String, dynamic>{
        'type': 'ws',
        'path': '/ws',
        'max_early_data': 2048,
        'early_data_header_name': 'Sec-WebSocket-Protocol',
      },
    });
    (remote['outbounds'] as List<Object?>).add(<String, dynamic>{
      'type': 'vless',
      'tag': 'grpc',
      'transport': <String, dynamic>{'type': 'grpc', 'service_name': 'x'},
    });

    final List<Object?> outbounds =
        assembler
                .assemble(remote: remote, template: template())
                .config['outbounds']
            as List<Object?>;
    Map<String, dynamic> transportOf(String tag) =>
        (outbounds.whereType<Map<String, dynamic>>().firstWhere(
              (Map<String, dynamic> o) => o['tag'] == tag,
            )['transport']
            as Map<String, dynamic>);

    expect(transportOf('cdn'), <String, dynamic>{'type': 'ws', 'path': '/ws'});
    expect(transportOf('grpc'), <String, dynamic>{
      'type': 'grpc',
      'service_name': 'x',
    });
  });

  test('面板下发的 log / dns / inbounds / experimental 一律被本地模板替换', () {
    final AssembledProfile profile = assembler.assemble(
      remote: remoteProfile(),
      template: template(),
    );

    expect((profile.config['log'] as Map<String, dynamic>)['level'], 'warn');
    expect(
      (profile.config['log'] as Map<String, dynamic>).containsKey('output'),
      isFalse,
    );
    expect(
      (profile.config['dns'] as Map<String, dynamic>)['final'],
      TemplateTags.remoteDns,
    );
    expect(
      (profile.config['experimental'] as Map<String, dynamic>)['clash_api'],
      containsPair('external_controller', '127.0.0.1:19090'),
    );

    final List<Object?> inbounds = profile.config['inbounds'] as List<Object?>;
    final List<String> tags = <String>[
      for (final Object? inbound in inbounds)
        (inbound as Map<String, dynamic>)['tag'] as String,
    ];
    expect(tags, <String>[TemplateTags.tunInbound, TemplateTags.mixedInbound]);
  });

  test('远程 DNS 经默认出站，本地 DNS 直连且不带 detour', () {
    final Map<String, dynamic> dns =
        assembler
                .assemble(remote: remoteProfile(), template: template())
                .config['dns']
            as Map<String, dynamic>;

    final Map<String, Map<String, dynamic>> servers =
        <String, Map<String, dynamic>>{
          for (final Object? server in dns['servers'] as List<Object?>)
            (server as Map<String, dynamic>)['tag'] as String: server,
        };

    expect(servers[TemplateTags.remoteDns]!['detour'], '主节点');
    expect(servers[TemplateTags.localDns]!.containsKey('detour'), isFalse);
  });

  test('面板提供 geosite-cn 时国内域名分流到本地 DNS', () {
    final List<Object?> rules =
        (assembler
                    .assemble(remote: remoteProfile(), template: template())
                    .config['dns']
                as Map<String, dynamic>)['rules']
            as List<Object?>;

    expect(
      rules,
      contains(
        allOf(
          containsPair('rule_set', <String>['geosite-cn']),
          containsPair('server', TemplateTags.localDns),
        ),
      ),
    );
  });

  test('面板未提供 geosite-cn 时不生成国内分流规则', () {
    final Map<String, dynamic> withoutGeositeCn = remoteProfile();
    (withoutGeositeCn['route'] as Map<String, dynamic>)['rule_set'] =
        <Object>[];

    final List<Object?> rules =
        (assembler
                    .assemble(remote: withoutGeositeCn, template: template())
                    .config['dns']
                as Map<String, dynamic>)['rules']
            as List<Object?>;

    for (final Object? rule in rules) {
      expect((rule as Map<String, dynamic>).containsKey('rule_set'), isFalse);
    }
  });

  test('route 中依赖本地环境的字段由客户端覆盖', () {
    final Map<String, dynamic> route =
        assembler
                .assemble(remote: remoteProfile(), template: template())
                .config['route']
            as Map<String, dynamic>;

    expect(route['auto_detect_interface'], isTrue);
    expect(
      route['default_domain_resolver'],
      containsPair('server', TemplateTags.localDns),
    );
  });

  test('关闭 IPv6 也保留 TUN 的 IPv6 地址，并排除私有网段', () {
    final Map<String, dynamic> tun =
        (assembler
                        .assemble(
                          remote: remoteProfile(),
                          template: template(ipv6Enabled: false),
                        )
                        .config['inbounds']
                    as List<Object?>)
                .first
            as Map<String, dynamic>;

    expect((tun['address'] as List<Object?>).length, 2);
    expect(tun['route_exclude_address'], contains('192.168.0.0/16'));
    expect(tun['route_exclude_address'], contains('::1/128'));
  });

  test('关闭 TUN 后只保留混合入站', () {
    final AssembledProfile profile = assembler.assemble(
      remote: remoteProfile(),
      template: template(tunEnabled: false),
    );

    expect((profile.config['inbounds'] as List<Object?>).length, 1);
  });

  test('面板未下发节点或缺少 final 时拒绝生成配置', () {
    expect(
      () => assembler.assemble(
        remote: <String, dynamic>{'outbounds': <Object>[]},
        template: template(),
      ),
      throwsA(isA<ProfileAssemblyException>()),
    );

    final Map<String, dynamic> withoutFinal = remoteProfile()
      ..['route'] = <String, dynamic>{'rules': <Object>[]};
    expect(
      () => assembler.assemble(remote: withoutFinal, template: template()),
      throwsA(isA<ProfileAssemblyException>()),
    );
  });
}
