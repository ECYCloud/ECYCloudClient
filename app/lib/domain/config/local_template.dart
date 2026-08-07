class LocalTemplateOptions {
  const LocalTemplateOptions({
    required this.tunEnabled,
    required this.tunStrictRoute,
    required this.mixedPort,
    required this.allowLan,
    required this.ipv6Enabled,
    required this.logLevel,
    this.tunInterfaceName = defaultTunInterfaceName,
    this.tunStack = 'mixed',
    this.tunMtu = 9000,
    this.tunAddress4 = '172.19.0.1/30',
    this.tunAddress6 = 'fdfe:dcba:9876::1/126',
    this.autoDetectInterface = true,
    this.remoteDnsServer = 'https://1.1.1.1/dns-query',
    this.localDnsServer = '223.5.5.5',
    this.tunIncludePackages = const <String>[],
    this.tunExcludePackages = const <String>[],
  });

  static const String defaultTunInterfaceName = 'ECYCloud';

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

  // 兜底 DNS，仅在面板没下发 dns 段时使用。default-nameserver 必须是纯 IP，
  // 否则解析 nameserver 里的域名时会形成循环
  final String remoteDnsServer;
  final String localDnsServer;

  // 分应用代理走 tun 段而非 rules 的 process-name：rules 归面板所有，客户端不得
  // 往里塞规则。仅 Android 有值，由 BoxService 翻成 VpnService.Builder 的名单
  final List<String> tunIncludePackages;
  final List<String> tunExcludePackages;
}

class ClashApiOptions {
  const ClashApiOptions({required this.port, required this.secret});

  final int port;
  final String secret;

  String get externalController => '127.0.0.1:$port';

  Uri get baseUri => Uri.parse('http://127.0.0.1:$port');
}

class LocalTemplate {
  const LocalTemplate(this.options, this.clashApi);

  final LocalTemplateOptions options;
  final ClashApiOptions clashApi;

  // auto-route 会让 TUN 接管默认路由，本机服务、局域网与组播（局域网联机、
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

  /// 界面开关与控制面参数，面板给了也要盖掉
  Map<String, dynamic> get overrides => <String, dynamic>{
    'mixed-port': options.mixedPort,
    // 内核的另外四个入站端口一律关掉（0 即不监听）。面板那份配置是给通用 Clash 客户端
    // 用的，里面写着 port: 7890 / socks-port: 7891 / redir-port: 7892，照抄下来内核就会
    // 多开几个界面从不显示、用户也没同意的代理口：7890 还正好是整个 Clash 生态的默认口，
    // 与用户机上别的客户端撞车；allow-lan 打开时它们跟着 bind-address 一起对局域网敞开。
    // 本客户端只认 mixed-port 这一个，系统代理与界面文案都按它来
    'port': 0,
    'socks-port': 0,
    'redir-port': 0,
    'tproxy-port': 0,
    'allow-lan': options.allowLan,
    'bind-address': options.allowLan ? '*' : '127.0.0.1',
    'log-level': options.logLevel,
    'external-controller': clashApi.externalController,
    'secret': clashApi.secret,
    // 内核默认放开跨源（allow-origins: ["*"]、allow-private-network: true），而
    // log-level 为 debug 时它会把 pprof 挂在 /debug 且**不过鉴权**（hub/route/server.go
    // 的 router 把 /debug 挂在鉴权分组之外，IsDebug 取自日志级别）。两者叠加时，用户
    // 随手打开的网页就能跨源读到堆与 goroutine 转储，里面带着 secret 与节点凭据。
    // 本客户端不是浏览器、从不发 Origin，收紧它没有代价；名单不能留空，空列表在
    // cors 库里等于放开全部（chi/cors 的 allowedOriginsAll）
    'external-controller-cors': <String, dynamic>{
      'allow-origins': const <String>['http://127.0.0.1'],
      'allow-private-network': false,
    },
    'tun': tun,
    // 选中项与 fake-ip 映射落在 -d 目录的 cache.db，重启后各策略组能回到上次的选择
    'profile': <String, dynamic>{
      'store-selected': true,
      'store-fake-ip': false,
    },
  };

  /// 面板缺失时才注入的默认值
  Map<String, dynamic> get fallbacks => <String, dynamic>{
    'mode': 'rule',
    'ipv6': options.ipv6Enabled,
    'unified-delay': true,
    'tcp-concurrent': true,
    'dns': dns,
  };

  Map<String, dynamic> get tun => <String, dynamic>{
    'enable': options.tunEnabled,
    'stack': options.tunStack,
    'device': options.tunInterfaceName,
    'auto-route': true,
    'auto-detect-interface': options.autoDetectInterface,
    'strict-route': options.tunStrictRoute,
    'mtu': options.tunMtu,
    'dns-hijack': const <String>['any:53'],
    'inet4-address': <String>[options.tunAddress4],
    // IPv6 地址必须恒定下发：strict-route 在 TUN 缺少 IPv6 地址时会向 WFP
    // 注册一条全局阻断规则，连 ::1 都不可达
    'inet6-address': <String>[options.tunAddress6],
    'route-exclude-address': excludedRoutes,
    if (options.tunIncludePackages.isNotEmpty)
      'include-package': options.tunIncludePackages,
    if (options.tunExcludePackages.isNotEmpty)
      'exclude-package': options.tunExcludePackages,
  };

  Map<String, dynamic> get dns => <String, dynamic>{
    'enable': true,
    'ipv6': options.ipv6Enabled,
    'enhanced-mode': 'fake-ip',
    'fake-ip-range': '198.18.0.1/16',
    'default-nameserver': <String>[options.localDnsServer],
    // 远程 DNS 走 DoH：明文查询会被污染，而分流要靠解析结果判定 geoip
    'nameserver': <String>[options.remoteDnsServer],
    'proxy-server-nameserver': <String>[options.localDnsServer],
  };
}
