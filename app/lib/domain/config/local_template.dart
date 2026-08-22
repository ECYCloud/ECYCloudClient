import 'network_bypass.dart';

class LocalTemplateOptions {
  const LocalTemplateOptions({
    required this.tunEnabled,
    required this.tunStrictRoute,
    required this.mixedPort,
    required this.allowLan,
    required this.ipv6Enabled,
    required this.logLevel,
    this.routeMode = 'rule',
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
    this.tunExcludeAddresses = const <String>[],
  });

  static const String defaultTunInterfaceName = 'ECYCloud';

  final bool tunEnabled;
  final bool tunStrictRoute;
  final int mixedPort;
  final bool allowLan;
  final bool ipv6Enabled;
  final String logLevel;
  final String routeMode;
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

  // 分应用代理走 tun 段而非 rules 的 process-name：rules 归面板所有，客户端不得往里塞
  final List<String> tunIncludePackages;
  final List<String> tunExcludePackages;
  final List<String> tunExcludeAddresses;
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

  Map<String, dynamic> get overrides => <String, dynamic>{
    'mixed-port': options.mixedPort,
    // 面板那份配置给通用 Clash 客户端用，port / socks-port / redir-port 都带实值；
    // 照抄就多开几个界面上不存在的代理口，allow-lan 时还对局域网敞开。0 即不监听
    'port': 0,
    'socks-port': 0,
    'redir-port': 0,
    'tproxy-port': 0,
    'mode': options.routeMode,
    'allow-lan': options.allowLan,
    'bind-address': options.allowLan ? '*' : '127.0.0.1',
    // 入站认证归客户端：界面上没有填代理口账号密码的地方，本机浏览器与系统代理
    // 也不会带上面板那组密码，而内核对回环不豁免（实测 127.0.0.1 也回 407）
    'authentication': const <String>[],
    // listeners 与 tunnels 能开出任意协议的入站口与端口转发，界面上没有这两项开关，
    // 面板下发就等于替用户开了看不见的监听
    'listeners': const <Map<String, dynamic>>[],
    'tunnels': const <Map<String, dynamic>>[],
    'log-level': options.logLevel,
    'external-controller': clashApi.externalController,
    'secret': clashApi.secret,
    // 控制面只留 127.0.0.1 上这一套 RESTful API。其余通道要么绕开 secret
    // （unix / pipe 靠文件权限），要么另开对外端口（tls / doh），一律关掉
    'external-controller-unix': '',
    'external-controller-pipe': '',
    'external-controller-tls': '',
    'external-doh-server': '',
    // 面板给了 external-ui 就会让内核以特权身份去下载并解压一个前端到运行目录，
    // 而客户端自己有界面，从不用它
    'external-ui': '',
    'external-ui-url': '',
    // 内核默认放开跨源，且 log-level 为 debug 时把不过鉴权的 pprof 挂在 /debug
    // （hub/route/server.go）；名单不能留空，空列表在 chi/cors 里等于放开全部
    'external-controller-cors': <String, dynamic>{
      'allow-origins': const <String>['http://127.0.0.1'],
      'allow-private-network': false,
    },
    'tun': tun,
    'profile': <String, dynamic>{
      'store-selected': true,
      'store-fake-ip': false,
    },
  };

  Map<String, dynamic> get fallbacks => <String, dynamic>{
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
    'route-exclude-address': appendUnique(
      excludedRoutes,
      options.tunExcludeAddresses,
    ),
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
    // 远程 DNS 走 DoH：明文查询会被污染，分流要靠解析结果判定 geoip
    'nameserver': <String>[options.remoteDnsServer],
    'proxy-server-nameserver': <String>[options.localDnsServer],
  };
}
