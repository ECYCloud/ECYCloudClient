class LocalTemplateOptions {
  const LocalTemplateOptions({
    required this.tunEnabled,
    required this.tunStrictRoute,
    required this.mixedPort,
    required this.allowLan,
    required this.ipv6Enabled,
    required this.logLevel,
    this.tunInterfaceName = 'ECYCloud',
    this.tunStack = 'mixed',
    this.tunMtu = 9000,
    this.tunAddress4 = '172.19.0.1/30',
    this.tunAddress6 = 'fdfe:dcba:9876::1/126',
    this.autoDetectInterface = true,
    this.remoteDnsServer = '1.1.1.1',
    this.localDnsServer = '223.5.5.5',
    this.tunIncludePackages = const <String>[],
    this.tunExcludePackages = const <String>[],
  });

  final bool tunEnabled;
  final bool tunStrictRoute;
  final int mixedPort;
  final bool allowLan;
  final bool ipv6Enabled;
  final String logLevel;
  final String tunInterfaceName;
  final String tunStack;
  final int tunMtu;
  final String tunAddress4;
  final String tunAddress6;
  final bool autoDetectInterface;

  // 必须是 IP，域名会在内核启动早期形成解析循环
  final String remoteDnsServer;
  final String localDnsServer;

  // 分应用代理走 tun 入站而非 route.rules 的 package_name：route 段归面板所有，
  // 客户端不得往里塞规则。两者互斥，同时非空时内核拒绝启动
  final List<String> tunIncludePackages;
  final List<String> tunExcludePackages;
}

class ClashApiOptions {
  const ClashApiOptions({
    required this.port,
    required this.secret,
    this.debugPort,
  });

  final int port;
  final String secret;

  // Clash API 不暴露 goroutine 数量，只有 experimental.debug 的独立监听口有；
  // 该端口无鉴权，只能绑 127.0.0.1
  final int? debugPort;

  String get externalController => '127.0.0.1:$port';

  String? get debugListen => debugPort == null ? null : '127.0.0.1:$debugPort';

  Uri get baseUri => Uri.parse('http://127.0.0.1:$port');

  Uri? get debugUri =>
      debugPort == null ? null : Uri.parse('http://127.0.0.1:$debugPort');
}

class TemplateTags {
  TemplateTags._();

  static const String remoteDns = 'dns-remote';
  static const String localDns = 'dns-local';
  static const String tunInbound = 'tun-in';
  static const String mixedInbound = 'mixed-in';
}

class LocalTemplate {
  const LocalTemplate(this.options, this.clashApi, this.cacheFilePath);

  final LocalTemplateOptions options;
  final ClashApiOptions clashApi;
  final String cacheFilePath;

  Map<String, dynamic> get log => <String, dynamic>{
    'disabled': false,
    'level': options.logLevel,
    'timestamp': true,
  };

  // sing-box 1.12+ 的 type + server 结构，address 写法已废弃
  Map<String, dynamic> dns({
    required String proxyTag,
    required List<String> domesticRuleSets,
  }) => <String, dynamic>{
    'servers': <Map<String, dynamic>>[
      // 远程 DNS 必须经代理：直连 DoH 常被阻断，且直连解析会被污染，
      // 而面板 route.rules 里的 resolve 动作要靠解析结果判定 geoip
      <String, dynamic>{
        'tag': TemplateTags.remoteDns,
        'type': 'https',
        'server': options.remoteDnsServer,
        'detour': proxyTag,
      },
      // 不写 detour：省略即为直连，指向面板的空 direct 出站会被内核判为无意义并拒绝启动
      <String, dynamic>{
        'tag': TemplateTags.localDns,
        'type': 'udp',
        'server': options.localDnsServer,
      },
    ],
    'rules': <Map<String, dynamic>>[
      <String, dynamic>{
        'clash_mode': 'Direct',
        'server': TemplateTags.localDns,
      },
      <String, dynamic>{
        'clash_mode': 'Global',
        'server': TemplateTags.remoteDns,
      },
      if (domesticRuleSets.isNotEmpty)
        <String, dynamic>{
          'rule_set': domesticRuleSets,
          'server': TemplateTags.localDns,
        },
    ],
    'final': TemplateTags.remoteDns,
    'strategy': options.ipv6Enabled ? 'prefer_ipv4' : 'ipv4_only',
    'independent_cache': true,
  };

  // auto_route 会让 TUN 接管默认路由，本机服务、局域网与组播（局域网联机、
  // 设备发现）随之被吸进隧道；排除后这些网段仍走物理网卡
  static const List<String> excludedRoutes = <String>[
    '127.0.0.0/8',
    '10.0.0.0/8',
    '172.16.0.0/12',
    '192.168.0.0/16',
    '169.254.0.0/16',
    '224.0.0.0/4',
    '::1/128',
    'fc00::/7',
    'fe80::/10',
    'ff00::/8',
  ];

  List<Map<String, dynamic>> get inbounds => <Map<String, dynamic>>[
    if (options.tunEnabled)
      <String, dynamic>{
        'type': 'tun',
        'tag': TemplateTags.tunInbound,
        'interface_name': options.tunInterfaceName,
        // IPv6 地址必须恒定下发：strict_route 在 TUN 缺少 IPv6 地址时会向 WFP
        // 注册一条全局 ALE_AUTH_CONNECT_V6 阻断规则，连 ::1 都不可达
        'address': <String>[options.tunAddress4, options.tunAddress6],
        'mtu': options.tunMtu,
        'stack': options.tunStack,
        'auto_route': true,
        'strict_route': options.tunStrictRoute,
        'route_exclude_address': excludedRoutes,
        if (options.tunIncludePackages.isNotEmpty)
          'include_package': options.tunIncludePackages,
        if (options.tunExcludePackages.isNotEmpty)
          'exclude_package': options.tunExcludePackages,
      },
    <String, dynamic>{
      'type': 'mixed',
      'tag': TemplateTags.mixedInbound,
      'listen': options.allowLan ? '::' : '127.0.0.1',
      'listen_port': options.mixedPort,
    },
  ];

  Map<String, dynamic> get experimental => <String, dynamic>{
    'clash_api': <String, dynamic>{
      'external_controller': clashApi.externalController,
      'secret': clashApi.secret,
      'default_mode': 'Rule',
    },
    if (clashApi.debugListen != null)
      'debug': <String, dynamic>{'listen': clashApi.debugListen},
    'cache_file': <String, dynamic>{
      'enabled': true,
      'path': cacheFilePath,
      'store_fakeip': false,
      'store_rdrc': true,
    },
  };

  Map<String, dynamic> get routeOverrides => <String, dynamic>{
    'auto_detect_interface': options.autoDetectInterface,
    'default_domain_resolver': <String, dynamic>{
      'server': TemplateTags.localDns,
    },
  };
}
