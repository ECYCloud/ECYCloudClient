import 'dart:convert';

import 'local_template.dart';

class ProfileAssemblyException implements Exception {
  ProfileAssemblyException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AssembledProfile {
  const AssembledProfile(this.config, this.json);

  final Map<String, dynamic> config;
  final String json;

  List<String> get outboundTags => <String>[
    for (final Object? outbound in config['outbounds'] as List<Object?>)
      if (outbound is Map<String, dynamic> && outbound['tag'] is String)
        outbound['tag'] as String,
  ];

  // 首次启动要逐个下载并编译远程规则集，这是等待时间的主要来源，
  // 数量取自配置本身，用来给启动进度提供分母
  int get remoteRuleSetCount {
    final Object? route = config['route'];
    final Object? ruleSets = route is Map<String, dynamic>
        ? route['rule_set']
        : null;
    if (ruleSets is! List) {
      return 0;
    }

    return ruleSets
        .whereType<Map<String, dynamic>>()
        .where((Map<String, dynamic> set) => set['type'] == 'remote')
        .length;
  }
}

class ProfileAssembler {
  const ProfileAssembler();

  static const Set<String> panelOwnedRouteKeys = <String>{
    'rules',
    'rule_set',
    'final',
  };

  // 国内域名分流到本地 DNS 要复用面板下发的规则集，这是 sing-box 生态的约定 tag
  static const Set<String> domesticRuleSetTags = <String>{'geosite-cn'};

  AssembledProfile assemble({
    required Map<String, dynamic> remote,
    required LocalTemplate template,
  }) {
    final Object? outbounds = remote['outbounds'];
    if (outbounds is! List || outbounds.isEmpty) {
      throw ProfileAssemblyException('面板未下发任何可用节点');
    }

    final Map<String, dynamic> route = _route(remote, template);

    final Map<String, dynamic> config = <String, dynamic>{
      r'$schema': 'https://sing-box.sagernet.org/schema.json',
      'log': template.log,
      'dns': template.dns(
        proxyTag: route['final'] as String,
        domesticRuleSets: _domesticRuleSets(route),
      ),
      'inbounds': template.inbounds,
      'outbounds': _withoutWebsocketEarlyData(outbounds),
      'route': route,
      'experimental': template.experimental,
    };

    final Object? ntp = remote['ntp'];
    if (ntp is Map<String, dynamic>) {
      config['ntp'] = ntp;
    }

    return AssembledProfile(
      config,
      const JsonEncoder.withIndent('  ').convert(config),
    );
  }

  // ws 的 early data 会把 TCP、TLS、WebSocket Upgrade 全部推迟到首次写入：
  // max_early_data > 0 时 DialContext 直接返回一个空的 EarlyWebsocketConn
  // （sing-box transport/v2raywebsocket/client.go）。
  //
  // 而内核测延迟的口径是「拨号完成后重置计时，再发一次 HEAD」
  // （common/urltest/urltest.go 的 NeedHandshakeForWrite 分支）：普通节点的
  // TCP + TLS 握手发生在拨号阶段、不计入，early data 节点的这些握手全落在计时窗口里，
  // 其中 WebSocket Upgrade 还要经 CDN 边缘回源站，等于多算了两三个往返。
  // 表现就是同一批节点里套 CDN 的那些延迟高出几倍，urltest 也永远不会选中它们。
  //
  // 代价是真实连接少了 early data 省下的那一个往返，换来各节点延迟同口径、自动选择可用。
  static List<Object?> _withoutWebsocketEarlyData(List<Object?> outbounds) =>
      <Object?>[
        for (final Object? outbound in outbounds)
          if (outbound is Map<String, dynamic> &&
              outbound['transport'] is Map<String, dynamic> &&
              (outbound['transport'] as Map<String, dynamic>)['type'] == 'ws')
            <String, dynamic>{
              ...outbound,
              'transport':
                  <String, dynamic>{
                    ...outbound['transport'] as Map<String, dynamic>,
                  }..removeWhere(
                    (String key, _) => const <String>{
                      'max_early_data',
                      'early_data_header_name',
                    }.contains(key),
                  ),
            }
          else
            outbound,
      ];

  Map<String, dynamic> _route(
    Map<String, dynamic> remote,
    LocalTemplate template,
  ) {
    final Object? remoteRoute = remote['route'];
    final Map<String, dynamic> route = <String, dynamic>{};

    if (remoteRoute is Map<String, dynamic>) {
      for (final String key in panelOwnedRouteKeys) {
        if (remoteRoute.containsKey(key)) {
          route[key] = remoteRoute[key];
        }
      }
    }

    if (route['final'] is! String) {
      throw ProfileAssemblyException('面板配置缺少 route.final，无法确定默认出站');
    }

    return route..addAll(template.routeOverrides);
  }

  List<String> _domesticRuleSets(Map<String, dynamic> route) {
    final Object? ruleSets = route['rule_set'];
    if (ruleSets is! List) {
      return const <String>[];
    }

    return <String>[
      for (final Object? ruleSet in ruleSets)
        if (ruleSet is Map<String, dynamic> &&
            domesticRuleSetTags.contains(ruleSet['tag']))
          ruleSet['tag'] as String,
    ];
  }
}
