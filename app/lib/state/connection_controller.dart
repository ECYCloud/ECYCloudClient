import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart'
    show AppLifecycleState, ThemeMode, WidgetsBinding, WidgetsBindingObserver;

import '../core/app_paths.dart';
import '../core/logger.dart';
import '../data/api/api_exception.dart';
import '../data/api/panel_api_client.dart';
import '../data/models/online_device.dart';
import '../data/models/user_profile.dart';
import '../data/store/json_file_store.dart';
import '../data/store/panel_response_cache.dart';
import '../data/store/settings_store.dart';
import '../data/store/speed_test_quota_store.dart';
import '../data/store/traffic_rank_store.dart';
import '../domain/config/local_template.dart';
import '../domain/config/network_bypass.dart';
import '../domain/config/node_catalog.dart';
import '../domain/config/node_working_set.dart';
import '../domain/config/profile_assembler.dart';
import '../domain/config/profile_inspector.dart';
import '../domain/config/speed_probe_config.dart';
import '../domain/kernel/clash_api_client.dart';
import '../domain/kernel/kernel_controller.dart';
import '../domain/kernel/kernel_update.dart';
import '../domain/kernel/node_speed_tester.dart';
import '../domain/platform/platform_service.dart';
import '../l10n/app_language.dart';
import '../l10n/l10n.dart';
import '../ui/node_labels.dart';

class RuleProviderRef {
  const RuleProviderRef({
    required this.name,
    required this.relativePath,
    this.format = '',
  });

  final String name;
  final String relativePath;
  final String format;
}

// 不叫 ConnectionState，避免与 Flutter 的同名枚举冲突
enum ConnectionPhase {
  disconnected,
  connecting,
  connected,
  disconnecting,
  failed,
}

typedef _Catalog = ({
  Map<String, dynamic> source,
  Map<String, Map<String, dynamic>> configs,
  List<ProxyNode> nodes,
  Map<String, List<String>> members,
  // 分页模式下各分组所用节点文件的目录条目，以及成员里不归目录管的个数（DIRECT、其它分组、模板里写死的节点）
  Map<String, CatalogProvider> files,
  Map<String, int> extras,
});

class _NodePaging {
  _NodePaging(this.offset, this.more);

  int offset;
  bool more;
  bool loading = false;
  String? error;
  String query = '';
  String? queued;
  int searchOffset = 0;
  bool searchMore = false;
  final Set<String> hits = <String>{};
}

class ConnectionController extends ChangeNotifier with WidgetsBindingObserver {
  // 命名参数不能写成 this._field，只能在初始化列表里赋值
  // ignore_for_file: prefer_initializing_formals
  ConnectionController({
    required PlatformService platform,
    required KernelController kernel,
    required SettingsStore settingsStore,
    PanelResponseCache? panelCache,
    NodeSpeedTester? speedTester,
  }) : _platform = platform,
       _kernel = kernel,
       _settingsStore = settingsStore,
       _settings = settingsStore.load(),
       _panelCache = panelCache ?? PanelResponseCache(),
       _speedTester = speedTester ?? NodeSpeedTester(),
       _selectorCache = JsonFileStore(AppPaths.selectorCache, 'selector-cache'),
       _trafficRank = TrafficRankStore(),
       _speedQuota = SpeedTestQuotaStore() {
    WidgetsBinding.instance.addObserver(this);
    _routeMode = _settings.routeMode;
    _kernelStatusSubscription = _kernel.statusStream.listen(_onKernelStatus);
    _kernelLogSubscription = _kernel.kernelLog.listen((String line) {
      if (_clearingSession) {
        return;
      }
      Logger.instance.log(
        Logger.kernelLevel(line),
        'mihomo',
        NodeLabels.annotateText(Logger.kernelChain(Logger.kernelMessage(line))),
      );
      _trackStartupStage(line);
    });
    // Android 没有托盘，但通知栏磁贴同样从界面之外请求连接/断开
    _trayActionSubscription = _platform.trayActions.listen(_onTrayAction);
    if (_platform.supportsTray) {
      addListener(_syncTray);
    }
    // TUN 是该平台唯一的接管方式时，关掉它等于连上也不走流量，不给出这个状态
    if (_platform.requiresTun && !_settings.tunEnabled) {
      _settings = _settings.copyWith(tunEnabled: true);
      _settingsStore.save(_settings);
    }
  }

  static const String _source = 'connection';
  // 与 Website ClientApiRateLimit 一致：60s/10 次；缺 Retry-After 时的退避兜底
  static const Duration _rateLimitFallback = Duration(seconds: 6);
  // 与面板 /link/ 订阅响应头 profile-update-interval: 24 保持一致
  static const Duration _defaultProfileUpdateInterval = Duration(hours: 24);
  static const List<Duration> _backoff = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
    Duration(seconds: 30),
  ];

  final PlatformService _platform;
  final KernelController _kernel;
  final SettingsStore _settingsStore;
  final PanelResponseCache _panelCache;
  final JsonFileStore _selectorCache;
  final TrafficRankStore _trafficRank;
  final SpeedTestQuotaStore _speedQuota;
  final NodeSpeedTester _speedTester;

  late StreamSubscription<KernelStatus> _kernelStatusSubscription;
  late StreamSubscription<String> _kernelLogSubscription;
  StreamSubscription<TrayAction>? _trayActionSubscription;
  Timer? _restartTimer;
  Timer? _proxyRefreshTimer;
  Timer? _sysProxyGuardTimer;
  Timer? _statsTimer;
  TrayState? _trayState;

  AppSettings _settings;
  ConnectionPhase _state = ConnectionPhase.disconnected;
  String? _error;
  String? _startupStage;
  String? _formatError;
  String? _lastConfigAlert;
  List<String> _preflightProblems = const <String>[];

  PanelApiClient? _api;
  ClashApiClient? _clash;
  UserProfile? Function()? _profileOf;

  /// 返回用户选定要挤下线的设备 ID；返回 null 表示取消连接，空串表示交给节点挑最旧的
  Future<String?> Function(List<OnlineDevice> devices)? confirmDeviceLimitKick;

  void Function(String message)? onConfigAlert;

  Map<String, dynamic>? _remote;
  RemoteProfile? _remoteProfile;
  bool _remotePending = false;
  bool _panelOffline = false;
  bool _panelSyncInFlight = false;
  Timer? _panelSyncTimer;
  Timer? _authorizationTimer;
  Future<void> Function()? onPanelSync;
  Future<void> Function()? onSessionRejected;
  Map<String, String> _proxyNetwork = const <String, String>{};
  Map<String, bool> _proxyUdp = const <String, bool>{};
  Map<String, String> _proxyTls = const <String, String>{};
  Set<String> _proxyServers = const <String>{};
  Map<String, String> _groupIcons = const <String, String>{};
  AssembledProfile? _profile;
  ClashApiOptions? _clashApiOptions;
  Future<void>? _adoption;
  String _configRevision = '';
  DateTime? _connectedAt;

  List<ProxyGroup> _groups = const <ProxyGroup>[];
  List<ProxyNode> _nodes = const <ProxyNode>[];
  // 面板节点超过内核装载上限时实际装入内核的那部分；null 表示全部装入
  Set<String>? _loadedNodes;
  // 用户选过的节点，最近的在前：超出上限时优先留在内核里
  final List<String> _recentNodes = <String>[];
  static const int _recentNodeLimit = 200;
  static const int _probeBatch = 64;
  _Catalog? _catalog;
  // 分页模式下翻页、搜索取到的节点：只供界面列出，用到时才并入面板配置；最近取到的排在后面
  final Map<String, CatalogNode> _browsed = <String, CatalogNode>{};
  static const int _browsedLimit = 2000;
  static const int _nodePageSize = 100;
  static const int _nodeNamesLimit = 500;
  final Map<String, _NodePaging> _paging = <String, _NodePaging>{};
  Map<String, dynamic>? _listed;
  Map<String, dynamic>? _listedSource;
  // _acceptRemote 刚让内核校验过的那份面板配置及当时的接管状态、设置：紧接着的热载或启动装配的是同一份，
  // 再校验一遍只是把等待翻倍（5000 个节点副本校验一次约 10 秒）
  ({Map<String, dynamic> remote, bool takeover, AppSettings settings})?
  _validated;
  // 内核用手上这份面板配置没能启动：下次连接先向面板核对，不再因为缓存「离线可用」就原样重试
  bool _remoteFailed = false;
  // 探测节点文件里的节点：未装入的节点测延迟、测速时临时放这里，不动分组用的节点文件
  List<Object?> _probeNodes = const <Object?>[];
  final Map<String, int> _delays = <String, int>{};
  final Set<String> _testing = <String>{};
  final Set<String> _testingGroups = <String>{};
  final Set<String> _unreachable = <String>{};
  final Map<String, int> _speeds = <String, int>{};
  final Set<String> _testingSpeeds = <String>{};
  Future<void> _speedLane = Future<void>.value();
  final Set<String> _testingSpeedGroups = <String>{};
  final Set<String> _speedFailed = <String>{};
  TrafficSample _traffic = const TrafficSample(0, 0);
  TrafficSample _trafficTotal = const TrafficSample(0, 0);
  DateTime? _trafficSampledAt;
  bool _pollingStats = false;
  final List<TrafficSample> _trafficHistory = <TrafficSample>[];
  final ValueNotifier<int> _statsUpdates = ValueNotifier<int>(0);
  KernelStats _stats = KernelStats.empty;
  List<Map<String, dynamic>> _connections = const <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> _closedConnections =
      <Map<String, dynamic>>[];
  String _routeMode = 'rule';

  bool _userStopped = true;
  // 内核常驻，界面上的「连接」只切换出口接管（TUN + 系统代理）。未接管时内核照样
  // 在跑、控制面照样在线，选节点与测延迟因此不需要先连接
  bool _takeover = false;
  bool _background = false;
  int _restartAttempt = 0;
  bool _tunRouteRepairing = false;
  int _tunRouteRepairs = 0;
  Timer? _autoConnectTimer;
  int _autoConnectAttempt = 0;
  bool _profileRefreshInFlight = false;
  // 面板对 /config/clash 有最小请求间隔，超了直接 429。手上的配置只有在面板
  // 报出新的 revision 或超过更新间隔后才算过期，在那之前一律复用，不再重复请求
  bool _remoteStale = false;
  Future<void>? _remoteFetch;
  DateTime? _remoteCooldownUntil;
  String _accountKey = '';
  // 连接/重启过程中内核异常退出时置位，供 waitReady 提前结束（禁止再 scheduleRestart）
  bool _kernelDiedDuringConnect = false;
  // 正在拉起内核。内核常驻后这件事也发生在「未连接」状态下（常驻启动、断开时
  // 换成不接管出口的配置重载），不能再拿 connecting 当判据
  bool _launching = false;
  // 面板配置/节点变更等主动重启：失败后按退避持续重试，直到连上或用户断开
  bool _persistRestart = false;
  // 只认用户点选后落盘的记录。内核回落到的组内第一个不能当上次选择，
  // 否则会写成 default-selected 并关掉 store-selected，把 cache.db 也废掉。
  Map<String, String>? _selectorSnapshot;

  // connect()/_restartKernel()/自动重连每次各领一个新编号；某一轮在 await 期间
  // 发现自己的编号已经落后，说明中途被 disconnect() 或更新的一轮取代，
  // 后续动作（拉起内核、写状态、挂定时器）全部作废，避免把状态改回去
  int _generation = 0;
  bool _clearingSession = false;
  int? _deviceReclaimGeneration;

  AppSettings get settings => _settings;

  ConnectionPhase get state => _state;

  String? get error => _error;
  bool get panelOffline => _panelOffline;

  String? get formatError => _formatError;

  List<String> get preflightProblems => _preflightProblems;

  List<ProxyGroup> get groups => <ProxyGroup>[
    for (final ProxyGroup group in _groups)
      if (group.name != ClashApiClient.globalGroupName) group,
  ];

  ProxyGroup? get globalGroup => groupByName(ClashApiClient.globalGroupName);

  List<ProxyGroup> get groupsForMode {
    if (_routeMode == 'direct') {
      return const <ProxyGroup>[];
    }
    if (_routeMode == 'global') {
      final ProxyGroup? group = globalGroup;
      return group == null ? const <ProxyGroup>[] : <ProxyGroup>[group];
    }
    return groups;
  }

  List<ProxyNode> get nodes => _nodes;

  int delayOf(String name) => _delays[name] ?? 0;

  int speedOf(String name) => _speeds[name] ?? 0;

  Set<String> get testingSpeedNodes => _testingSpeeds;

  Set<String> get testingSpeedGroups => _testingSpeedGroups;

  Set<String> get speedFailedNodes => _speedFailed;

  String typeOf(String name) {
    for (final ProxyNode node in _nodes) {
      if (node.name == name) {
        return _displayType(node.type);
      }
    }
    return '';
  }

  String networkOf(String name) {
    final String network = _proxyNetwork[name] ?? '';
    return network.isEmpty ? '' : network.toUpperCase();
  }

  String tlsOf(String name) => _proxyTls[name] ?? '';

  String udpOf(String name) {
    for (final ProxyNode node in _nodes) {
      if (node.name != name) {
        continue;
      }
      if (node.xudp == true) {
        return 'XUDP';
      }
      if (node.udp == true) {
        return 'UDP';
      }
      break;
    }
    return _proxyUdp[name] == true ? 'UDP' : '';
  }

  Set<String> get testingNodes => _testing;

  Set<String> get testingGroups => _testingGroups;

  Set<String> get unreachableNodes => _unreachable;

  bool get kernelCacheReady => _kernel.cacheReady;

  String? get mixedProxyCredential => _clash?.options.mixedCredential;

  Future<String> kernelVersion() => _kernel.kernelVersion();

  bool get kernelUpgradeSupported => _kernel.upgradable;

  Future<KernelUpdate> checkKernelUpdate() async =>
      KernelUpdate.check(await kernelVersion());

  /// 升级内核。下载与校验期间连接不断，GitHub 经本地 mixed 出网；
  /// 替换文件前由服务停掉内核，因此这里要先摘掉「内核意外退出就自动重启」那条路，
  /// 换完再按升级前的状态重连。
  Future<String> upgradeKernel(String version) async {
    final int generation = _generation;
    final bool wasConnected = _state == ConnectionPhase.connected;
    final bool wasRunning = _clash != null;
    _userStopped = true;
    _restartTimer?.cancel();
    _restartTimer = null;

    bool installed = false;
    try {
      final String result = await _kernel.upgrade(
        version,
        proxyPort: wasConnected ? _settings.mixedPort : null,
      );
      installed = true;
      return result;
    } finally {
      if (wasRunning && generation == _generation) {
        _userStopped = false;
        if (installed) {
          _restartAttempt = 0;
          await _restartKernel(L10n.t('内核已更新，正在重启'));
        }
      }
    }
  }

  Future<({String stage, int percent})> kernelUpgradeProgress() =>
      _kernel.upgradeProgress();

  String? get startupStage => _startupStage;

  int get remoteProviderCount => _providerTotal;

  // 内核为每个 provider 各输出一行完成日志，文案见 component/resource/fetcher.go：
  // 有更新是 info 级的「[Provider] <name>'s content update」，命中缓存未变更是
  // debug 级的「[Provider] <name>'s content doesn't change」。
  // provider 是并发初始化的（hub/executor loadProvider），开始那行的顺序说明不了
  // 进度，因此只按已完成数量统计。
  static final RegExp _providerDone = RegExp(
    r"\[Provider\] (.+?)'s content (?:update|doesn't change)",
  );

  final Set<String> _providerReady = <String>{};
  int _providerTotal = 0;

  void _trackStartupStage(String line) {
    if (_state != ConnectionPhase.connecting) {
      return;
    }

    final RegExpMatch? match = _providerDone.firstMatch(line);
    if (match != null) {
      _providerReady.add(match.group(1)!);
    }

    final String? next = match != null && _providerTotal > 0
        ? L10n.t('正在准备分流规则集 {0}/{1}', <Object>[
            _providerReady.length,
            _providerTotal,
          ])
        : line.contains('Start initial configuration in progress')
        ? L10n.t('内核已启动，正在加载配置')
        : null;

    if (next == null || next == _startupStage) {
      return;
    }
    _startupStage = next;
    notifyListeners();
  }

  // MATCH 规则指向的分组才是默认出站；全局模式改走内核自建的 GLOBAL
  ProxyGroup? get mainGroup {
    if (_routeMode == 'direct') {
      return null;
    }
    if (_routeMode == 'global') {
      return globalGroup;
    }
    final String? target = _matchTarget();
    return (target == null ? null : groupByName(target)) ??
        (groups.isEmpty ? null : groups.first);
  }

  // 规则是 `TYPE,payload,target` 的逗号分隔文本，兜底规则没有 payload：`MATCH,Proxy`
  String? _matchTarget() {
    final Object? rules = _remote?['rules'];
    if (rules is! List) {
      return null;
    }

    for (final Object? rule in rules) {
      if (rule is! String) {
        continue;
      }
      final List<String> parts = rule.split(',');
      if (parts.length >= 2 && parts.first.trim().toUpperCase() == 'MATCH') {
        return parts[1].trim();
      }
    }
    return null;
  }

  ProxyGroup? groupByName(String name) {
    for (final ProxyGroup group in _groups) {
      if (group.name == name) {
        return group;
      }
    }
    return null;
  }

  // 面板在 Clash 模板的 x-sspanel.group_icons 里维护，没配的分组返回 null
  String? groupIconOf(String tag) => _groupIcons[tag];

  String? fastestMember(ProxyGroup group) {
    String? fastest;
    int lowest = 0;

    for (final String member in group.members) {
      final int delay = delayOf(resolveNode(member));
      if (delay <= 0 || (lowest != 0 && delay >= lowest)) {
        continue;
      }
      lowest = delay;
      fastest = member;
    }

    return fastest;
  }

  // 每秒的流量与连接快照单独通知：整页的监听者不必跟着每秒重建
  Listenable get statsUpdates => _statsUpdates;

  TrafficSample get traffic => _traffic;

  TrafficSample get trafficTotal => _trafficTotal;

  List<TrafficSample> get trafficHistory => _trafficHistory;

  KernelStats get stats => _stats;

  List<Map<String, dynamic>> get connections => _connections;

  List<TrafficRankRow> trafficRankGroups(TrafficRankDay day) =>
      _trafficRank.topGroups(day);

  List<TrafficRankRow> trafficRankHosts(TrafficRankDay day) =>
      _trafficRank.topHosts(day, exclude: _proxyServers);

  List<Map<String, dynamic>> get closedConnections => _closedConnections;

  // 与内核日志里的源地址同一写法（net.JoinHostPort），日志按它回查入站类型
  static String connectionSource(Map<String, dynamic> item) {
    final Object? meta = item['metadata'];
    if (meta is! Map) {
      return '';
    }
    final String ip = '${meta['sourceIP'] ?? ''}'.trim();
    final String port = '${meta['sourcePort'] ?? ''}'.trim();
    if (ip.isEmpty || port.isEmpty) {
      return '';
    }
    return ip.contains(':') ? '[$ip]:$port' : '$ip:$port';
  }

  String get routeMode => _routeMode;

  DateTime? get connectedAt => _connectedAt;

  ClashApiClient? get clash => _clash;

  /// 控制面是否在线。内核常驻，未连接时它同样为真，节点操作据此放行。
  bool get controlPlaneReady => _clash != null;

  String? _standbyError;
  String? get standbyError => _standbyError;

  bool get busy =>
      _state == ConnectionPhase.connecting ||
      _state == ConnectionPhase.disconnecting;

  void attachProfileLookup(UserProfile? Function()? lookup) {
    _profileOf = lookup;
  }

  void attachApi(PanelApiClient? api, {String? accountKey}) {
    final PanelApiClient? previousApi = _api;
    final bool changed = !identical(api, _api);
    final String nextKey = (accountKey ?? '').trim();
    final bool accountChanged =
        nextKey.isNotEmpty &&
        nextKey.toLowerCase() != _accountKey.toLowerCase();
    _api = api;
    if (api != null) {
      _clearingSession = false;
    }
    if (changed) {
      _remoteFetch = null;
    }
    if (accountChanged || api == null) {
      _panelSyncTimer?.cancel();
      _authorizationTimer?.cancel();
      _remoteProfile = null;
      _remotePending = false;
      _panelOffline = false;
      _clearFormatError();
      _remote = null;
      _profile = null;
      _configRevision = '';
      _selectorSnapshot = null;
      _groupIcons = const <String, String>{};
      _groups = const <ProxyGroup>[];
      _nodes = const <ProxyNode>[];
      _loadedNodes = null;
      _recentNodes.clear();
      _probeNodes = const <Object?>[];
      _forgetBrowsed();
      _validated = null;
      _remoteFailed = false;
      _indexProxyExtra();
    }
    api?.fallbackProxyPort = _state == ConnectionPhase.connected
        ? _settings.mixedPort
        : null;
    api?.fallbackProxyCredential = mixedProxyCredential;
    api?.reportConnected = _state == ConnectionPhase.connected;
    if (api != null) {
      unawaited(api.refreshConfigDirectAddresses());
    }
    if (nextKey.isNotEmpty) {
      _accountKey = nextKey;
      _speedQuota.bindAccount(nextKey);
      _trafficRank.bindAccount(nextKey);
    }
    if (api == null) {
      _remoteStale = false;
      _remoteCooldownUntil = null;
      _accountKey = '';
      _speedQuota.bindAccount('');
      _trafficRank.bindAccount('');
      return;
    }
    if (accountChanged) {
      _forgetTestResults();
    }
    if (accountChanged || (_remote == null && _accountKey.isNotEmpty)) {
      _hydrateRemoteFromCache();
    }
    if (changed) {
      // 新 token 限流计数独立；清掉旧退避，避免刚登录还背着上一会话的冷却
      _remoteCooldownUntil = null;
      _panelSyncTimer?.cancel();
      _panelSyncTimer = null;
      if (_state == ConnectionPhase.connected) {
        _startPanelSync(api);
        _armAuthorizationExpiry();
      }
      if (_state == ConnectionPhase.connected && previousApi != null) {
        unawaited(refreshProfileFromPanel());
      } else {
        unawaited(preloadProxies());
      }
    }
  }

  Future<void> preloadProxies() async {
    final PanelApiClient? api = _api;
    if (api == null) {
      return;
    }

    try {
      await _ensureRemoteConfig(api);
    } on Object catch (e) {
      if (!identical(api, _api)) {
        return;
      }
      Logger.instance.warn(_source, '预取面板配置失败: $e');
      if (_isFormatError(e)) {
        _emitConfigAlert(e);
      }
    }

    if (!identical(api, _api)) {
      return;
    }
    if (_clash != null) {
      try {
        await _refreshProxies();
      } on Object catch (e) {
        Logger.instance.debug(_source, '刷新出站列表失败: $e');
      }
      if (_groups.isEmpty) {
        _applyProfileProxies();
      }
      notifyListeners();
      return;
    }

    _applyProfileProxies();
    notifyListeners();
    unawaited(startStandby());
  }

  Future<void> runPreflight() async {
    _preflightProblems = await _kernel.preflight();
    notifyListeners();
  }

  /// 内核比界面活得久时（Android 上 Activity 被销毁、进程被杀，VpnService 仍在
  /// 跑隧道），界面重新起来必须认回这条连接。认不回的一律停掉：留着就是一条
  /// 界面显示「未连接」、用户也断不开的隧道。
  Future<void> adoptRunningKernel({bool takeover = false}) {
    final Future<void> run = _adoptRunningKernel(takeover);
    _adoption = run;
    return run.whenComplete(() {
      if (identical(_adoption, run)) {
        _adoption = null;
      }
    });
  }

  Future<void> _adoptRunningKernel(bool takeover) async {
    final int generation = ++_generation;
    final ClashApiOptions? live = await _kernel.attach();
    if (live == null || generation != _generation) {
      return;
    }

    _userStopped = false;
    _setState(ConnectionPhase.connecting, error: null);

    final ClashApiClient clash = ClashApiClient(live)
      ..panelProviders = _panelProviderNames();
    try {
      await clash.waitReady(
        timeout: const Duration(seconds: 10),
        isCancelled: () => generation != _generation,
      );
      if (generation != _generation) {
        clash.close();
        return;
      }
      _clash = clash;
      _clashApiOptions = live;
      await _refreshProxies();
      final ({String mode, bool tunEnabled, int mixedPort}) runtime =
          await clash.fetchRuntime();
      if (generation != _generation || !identical(clash, _clash)) {
        return;
      }
      _routeMode = runtime.mode;
      // 认回来的可能是一个常驻但没接管出口的内核，此时界面该显示未连接
      _takeover = runtime.tunEnabled || takeover;
      // 平台初始化会还原残留的系统代理，认回后按接管状态重新设置
      await _applySystemProxy();
      if (generation != _generation || !identical(clash, _clash)) {
        return;
      }
    } on Object catch (e) {
      if (generation != _generation) {
        clash.close();
        return;
      }
      Logger.instance.warn(_source, '接管运行中的内核失败，改为停止：$e');
      _userStopped = true;
      _clash = null;
      clash.close();
      await _teardown();
      _setState(ConnectionPhase.disconnected, error: null);
      return;
    }

    _connectedAt = _takeover ? _kernel.startedAt : null;
    _scheduleProxyRefresh();
    if (_takeover) {
      _scheduleStatsRefresh();
    }
    Logger.instance.info(_source, _takeover ? '已接管后台运行中的内核' : '已接管后台常驻的内核');
    _setState(
      _takeover ? ConnectionPhase.connected : ConnectionPhase.disconnected,
      error: null,
    );
  }

  Future<void> startStandby() async {
    // 认回还在等后台应答时不能抢先起常驻内核：那会作废认回，并把正在跑的隧道换成不接管的内核
    final Future<void>? adoption = _adoption;
    if (adoption != null) {
      try {
        await adoption;
      } on Object catch (_) {}
    }
    if (_clash != null || busy || _api == null) {
      return;
    }
    await _switchTakeover(false, L10n.t('正在准备内核'));
  }

  Future<void> connect() async {
    if (busy || _state == ConnectionPhase.connected) {
      return;
    }
    _autoConnectTimer?.cancel();
    _autoConnectTimer = null;
    _autoConnectAttempt = 0;
    await _attemptConnect();
  }

  /// 启动后自动连接。开机自启时界面比网络早就绪几十秒（实测登录后 6 秒起界面、
  /// 32 秒才有默认路由），此时连不上面板不是失败而是还没到时候，按退避等网络起来。
  /// 手点连接仍然一次失败就报错，不在这里等。
  Future<void> autoConnect() async {
    if (busy || _state == ConnectionPhase.connected) {
      return;
    }
    _autoConnectAttempt = 0;
    await _attemptConnect(autoRetry: true);
  }

  Future<void> _attemptConnect({bool autoRetry = false}) async {
    final PanelApiClient? api = _api;
    if (api == null) {
      _fail(L10n.t('尚未登录'));
      return;
    }

    final int generation = ++_generation;
    _startupStage = L10n.t('正在连接');
    _deviceReclaimGeneration = generation;
    _setState(ConnectionPhase.connecting, error: null);
    try {
      if (!_canUseOffline(api)) {
        await api.fetchProfile();
      }
      if (generation != _generation) {
        return;
      }
    } on ApiException catch (e) {
      if (generation == _generation) {
        if (e.transient && _useCachedRemote()) {
          _panelOffline = true;
        } else if (autoRetry && e.transient && !e.rateLimited) {
          _scheduleAutoConnect(generation, e.message);
        } else {
          if (e.unauthorized) {
            await _rejectSession(api);
            return;
          }
          _fail(e.message);
        }
      }
      if (!_canUseOffline(api) || !e.transient) {
        return;
      }
    } finally {
      if (_deviceReclaimGeneration == generation) {
        _deviceReclaimGeneration = null;
      }
    }
    if (generation != _generation) {
      return;
    }

    await _switchTakeover(true, L10n.t('正在连接'), autoRetry: autoRetry);
    if (identical(api, _api) && _state == ConnectionPhase.connected) {
      unawaited(_syncPanel(api));
    }
  }

  Future<void> handleDeviceLimitDenied() async {
    if (_deviceReclaimGeneration == _generation ||
        (_state != ConnectionPhase.connected &&
            _state != ConnectionPhase.connecting)) {
      return;
    }

    final int generation = _generation;
    final PanelApiClient? api = _api;
    final confirm = confirmDeviceLimitKick;
    if (api == null || confirm == null) {
      return;
    }
    _deviceReclaimGeneration = generation;
    try {
      final profile = await api.fetchProfile();
      if (generation != _generation ||
          profile.connectorLimit <= 0 ||
          profile.onlineDeviceSelf) {
        return;
      }
      final devices = await api.fetchOnlineDevices();
      if (generation != _generation) {
        return;
      }
      final targetDeviceId = await confirm(devices);
      if (generation != _generation || targetDeviceId == null) {
        return;
      }
      await api.reclaimDeviceSlot(targetDeviceId: targetDeviceId);
    } on ApiException catch (e) {
      Logger.instance.warn(_source, e.message);
    } finally {
      if (_deviceReclaimGeneration == generation) {
        _deviceReclaimGeneration = null;
      }
    }
  }

  Future<void> disconnect() async {
    if (_state == ConnectionPhase.disconnecting ||
        (!_takeover && _state == ConnectionPhase.disconnected)) {
      return;
    }

    _setState(ConnectionPhase.disconnecting, error: null);
    await _switchTakeover(false, L10n.t('正在断开连接'));
  }

  /// 登出或退出应用：内核彻底停下，出口还原。与 [disconnect] 的区别是这之后
  /// 控制面也不在了，节点列表退回面板配置那一份。
  Future<void> shutdown({
    bool clearSession = false,
    String endedSession = '',
  }) async {
    final int generation = ++_generation;
    _takeover = false;
    _userStopped = true;
    _persistRestart = false;
    _restartTimer?.cancel();
    _restartTimer = null;
    _autoConnectTimer?.cancel();
    _autoConnectTimer = null;
    _panelSyncTimer?.cancel();
    _panelSyncTimer = null;
    _authorizationTimer?.cancel();
    _authorizationTimer = null;

    if (clearSession) {
      _clearingSession = true;
      attachApi(null);
    }

    _setState(ConnectionPhase.disconnecting, error: null);
    try {
      await _teardown(clearSession: clearSession, session: endedSession);
    } on Object catch (e) {
      if (!clearSession) {
        if (generation == _generation) {
          _fail(e.toString());
        }
        rethrow;
      }
      Logger.instance.warn(_source, '停止旧账户内核失败，下次启动或退出时再停: $e');
    }
    if (clearSession && _api == null) {
      await _speedTester.waitForIdle();
      if (_api == null) {
        _clashApiOptions = null;
        NodeLabels.configure('');
        Logger.instance.clearSession();
      }
    }
    if (generation != _generation) {
      return;
    }
    _forgetTestResults();
    _setState(ConnectionPhase.disconnected, error: null);
  }

  Future<void> _switchTakeover(
    bool takeover,
    String stage, {
    bool autoRetry = false,
  }) async {
    final PanelApiClient? api = _api;
    if (api == null) {
      if (takeover) {
        _fail(L10n.t('尚未登录'));
      }
      return;
    }

    final int generation = ++_generation;
    final bool wasTakeover = _takeover;
    _takeover = takeover;
    _userStopped = false;
    _restartAttempt = 0;
    _tunRouteRepairs = 0;
    _persistRestart = false;
    _kernelDiedDuringConnect = false;
    _restartTimer?.cancel();
    _restartTimer = null;
    _autoConnectTimer?.cancel();
    _autoConnectTimer = null;
    _captureSelectorSnapshot();
    _startupStage = stage;
    _standbyError = null;
    if (takeover) {
      _setState(ConnectionPhase.connecting, error: null);
    } else {
      notifyListeners();
    }

    try {
      if (takeover || _clash == null || _remote == null) {
        await _ensureRemoteConfig(api);
        if (generation != _generation) {
          return;
        }
      }

      if (takeover && _clash != null && _remotePending) {
        await _hotReloadPanelProfile();
        if (generation != _generation) {
          return;
        }
      }

      if (_clash != null && !_platform.requiresTun) {
        try {
          await _hotSwitchTakeover(generation);
          return;
        } on Object catch (e) {
          Logger.instance.warn(_source, '热切换出口失败，回退为重载内核: $e');
        }
      }

      if (_clash != null && _platform.requiresTun && !takeover) {
        await _rebuildProfile(
          reuseControlPlane: true,
          refreshDirectAddresses: false,
        );
        await _kernel.persistConfig(_profile!.json);
        if (generation != _generation) {
          return;
        }
        await _teardown();
        if (generation != _generation) {
          return;
        }
        _setState(ConnectionPhase.disconnected, error: null);
        unawaited(
          Future<void>(() async {
            if (generation == _generation) {
              await startStandby();
            }
          }),
        );
        return;
      }

      final bool keepPlane = _clash != null;
      if (!keepPlane) {
        await _teardown(restarting: true);
      }
      if (generation != _generation) {
        return;
      }
      await _rebuildProfile(
        reuseControlPlane: keepPlane,
        refreshDirectAddresses: !_canUseOffline(api),
      );
      await _launchKernel(generation);
    } on Object catch (e) {
      if (generation != _generation) {
        return;
      }
      if (e is! ApiException) {
        _remoteFailed = true;
      }
      final String reason = _kernelDiedDuringConnect
          ? L10n.t('内核启动失败，请重试')
          : e.toString();
      Object? stopError;
      try {
        await _teardown();
      } on Object catch (stop) {
        stopError = stop;
        Logger.instance.warn(_source, '连接失败后停止内核失败: $stop');
      }
      if (generation != _generation) {
        return;
      }
      if (_isFormatError(e)) {
        _emitConfigAlert(e);
      }
      // 常驻起不来不该弹成连接失败：用户没按连接，界面退回面板配置那份节点列表即可
      if (takeover) {
        if (e is ApiException && e.unauthorized) {
          await _rejectSession(api);
        } else if (autoRetry &&
            e is ApiException &&
            e.transient &&
            !e.rateLimited) {
          _scheduleAutoConnect(generation, e.message);
        } else {
          _fail(reason);
        }
      } else if (wasTakeover && stopError != null) {
        // 断开时内核没能停掉：TUN 与内核都还在接管流量，不能显示成已断开
        _fail(stopError.toString());
      } else {
        Logger.instance.warn(_source, '内核常驻启动失败：$reason');
        _standbyError = reason;
        _setState(ConnectionPhase.disconnected, error: null);
      }
    }
  }

  Future<void> _hotSwitchTakeover(int generation) async {
    await _rebuildProfile(
      reuseControlPlane: true,
      refreshDirectAddresses: false,
    );
    if (generation != _generation) {
      return;
    }
    final AssembledProfile profile = _profile!;
    await _kernel.persistConfig(profile.json);
    if (generation != _generation) {
      return;
    }

    final ClashApiClient? clash = _clash;
    if (clash == null) {
      throw StateError(L10n.t('内核未就绪'));
    }
    final bool tunEnabled = _takeover && _settings.tunEnabled;
    await clash.setTunEnabled(tunEnabled);
    if (generation != _generation) {
      return;
    }
    await _ensureTunApplied(clash, tunEnabled);
    if (generation != _generation) {
      return;
    }

    await _applySystemProxy();
    if (generation != _generation) {
      return;
    }

    _connectedAt = _takeover ? DateTime.now() : null;
    _restartAttempt = 0;
    _persistRestart = false;
    if (_takeover) {
      _scheduleStatsRefresh();
    } else {
      _statsTimer?.cancel();
      _statsTimer = null;
      _trafficRank.flush();
      _traffic = const TrafficSample(0, 0);
      _trafficTotal = const TrafficSample(0, 0);
      _trafficSampledAt = null;
      _trafficHistory.clear();
      _stats = KernelStats.empty;
      _connections = const <Map<String, dynamic>>[];
      _closedConnections.clear();
    }
    _scheduleProxyRefresh();
    _setState(
      _takeover ? ConnectionPhase.connected : ConnectionPhase.disconnected,
      error: null,
    );
  }

  Future<void> updateSettings(AppSettings next) async {
    final int generation = _generation;
    final bool needsRestart =
        _settings.affectsKernel(next) && (_clash != null || _launching);
    final bool proxyChanged =
        _settings.systemProxyEnabled != next.systemProxyEnabled ||
        !listEquals(_settings.systemProxyBypass, next.systemProxyBypass);

    _settings = next;
    _settingsStore.save(next);
    Logger.instance.level = next.logLevel;
    notifyListeners();

    await syncPlatformSettings();
    if (generation != _generation) {
      return;
    }

    if (needsRestart) {
      await _restartKernel(L10n.t('正在应用新设置'));
      return;
    }

    if (proxyChanged && _state == ConnectionPhase.connected) {
      await _applySystemProxy();
    }
    if (proxyChanged) {
      _syncSysProxyGuard();
    }
  }

  // 内核的 PATCH / PUT /configs 能热改端口、TUN、IPv6、日志级别，但客户端每次都是
  // 拿面板配置加本地模板整份重装：走重启这一条路，落盘的那份配置始终等于运行中的
  // 状态，界面之外读回控制面端口与 secret 时才不会读到已被增量改掉的旧值
  Future<void> _restartKernel(String stage, {bool validated = false}) async {
    final int generation = ++_generation;
    _restartTimer?.cancel();
    _restartTimer = null;
    _restartAttempt = 0;
    _persistRestart = true;
    _kernelDiedDuringConnect = false;
    _captureSelectorSnapshot();
    // 先进入 connecting，避免 teardown 停内核时状态仍是 connected 触发自动重连
    _startupStage = stage;
    if (_takeover) {
      _setState(ConnectionPhase.connecting, error: null);
    }
    await _teardown(restarting: true);
    if (generation != _generation) {
      return;
    }

    try {
      await _rebuildProfile();
      await _launchKernel(generation, validated: validated);
    } on Object catch (e) {
      if (generation != _generation || _userStopped) {
        return;
      }
      // 配置本身非法：重试无意义，直接失败
      if (_isUnrecoverableConfigError(e)) {
        _persistRestart = false;
        if (_isFormatError(e)) {
          _emitConfigAlert(e);
        }
        _fail(e.toString());
        await _teardown();
        return;
      }
      final String reason = _kernelDiedDuringConnect
          ? L10n.t('内核启动失败')
          : e.toString();
      await _teardown(restarting: true);
      _scheduleRestart(reason);
    }
  }

  bool _isUnrecoverableConfigError(Object error) {
    if (error is ProfileAssemblyException || error is ProfileFormatException) {
      return true;
    }
    final String message = switch (error) {
      ApiException() => error.message,
      KernelException() => error.message,
      _ => error.toString(),
    };
    return message.contains('配置校验未通过') ||
        message.contains('面板配置不规范') ||
        message.contains('面板下发的不是一份完整配置') ||
        message.contains('面板未下发任何可用节点') ||
        message.contains(L10n.t('尚未获取面板配置'));
  }

  // 启动时也必须推一次：注册表自启项可能被外部清理，原生侧托盘状态不持久
  Future<void> syncPlatformSettings() async {
    if (_platform.supportsLaunchAtLogin) {
      await _platform.setLaunchAtLogin(enabled: _settings.launchAtLogin);
    }
    if (_platform.supportsTray) {
      await _platform.setCloseToTray(enabled: _settings.closeToTray);
      _syncTray();
    }
  }

  void _syncTray() {
    final bool active = _state == ConnectionPhase.connected;
    // 改设置要重启内核，中途状态落回 connecting：出口开关并没有变，系统代理也还留在
    // 系统里（_teardown 的重启分支不还原），图标不能跟着闪回默认色
    final bool serving = active || (busy && _persistRestart);
    final bool proxyOn = serving && _settings.systemProxyEnabled;
    final bool tunOn = serving && _settings.tunEnabled;
    final String on = L10n.t('已开启');
    final String off = L10n.t('已关闭');
    final TrayState next = TrayState(
      connected: active,
      busy: busy,
      systemProxyEnabled: proxyOn,
      tunEnabled: tunOn,
      routeMode: _routeMode,
      modeEnabled: true,
      statusTip:
          '${L10n.t('系统代理：{0}', <Object>[proxyOn ? on : off])}\n'
          '${L10n.t('TUN 模式：{0}', <Object>[tunOn ? on : off])}',
      labels: TrayLabels(
        connect: switch (L10n.current) {
          AppLanguage.en => 'Connect',
          AppLanguage.zhTW => '連線',
          AppLanguage.zhCN => '连接',
        },
        disconnect: L10n.t('断开连接'),
        cancel: L10n.t('取消连接'),
        systemProxy: L10n.t('系统代理'),
        tun: L10n.t('TUN 模式'),
        rule: L10n.t('规则'),
        global: L10n.t('全局'),
        direct: L10n.t('直连'),
        show: L10n.t('显示主界面'),
        quit: L10n.t('退出'),
      ),
      darkMenu: switch (_settings.themeMode) {
        ThemeMode.dark => true,
        ThemeMode.light => false,
        ThemeMode.system =>
          PlatformDispatcher.instance.platformBrightness == Brightness.dark,
      },
    );
    if (next == _trayState) {
      return;
    }

    _trayState = next;
    unawaited(
      _platform
          .setTrayState(next)
          .catchError(
            (Object e) => Logger.instance.debug(_source, '同步托盘状态失败: $e'),
          ),
    );
  }

  void _onTrayAction(TrayAction action) {
    switch (action) {
      case TrayAction.connect:
        unawaited(connect());
      case TrayAction.disconnect:
        unawaited(disconnect());
      case TrayAction.toggle:
        unawaited(
          busy || _state == ConnectionPhase.connected
              ? disconnect()
              : connect(),
        );
      case TrayAction.toggleSystemProxy:
        if (_state != ConnectionPhase.connected) {
          return;
        }
        unawaited(
          updateSettings(
            _settings.copyWith(
              systemProxyEnabled: !_settings.systemProxyEnabled,
            ),
          ),
        );
      case TrayAction.toggleTun:
        if (_state != ConnectionPhase.connected) {
          return;
        }
        unawaited(
          updateSettings(_settings.copyWith(tunEnabled: !_settings.tunEnabled)),
        );
      case TrayAction.modeRule:
        unawaited(setRouteMode('rule'));
      case TrayAction.modeGlobal:
        unawaited(setRouteMode('global'));
      case TrayAction.modeDirect:
        unawaited(setRouteMode('direct'));
    }
  }

  Future<void> selectProxy(String group, String member) async {
    if (!await _ensureControlPlane()) {
      return;
    }
    final ClashApiClient clash = _clash!;
    final String? previous = groupByName(group)?.now;

    await _loadNodes(<String>[member]);
    if (!identical(clash, _clash)) {
      return;
    }
    await clash.selectProxy(group, member);
    if (!identical(clash, _clash)) {
      return;
    }
    _rememberSelector(group, member);
    await _refreshProxies();
    await _persistRunningProfile();

    // 换下来的那个出站上还挂着存量连接，断掉它们后续请求才走新选中项。只断经过它的，
    // 别的分组不受牵连；放后台做，界面不等这一轮
    if (previous != null && previous.isNotEmpty && previous != member) {
      unawaited(clash.closeConnectionsVia(<String>{previous}));
    }
  }

  void _captureSelectorSnapshot() {
    final Map<String, String> live = <String, String>{
      for (final ProxyGroup group in _groups)
        if (group.selectable &&
            group.now.isNotEmpty &&
            (group.members.isEmpty || group.now != group.members.first))
          group.name: group.now,
    };
    final Map<String, String> snap = <String, String>{
      ...live,
      ...?_loadSelectorSnapshot(),
      ...?_selectorSnapshot,
    };
    _selectorSnapshot = snap.isEmpty ? null : snap;
    if (snap.isNotEmpty) {
      _persistSelectorSnapshot(snap);
    }
  }

  void _rememberSelector(String group, String member) {
    if (group.isEmpty || member.isEmpty) {
      return;
    }
    final Map<String, String> snap = <String, String>{
      ...?_loadSelectorSnapshot(),
      ...?_selectorSnapshot,
      group: member,
    };
    _selectorSnapshot = snap;
    _persistSelectorSnapshot(snap);
  }

  Map<String, String>? _loadSelectorSnapshot() {
    final Map<String, dynamic> data = _selectorCache.read();
    final String storedAccount = (data['account'] as String? ?? '')
        .toLowerCase();
    if (_accountKey.isEmpty ||
        storedAccount != _accountKey.trim().toLowerCase()) {
      return null;
    }
    final Object? raw = data['selected'];
    if (raw is! Map) {
      return null;
    }
    final Map<String, String> snap = <String, String>{
      for (final MapEntry<Object?, Object?> entry in raw.entries)
        if (entry.key is String &&
            entry.value is String &&
            (entry.value as String).isNotEmpty)
          entry.key as String: entry.value as String,
    };
    return snap.isEmpty ? null : snap;
  }

  void _persistSelectorSnapshot(Map<String, String> snap) {
    if (snap.isEmpty) {
      return;
    }
    try {
      _selectorCache.write(<String, dynamic>{
        'account': _accountKey.trim().toLowerCase(),
        'selected': snap,
      });
    } on Object catch (e) {
      Logger.instance.warn(_source, '写入 selector-cache 失败: $e');
    }
  }

  Future<void> _restoreSelectorSnapshot() async {
    final Map<String, String>? snap =
        _selectorSnapshot ?? _loadSelectorSnapshot();
    final ClashApiClient? clash = _clash;
    if (snap == null || snap.isEmpty || clash == null) {
      return;
    }

    final Set<String> replaced = <String>{};
    for (final ProxyGroup group in _groups) {
      final String? want = snap[group.name];
      if (want == null ||
          want.isEmpty ||
          !group.selectable ||
          !group.members.contains(want) ||
          group.now == want) {
        continue;
      }
      try {
        await clash.selectProxy(group.name, want);
        if (!identical(clash, _clash)) {
          return;
        }
        replaced.add(group.now);
      } on Object catch (e) {
        if (!identical(clash, _clash)) {
          return;
        }
        Logger.instance.warn(_source, '恢复分组「${group.name}」选中项失败: $e');
      }
    }
    if (replaced.isNotEmpty) {
      await clash.closeConnectionsVia(replaced);
      if (identical(clash, _clash)) {
        await _refreshProxies(notify: false);
      }
    }
  }

  Future<void> setRouteMode(String mode) async {
    if (mode != 'rule' && mode != 'global' && mode != 'direct') {
      return;
    }
    final ClashApiClient? clash = _clash;
    if (clash != null) {
      await clash.setMode(mode);
      if (!identical(clash, _clash)) {
        return;
      }
    }

    _routeMode = mode;
    if (_settings.routeMode != mode) {
      _settings = _settings.copyWith(routeMode: mode);
      _settingsStore.save(_settings);
    }
    notifyListeners();
    if (clash != null) {
      await _persistRunningProfile();
    }
  }

  // 开机自启、始终开启的 VPN 与磁贴由原生侧按落盘配置拉起内核，运行中换的节点与模式不写回就会退回连接时的值
  Future<void> _persistRunningProfile() async {
    final int generation = _generation;
    try {
      await _rebuildProfile(
        reuseControlPlane: true,
        refreshDirectAddresses: false,
      );
      if (generation == _generation && _clash != null) {
        await _kernel.persistConfig(_profile!.json);
      }
    } on Object catch (e) {
      Logger.instance.warn(_source, '写回当前节点与模式失败: $e');
    }
  }

  // 分组成员本身也可能是分组（面板下发的「主节点」「自动选择」就是）。延迟、探测进度、
  // 不可用标记一律以叶子名为键，成员是分组时先顺着选中项解析下去。
  //
  // 因为 fetchProxies 把 /proxies 里带 all/now 的条目全归进 _groups，_nodes 里只有
  // 非分组出站。而 /proxies/{名}/delay 把结果记在被点名的那个出站上（adapter/adapter.go
  // 的 URLTest 往接收者的 history 与 extra 里写），拿分组名去测，历史就落在分组上，
  // _applyProxies 那轮刷新永远读不到它，界面上的数字会一直停在第一次的值。
  String resolveNode(String name) {
    String current = name;
    // 面板配置理论上不该有环，留个上限兜住
    for (int hop = 0; hop < 8; hop++) {
      final ProxyGroup? group = groupByName(current);
      if (group == null || group.now.isEmpty) {
        break;
      }
      current = group.now;
    }
    return current;
  }

  Future<void> testDelay(String name) async {
    final _TestRun? run = await _openTestRun();
    if (run != null) {
      await _testNodes(run, <String>[resolveNode(name)]);
    }
  }

  Future<bool> _ensureControlPlane() async {
    if (_clash != null) {
      return true;
    }
    await startStandby();
    return _clash != null;
  }

  Future<_TestRun?> _openTestRun() async {
    final PanelApiClient? api = _api;
    if (!await _ensureControlPlane() || !identical(api, _api)) {
      return null;
    }
    return _TestRun(this, _clash!, api);
  }

  List<String> _leavesOf(ProxyGroup group) =>
      <String>{for (final String member in group.members) resolveNode(member)}
          .toList(growable: false);

  // 不用 /group/{name}/delay：一批才返回、urltest 会忽略 url/timeout，
  // 且静默跳过距上次不足 interval 的成员，失败与跳过都表现为缺项。
  Future<void> testGroup(String group) async {
    if (!_testingGroups.add(group)) {
      return;
    }
    notifyListeners();
    _TestRun? run;
    try {
      run = await _openTestRun();
      final ProxyGroup? target = groupByName(group);
      if (run == null || target == null) {
        return;
      }
      await _testNodes(run, _leavesOf(target));

      // selector 组的选中项归用户；urltest 组要让内核按新延迟立刻重选
      if (run.isCurrent && !target.selectable) {
        await _reselect(group);
      }
    } finally {
      if (run == null || run.isCurrent) {
        _testingGroups.remove(group);
        notifyListeners();
      }
    }
  }

  Future<void> _reselect(String group) async {
    final ClashApiClient? clash = _clash;
    try {
      await clash?.reselectGroup(group);
      if (identical(clash, _clash)) {
        await _refreshProxies();
      }
    } on Object catch (e) {
      if (identical(clash, _clash)) {
        Logger.instance.warn(_source, '分组 $group 重选失败: $e');
      }
    }
  }

  // 内核对整组是并发 10 分批测的，客户端逐个打也按同一量级并发，
  // 再高就会互相抢带宽、把延迟测虚高；多个分组同时测也共用这一个上限
  static const int _testConcurrency = 8;
  int _delaySlotsInUse = 0;
  final List<Completer<void>> _delaySlotWaiters = <Completer<void>>[];

  Future<void> _acquireDelaySlot() async {
    if (_delaySlotsInUse < _testConcurrency) {
      _delaySlotsInUse++;
      return;
    }
    final Completer<void> waiter = Completer<void>();
    _delaySlotWaiters.add(waiter);
    await waiter.future;
  }

  void _releaseDelaySlot() {
    if (_delaySlotWaiters.isEmpty) {
      _delaySlotsInUse--;
    } else {
      _delaySlotWaiters.removeAt(0).complete();
    }
  }

  Future<void> _testNodes(_TestRun run, List<String> names) async {
    final List<String> unloaded = _unloadedOf(names);
    final Set<String> deferred = unloaded.toSet();
    if (unloaded.isNotEmpty) {
      // 一次并入，免得每批探测各落一次盘
      _adoptBrowsed(unloaded);
    }
    bool used = await _testLoaded(run, <String>[
      for (final String name in names)
        if (!deferred.contains(name)) name,
    ]);
    for (int start = 0; start < unloaded.length; start += _probeBatch) {
      if (!run.isCurrent) {
        return;
      }
      final List<String> batch = unloaded.sublist(
        start,
        min(start + _probeBatch, unloaded.length),
      );
      if (await _probe(batch)) {
        used |= await _testLoaded(run, batch);
      } else if (run.isCurrent) {
        for (final String name in batch) {
          _delays.remove(name);
          _unreachable.add(name);
        }
        notifyListeners();
      }
    }
    if (run.isCurrent && used) {
      unawaited(run.api?.reportNodeUsed());
    }
  }

  Future<bool> _testLoaded(_TestRun run, List<String> names) async {
    final List<String> pending = names
        .where((String name) => name.isNotEmpty && _testing.add(name))
        .toList(growable: false);
    if (pending.isEmpty) {
      return false;
    }
    notifyListeners();
    bool used = false;

    Future<void> test(String name) async {
      await _acquireDelaySlot();
      try {
        if (!run.isCurrent) {
          return;
        }
        final int delay = await run.clash.testDelay(name);
        if (!run.isCurrent) {
          return;
        }
        _delays[name] = delay;
        _unreachable.remove(name);
        used |= delay > 0;
      } on Object {
        if (run.isCurrent) {
          _delays.remove(name);
          _unreachable.add(name);
        }
      } finally {
        _releaseDelaySlot();
        if (run.isCurrent) {
          _testing.remove(name);
          notifyListeners();
        }
      }
    }

    await Future.wait(pending.map(test));
    return used;
  }

  Future<String?> testSpeed(String name) async {
    final _TestRun? run = await _openTestRun();
    if (run == null) {
      return L10n.t('内核未就绪，无法测速');
    }
    final String leaf = resolveNode(name);
    if (NodeLabels.officialId(leaf) == null) {
      return L10n.t('不是可测速的官方节点');
    }
    return _testSpeeds(run, <String>[leaf]);
  }

  Future<String?> testGroupSpeed(String group) async {
    if (!_testingSpeedGroups.add(group)) {
      return null;
    }
    notifyListeners();
    _TestRun? run;
    try {
      run = await _openTestRun();
      if (run == null) {
        return L10n.t('内核未就绪，无法测速');
      }
      final ProxyGroup? target = groupByName(group);
      if (target == null) {
        return null;
      }
      return await _testSpeeds(run, <String>[
        for (final String leaf in _leavesOf(target))
          if (NodeLabels.officialId(leaf) != null) leaf,
      ]);
    } finally {
      if (run == null || run.isCurrent) {
        _testingSpeedGroups.remove(group);
        notifyListeners();
      }
    }
  }

  Future<String?> _testSpeeds(_TestRun run, List<String> names) async {
    final List<String> queued = <String>[
      for (final String name in names)
        if (name.isNotEmpty && _testingSpeeds.add(name)) name,
    ];
    if (queued.isEmpty) {
      return null;
    }
    _speedFailed.removeAll(queued);
    notifyListeners();
    final Future<void> earlier = _speedLane;
    final Completer<void> gate = Completer<void>();
    _speedLane = gate.future;
    await earlier;
    try {
      return run.isCurrent ? await _measureSpeeds(run, queued) : null;
    } finally {
      gate.complete();
      if (run.isCurrent) {
        _testingSpeeds.removeAll(queued);
        notifyListeners();
      }
    }
  }

  // 面板单次请求最多处理这么多个节点（UserSpeedTestLog::MAX_BATCH），超出的既不放行也不拒绝
  static const int _speedReserveBatch = 256;

  Future<String?> _measureSpeeds(_TestRun run, List<String> names) async {
    final bool unlimited = _profileOf?.call()?.speedTestUnlimited ?? false;
    final List<String> candidates = <String>[
      for (final String name in names)
        if (unlimited || _speedQuota.canTest(name)) name,
    ];
    final int localBlocked = names.length - candidates.length;
    if (localBlocked > 0) {
      _testingSpeeds.removeAll(names.toSet().difference(candidates.toSet()));
      notifyListeners();
    }
    if (candidates.isEmpty) {
      return L10n.t('该节点 1 小时内测速已达 5 次，请稍后再试');
    }

    final PanelApiClient? api = run.api;
    if (api == null) {
      return L10n.t('无法连接面板，测速未开始');
    }
    final List<String> allowed = <String>[];
    final List<SpeedTestDenied> denied = <SpeedTestDenied>[];
    try {
      await run.clash.waitReady(
        proxyPort: SpeedProbeConfig.portOf(_settings.mixedPort),
        isCancelled: () => !run.isCurrent,
      );
      for (
        int start = 0;
        start < candidates.length;
        start += _speedReserveBatch
      ) {
        if (!run.isCurrent) {
          return null;
        }
        final SpeedTestReserveResult reserved = await api.reserveSpeedTest(
          candidates.sublist(
            start,
            min(start + _speedReserveBatch, candidates.length),
          ),
        );
        allowed.addAll(reserved.allowed);
        denied.addAll(reserved.denied);
      }
    } on ClashApiException catch (e) {
      if (!run.isCurrent) {
        return null;
      }
      Logger.instance.warn(_source, '测速入口未就绪: $e');
      return L10n.t('内核未就绪，无法测速');
    } on ApiException catch (e) {
      if (!run.isCurrent) {
        return null;
      }
      if (e.unauthorized) {
        await _rejectSession(api);
      }
      return e.message;
    }
    if (!run.isCurrent) {
      return null;
    }

    // 面板只对次数用尽的拒绝给出 reset_at；无权测试、非官方节点不算次数用尽
    int quotaBlocked = localBlocked;
    String? refusal;
    for (final SpeedTestDenied item in denied) {
      if (item.resetAt == null) {
        refusal ??= item.message;
      } else {
        quotaBlocked++;
        if (!unlimited) {
          _speedQuota.markExhausted(item.proxyName, item.resetAt!);
        }
      }
      _testingSpeeds.remove(item.proxyName);
    }
    if (denied.isNotEmpty) {
      notifyListeners();
    }
    if (allowed.isEmpty) {
      return denied.isNotEmpty
          ? denied.first.message
          : L10n.t('该节点 1 小时内测速已达 5 次，请稍后再试');
    }
    final String? notice = quotaBlocked > 0
        ? L10n.t('已跳过 {0} 个达到测速次数上限的节点', <Object>[quotaBlocked])
        : refusal;

    bool used = false;
    for (final String name in allowed) {
      if (!run.isCurrent) {
        return null;
      }
      try {
        await _measureSpeed(run, name, unlimited);
        if (!run.isCurrent) {
          return null;
        }
        used = true;
      } on ApiException catch (e) {
        if (run.isCurrent) {
          await _rejectSession(api);
        }
        return e.message;
      } on Object catch (e) {
        if (!run.isCurrent) {
          return null;
        }
        Logger.instance.warn(_source, '节点 $name 测速失败: $e');
        _speeds.remove(name);
        _speedFailed.add(name);
      } finally {
        if (run.isCurrent) {
          await run.clash.closeConnectionsVia(<String>{
            SpeedProbeConfig.groupName,
          });
        }
        if (run.isCurrent) {
          _testingSpeeds.remove(name);
          notifyListeners();
        }
      }
    }

    if (used) {
      unawaited(api.reportNodeUsed());
    }
    return notice;
  }

  // 会话失效抛 ApiException；其余失败（含面板拒收结果）抛给调用方记为「失败」
  Future<void> _measureSpeed(_TestRun run, String name, bool unlimited) async {
    if (_unloadedOf(<String>[name]).isNotEmpty &&
        !await _probe(<String>[name])) {
      throw NodeSpeedTestException(L10n.t('失败'));
    }
    if (!run.isCurrent) {
      return;
    }
    await run.clash.selectProxy(SpeedProbeConfig.groupName, name);
    if (!run.isCurrent) {
      return;
    }
    _speeds.remove(name);
    notifyListeners();
    final int speed = await _speedTester.download(
      proxyPort: SpeedProbeConfig.portOf(_settings.mixedPort),
      credential: SpeedProbeConfig.credential(run.clash.options.secret),
      onPeak: (int bps) {
        if (!run.isCurrent || bps <= (_speeds[name] ?? 0)) {
          return;
        }
        _speeds[name] = bps;
        notifyListeners();
      },
    );
    if (!run.isCurrent) {
      return;
    }
    if (speed <= 0) {
      throw NodeSpeedTestException(L10n.t('失败'));
    }
    _speeds[name] = speed;
    if (!unlimited) {
      _speedQuota.record(name);
    }
    notifyListeners();

    try {
      final SpeedTestReserveResult reported = await run.api!.reportSpeedTest(
        <({String proxyName, int bytesPerSecond})>[
          (proxyName: name, bytesPerSecond: speed),
        ],
      );
      if (!run.isCurrent ||
          reported.denied.isEmpty ||
          reported.allowed.isNotEmpty) {
        return;
      }
      final SpeedTestDenied refused = reported.denied.first;
      if (!unlimited) {
        _speedQuota.markExhausted(
          name,
          refused.resetAt ?? DateTime.now().add(SpeedTestQuotaStore.window),
        );
      }
      throw NodeSpeedTestException(refused.message);
    } on ApiException catch (e) {
      if (!run.isCurrent) {
        return;
      }
      if (e.unauthorized) {
        rethrow;
      }
      Logger.instance.warn(_source, '节点 $name 测速结果未写入面板: $e');
      return;
    }
  }

  Future<void> _ensureRemoteConfig(PanelApiClient api) async {
    if (!identical(api, _api)) {
      return;
    }
    if (_canUseOffline(api) && !_remoteFailed) {
      return;
    }
    if (_remote != null &&
        !_remoteStale &&
        _remoteProfile?.offlineUntil == null) {
      return;
    }
    if (_remote == null) {
      _hydrateRemoteFromCache();
      if (_remote != null && !_remoteStale) {
        return;
      }
    }
    try {
      await _fetchRemoteConfig(api);
    } on ProfileFormatException catch (e) {
      if (!identical(api, _api)) {
        return;
      }
      _emitConfigAlert(e);
      if (_useCachedRemote()) {
        _remoteStale = false;
        return;
      }
      rethrow;
    }
  }

  Future<void> _fetchRemoteConfig(PanelApiClient api) {
    final Future<void>? inFlight = _remoteFetch;
    if (inFlight != null) {
      return inFlight;
    }

    final Future<void> done = _fetchRemoteConfigOnce(api);
    _remoteFetch = done;
    return done.whenComplete(() {
      if (identical(_remoteFetch, done)) {
        _remoteFetch = null;
      }
    });
  }

  Future<void> _fetchRemoteConfigOnce(PanelApiClient api) async {
    final DateTime? until = _remoteCooldownUntil;
    if (until != null && DateTime.now().isBefore(until)) {
      if (_useCachedRemote()) {
        return;
      }
      await _waitForRemoteCooldown(until);
    }
    if (!identical(api, _api)) {
      return;
    }

    final int? fallbackProxyPort = _state == ConnectionPhase.connected
        ? _settings.mixedPort
        : null;

    // 本地已有配置时先探轻量 revision，未变则绝不打昂贵的 /config/clash；
    // 本地若尚无分组则不能跳过（戳不变也会一直空着）。
    if (_remote != null &&
        _configRevision.isNotEmpty &&
        (_remoteProfile?.offlineUntil == null ||
            _remoteProfile?.cacheBinding == api.cacheBinding) &&
        (_remoteProfile?.offlineUntil == null ||
            _remoteProfile!.offlineUntil!.difference(DateTime.now()) >
                const Duration(hours: 1)) &&
        _remoteHasProxyGroups &&
        !_remoteUpdateDue &&
        await _remoteRevisionUnchanged(api, fallbackProxyPort) &&
        (_remote!['proxy-providers'] as Map?)?.containsKey('ecy-panel-nodes') ==
            true) {
      if (identical(api, _api)) {
        _remoteStale = false;
        _panelOffline = false;
      }
      return;
    }
    if (!identical(api, _api)) {
      return;
    }
    try {
      final AppLanguage language = L10n.current;
      final RemoteProfile remote = await _fetchProfile(api, fallbackProxyPort);
      if (identical(api, _api)) {
        if (language != L10n.current) {
          await _fetchRemoteConfigOnce(api);
          return;
        }
        await _acceptRemote(remote, persist: true);
        _panelOffline = false;
      }
    } on ApiException catch (e) {
      if (!identical(api, _api)) {
        return;
      }
      if (e.transient && _useCachedRemote()) {
        _panelOffline = true;
        if (e.rateLimited) {
          _remoteCooldownUntil = DateTime.now().add(
            Duration(
              seconds: (e.retryAfterSeconds ?? _rateLimitFallback.inSeconds)
                  .clamp(1, 86400),
            ),
          );
        }
        return;
      }
      if (!e.rateLimited) {
        rethrow;
      }
      final int seconds = e.retryAfterSeconds ?? _rateLimitFallback.inSeconds;
      _remoteCooldownUntil = DateTime.now().add(
        Duration(seconds: seconds.clamp(1, 60)),
      );
      if (_useCachedRemote()) {
        return;
      }
      await _waitForRemoteCooldown(_remoteCooldownUntil!);
      if (!identical(api, _api)) {
        return;
      }
      try {
        final AppLanguage language = L10n.current;
        final RemoteProfile remote = await _fetchProfile(
          api,
          fallbackProxyPort,
        );
        if (identical(api, _api)) {
          if (language != L10n.current) {
            await _fetchRemoteConfigOnce(api);
            return;
          }
          await _acceptRemote(remote, persist: true);
        }
      } on ApiException catch (retryError) {
        if (!identical(api, _api)) {
          return;
        }
        if (retryError.rateLimited && _useCachedRemote()) {
          return;
        }
        if (retryError.rateLimited) {
          throw ApiException(
            L10n.t('面板繁忙，请稍后再试连接'),
            statusCode: 429,
            retryAfterSeconds: retryError.retryAfterSeconds,
          );
        }
        rethrow;
      }
    }
  }

  // 分页模式下面板只带了在用的节点：用户选过的若不在里面，按名取回并入，否则内核起来后这些选择落空
  Future<RemoteProfile> _fetchProfile(
    PanelApiClient api,
    int? fallbackProxyPort,
  ) async {
    final RemoteProfile remote = await api.fetchClashProfile(
      fallbackProxyPort: fallbackProxyPort,
    );
    final NodeCatalog? catalog = remote.catalog;
    if (catalog == null) {
      return remote;
    }
    final List<String> missing =
        <String>{
              ..._recentNodes,
              ...?_selectorSnapshot?.values,
              ...?_loadSelectorSnapshot()?.values,
            }
            .where(
              (String name) =>
                  NodeLabels.officialId(name) != null &&
                  !catalog.ranks.containsKey(name),
            )
            .take(_nodeNamesLimit)
            .toList();
    if (missing.isEmpty) {
      return remote;
    }
    final NodePage page = await api.fetchNodes(
      names: missing,
      fallbackProxyPort: fallbackProxyPort,
    );
    // 两次请求之间面板的节点变了，序号对不上：这一轮不并入，配置戳随之变化，下一次刷新再补
    return page.stamp == catalog.stamp ? remote.withNodes(page.nodes) : remote;
  }

  Future<bool> _remoteRevisionUnchanged(
    PanelApiClient api,
    int? fallbackProxyPort,
  ) async {
    try {
      final String remote = await api.fetchConfigRevision(
        fallbackProxyPort: fallbackProxyPort,
      );
      if (!identical(api, _api) || remote.isEmpty) {
        return false;
      }
      return remote == _configRevision;
    } on Object catch (e) {
      if (!identical(api, _api)) {
        return false;
      }
      if (e is ApiException && e.unauthorized) {
        rethrow;
      }
      // 探测不出来不等于没变，一律按「可能变了」处理；限流退避由 /config/clash 那段负责
      Logger.instance.warn(_source, '配置戳探测失败，将尝试拉全量: $e');
      return false;
    }
  }

  void _applyRemoteProfile(RemoteProfile remote, {required bool persist}) {
    final NodeCatalog? catalog = remote.catalog;
    if (catalog?.stamp != _remoteProfile?.catalog?.stamp) {
      _forgetBrowsed();
    } else if (catalog != null) {
      _browsed.removeWhere((String name, _) => catalog.ranks.containsKey(name));
    }
    _remoteProfile = remote;
    _remotePending = persist;
    if (persist) {
      _remoteFailed = false;
    }
    _configRevision = remote.revision;
    _remote = remote.config;
    _indexProxyExtra();
    _groupIcons = remote.groupIcons;
    _remoteStale = false;
    _remoteCooldownUntil = null;
    NodeLabels.configure(
      remote.flagRegex,
      remote.nodeLabels,
      remote.groupLabels,
    );
    NodeLabels.addNodeLabels(<String, String>{
      for (final CatalogNode node in _browsed.values) node.name: node.label,
    });
    unawaited(_warmNodeRegions(remote));
    // 这里不装配：装配会换掉控制面端口/secret，旧内核仍在跑时改掉这些字段
    // 没有意义，还会干扰并发重启。需要配置的一方自行 _rebuildProfile()
    _providerTotal = AssembledProfile.countRemoteProviders(remote.config);
    _armAuthorizationExpiry();
  }

  // 取词正则不可信，只能在后台 isolate 带超时预跑（见 NodeLabels.warmRegions）；
  // 预跑完再刷新一次界面，旗帜随之出现，界面 isolate 全程不碰这个正则
  Future<void> _warmNodeRegions(RemoteProfile remote) async {
    final List<Map<String, dynamic>> proxies = AssembledProfile.nodesOf(
      remote.config,
    );
    final Set<String> names = <String>{
      ...remote.nodeLabels.values,
      for (final Object? proxy in proxies)
        if (proxy is Map && proxy['name'] is String) proxy['name'] as String,
    };
    if (names.isEmpty) {
      return;
    }
    await NodeLabels.warmRegions(names);
    notifyListeners();
  }

  bool _hydrateRemoteFromCache() {
    if (_accountKey.isEmpty) {
      return false;
    }
    final RemoteProfile? cached = _panelCache.loadRemote(
      _accountKey,
      _api?.cacheKey,
    );
    if (cached == null) {
      return false;
    }
    try {
      ProfileInspector.ensureValid(cached.config);
    } on ProfileFormatException catch (e) {
      Logger.instance.warn(_source, '缓存的面板配置不规范，已忽略: $e');
      return false;
    }
    _applyRemoteProfile(cached, persist: false);
    _remoteStale = true;
    Logger.instance.info(_source, '已载入本地面板配置缓存，待空闲时刷新');
    return true;
  }

  bool _useCachedRemote() {
    final PanelApiClient? api = _api;
    if (api == null) {
      return false;
    }
    if (_canUseOffline(api)) {
      _remoteStale = false;
      return true;
    }
    if (!_hydrateRemoteFromCache() || !_canUseOffline(api)) {
      return false;
    }
    _remoteStale = false;
    return true;
  }

  bool _canUseOffline(PanelApiClient api) =>
      (_remoteProfile?.usableOffline(api) ?? false) &&
      _panelCache.loadProfile(_accountKey)?.deviceKickReason != 'remove';

  void _commitRemote() {
    final RemoteProfile? remote = _remoteProfile;
    if (_remotePending && remote != null && _accountKey.isNotEmpty) {
      _panelCache.saveRemote(_accountKey, remote, _api?.cacheKey);
      _remotePending = false;
    }
  }

  void _armAuthorizationExpiry() {
    _authorizationTimer?.cancel();
    final DateTime? until = _remoteProfile?.offlineUntil;
    final PanelApiClient? api = _api;
    if (until == null || api == null) {
      return;
    }
    Future<void> expire() async {
      if (!identical(api, _api)) {
        return;
      }
      // 面板续期可能就在到期前一刻，每分钟的同步还没赶上：先在线取一次配置，仍无授权才停
      if (!_canUseOffline(api)) {
        if (_profileRefreshInFlight) {
          _authorizationTimer = Timer(const Duration(seconds: 1), expire);
          return;
        }
        await refreshProfileFromPanel(refreshRules: false);
        if (!identical(api, _api)) {
          return;
        }
      }
      // Timer 按时长触发、判断按墙钟：墙钟回拨后还没到期，要重新计时，否则不会再自动停用
      if (_canUseOffline(api)) {
        _armAuthorizationExpiry();
        return;
      }
      final Future<void> stopping = shutdown();
      final int generation = _generation;
      await stopping;
      if (identical(api, _api) && generation == _generation) {
        _fail(L10n.t('本地配置授权已到期，请连接面板更新后重试'));
      }
    }

    final Duration delay = until.difference(DateTime.now());
    _authorizationTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      expire,
    );
  }

  Future<void> _rejectSession(PanelApiClient api) async {
    if (!identical(api, _api)) {
      return;
    }
    // 封禁、待删除账户访问放行名单外的接口同样回 401：先用同一令牌查账户状态，只有它也回 401 才清会话
    final Future<void> Function()? verify = onPanelSync;
    if (verify != null) {
      try {
        await verify();
        return;
      } on ApiException catch (e) {
        if (!e.unauthorized) {
          return;
        }
      } on Object {
        return;
      }
      if (!identical(api, _api)) {
        return;
      }
    }
    final Future<void> Function()? reject = onSessionRejected;
    if (reject != null) {
      await reject();
    } else {
      await shutdown(clearSession: true);
    }
  }

  Future<void> _syncPanel(PanelApiClient api) async {
    final DateTime? until = _remoteCooldownUntil;
    if (_panelSyncInFlight ||
        (until != null && DateTime.now().isBefore(until))) {
      return;
    }
    _panelSyncInFlight = true;
    try {
      await onPanelSync?.call();
      if (!identical(api, _api)) {
        return;
      }
      await refreshProfileFromPanel(refreshRules: false);
    } on ApiException catch (e) {
      if (identical(api, _api) && e.transient) {
        _panelOffline = true;
        if (e.rateLimited) {
          _remoteCooldownUntil = DateTime.now().add(
            Duration(
              seconds: (e.retryAfterSeconds ?? _rateLimitFallback.inSeconds)
                  .clamp(1, 86400),
            ),
          );
        }
      }
      if (identical(api, _api) && e.unauthorized) {
        await _rejectSession(api);
      }
    } finally {
      _panelSyncInFlight = false;
      if (identical(api, _api)) {
        notifyListeners();
      }
    }
  }

  void _startPanelSync(PanelApiClient api) {
    _panelSyncTimer ??= Timer.periodic(const Duration(minutes: 1), (_) {
      if (identical(api, _api) && !_userStopped) {
        unawaited(_syncPanel(api));
      }
    });
  }

  Future<void> _waitForRemoteCooldown(DateTime until) async {
    final Duration wait = until.difference(DateTime.now());
    if (wait <= Duration.zero) {
      return;
    }
    if (_state == ConnectionPhase.connecting) {
      final int seconds = wait.inSeconds.clamp(1, 60);
      _startupStage = L10n.t('面板繁忙，约 {0}s 后自动重试', <Object>[seconds]);
      notifyListeners();
    }
    await Future<void>.delayed(wait);
  }

  Future<void> _rebuildProfile({
    bool reuseControlPlane = false,
    bool refreshDirectAddresses = true,
  }) async {
    final int generation = _generation;
    final PanelApiClient? api = _api;
    final Map<String, dynamic>? remote = _remote;
    if (remote == null) {
      throw StateError(L10n.t('尚未获取面板配置'));
    }

    // 热载必须复用端口/secret：PUT /configs 不重建控制面，换掉会使 ClashApiClient 失联；
    // 冷启动 / 进程重启仍每次重新分配
    ClashApiOptions? options = _clashApiOptions;
    if (!reuseControlPlane || options == null) {
      options = ClashApiOptions(
        port: await _pickFreePort(),
        secret: _randomSecret(),
      );
    }

    if (generation != _generation || !identical(api, _api)) {
      return;
    }
    if (api != null && refreshDirectAddresses) {
      await api.ensureConfigDirectAddresses();
    }
    if (generation != _generation || !identical(api, _api)) {
      return;
    }
    _clashApiOptions = options;

    final Map<String, String> selectorDefaults = <String, String>{
      ...?_selectorSnapshot,
      ...?_loadSelectorSnapshot(),
    };
    _selectorSnapshot = selectorDefaults.isEmpty ? null : selectorDefaults;
    final Set<String>? loaded = _workingSet(remote, selectorDefaults.values);
    _loadedNodes = loaded;
    _profile = const ProfileAssembler().assemble(
      remote: NodeWorkingSet.restrict(remote, loaded, _probeNodes),
      template: LocalTemplate(
        _settings.toTemplateOptions(
          tunInterfaceName: _platform.tunInterfaceName,
          tunSetsSystemDns: _platform.tunSetsSystemDns,
          strictRouteNeedsTunIPv6: _platform.strictRouteNeedsTunIPv6,
          lanNamesViaSystemDns: _platform.lanNamesViaSystemDns,
          takeover: _takeover,
          supportsSystemProxy: _platform.supportsSystemProxy,
          extraTunExcludeAddresses: api?.configDirectCidrs ?? const <String>[],
        ),
        _clashApiOptions!,
      ),
      selectorDefaults: selectorDefaults,
    );

    _providerReady.clear();
    _providerTotal = _profile!.remoteProviderCount;
  }

  Future<void> _launchKernel(int generation, {bool validated = false}) async {
    _launching = true;
    try {
      await _launchKernelOnce(generation, validated);
    } finally {
      _launching = false;
    }
  }

  Future<void> _launchKernelOnce(int generation, bool validated) async {
    final AssembledProfile? profile = _profile;
    final ClashApiOptions? clashApi = _clashApiOptions;
    if (profile == null || clashApi == null) {
      throw StateError(L10n.t('配置尚未生成'));
    }

    await _kernel.bindSession(AppPaths.session);
    if (generation != _generation) {
      return;
    }
    AppPaths.touchSession();
    final String? invalid = _takeValidated() || validated
        ? null
        : await _kernel.validate(profile.validationJson);
    if (invalid != null) {
      final KernelException error = KernelException('配置校验未通过：$invalid');
      _emitConfigAlert(error);
      throw error;
    }
    // 校验期间可能已被 disconnect() 或更晚一轮取代，不该再去拉起内核
    if (generation != _generation) {
      return;
    }

    try {
      await _kernel.start(configJson: profile.json, clashApi: clashApi);
    } on Object {
      if (generation == _generation) {
        try {
          await _kernel.rollbackKernelUpgrade();
        } on Object catch (rollbackError) {
          Logger.instance.error(_source, '候选内核启动失败，回滚旧内核也失败', rollbackError);
        }
      }
      rethrow;
    } finally {
      // 重启不再先停内核，轮询会一直开着：旧内核在这之前退出报的 failed 说的是上一个
      // 进程，带进下面的 waitReady 会让刚拉起来的这个被当场判死；start 自身失败时原因已在异常里
      _kernelDiedDuringConnect = false;
    }

    final ClashApiClient clash;
    final ClashApiClient? existing = _clash;
    if (existing != null &&
        existing.options.port == clashApi.port &&
        existing.options.secret == clashApi.secret) {
      clash = existing;
    } else {
      existing?.close();
      clash = ClashApiClient(clashApi);
    }
    final int readySeconds = (60 + _providerTotal * 8).clamp(60, 180);
    clash.panelProviders = _panelProviderNames();
    try {
      await clash.waitReady(
        timeout: Duration(seconds: readySeconds),
        isCancelled: () =>
            generation != _generation || _kernelDiedDuringConnect,
      );
    } on Object {
      if (generation == _generation) {
        try {
          await _kernel.rollbackKernelUpgrade();
        } on Object catch (rollbackError) {
          Logger.instance.error(_source, '升级内核启动失败，回滚旧内核也失败', rollbackError);
        }
      }
      rethrow;
    }

    try {
      await _kernel.commitKernelUpgrade();
    } on Object catch (e) {
      // 备份残留不会影响当前候选内核运行；下次升级前仍会被事务检查处理。
      Logger.instance.warn(_source, '内核已就绪，但清理旧内核备份失败: $e');
    }

    if (generation != _generation) {
      if (!identical(clash, existing)) {
        clash.close();
        await _kernel.stop();
      }
      return;
    }
    _clash = clash;

    await clash.resetUrlTests(_urlTestGroupNames());
    await _refreshProxies(notify: false);
    await _restoreSelectorSnapshot();
    _captureSelectorSnapshot();
    _routeMode = (await _ensureTunApplied(
      clash,
      (profile.config['tun'] as Map)['enable'] == true,
    )).mode;

    if (generation != _generation) {
      await _abandonLaunch(clash);
      return;
    }

    await _applySystemProxy();

    // apply 与 disconnect 的 teardown 可能交错：本轮若已过期，必须停内核并还原代理，
    // 否则会留下系统代理 / TUN 占用，其它代理软件无法接管
    if (generation != _generation) {
      await _abandonLaunch(clash, restoreProxy: true);
      return;
    }

    _scheduleProxyRefresh();
    // 常驻时没有流量可统计，/connections 又是控制面最贵的一次调用，不必每秒问
    if (_takeover) {
      _scheduleStatsRefresh();
    }

    _connectedAt = _takeover ? (_connectedAt ?? DateTime.now()) : null;
    _commitRemote();
    _remoteFailed = false;
    _restartAttempt = 0;
    _persistRestart = false;
    _setState(
      _takeover ? ConnectionPhase.connected : ConnectionPhase.disconnected,
      error: null,
    );
  }

  // 开 TUN 失败时内核只记一行错误并把 tun.enable 抹成 false，装配与 PATCH 照常成功，只能读回运行态核对
  Future<({String mode, bool tunEnabled, int mixedPort})> _ensureTunApplied(
    ClashApiClient clash,
    bool expected,
  ) async {
    final ({String mode, bool tunEnabled, int mixedPort}) runtime = await clash
        .fetchRuntime();
    if (runtime.tunEnabled != expected) {
      throw ClashApiException('内核未能接管 TUN，详见内核日志');
    }
    return runtime;
  }

  Future<void> _abandonLaunch(
    ClashApiClient clash, {
    bool restoreProxy = false,
  }) async {
    if (identical(_clash, clash)) {
      _clash = null;
      clash.close();
      await _kernel.stop();
    }
    if (!restoreProxy || !_platform.supportsSystemProxy) {
      return;
    }
    // 新一轮已在 connecting/connected 时由它负责系统代理；此处还原会误伤
    if (_state == ConnectionPhase.connected ||
        _state == ConnectionPhase.connecting) {
      return;
    }
    try {
      await _platform.restoreSystemProxy();
    } on Exception catch (e) {
      Logger.instance.error(_source, '还原系统代理失败', e);
    }
  }

  Future<void> _applySystemProxy() async {
    if (!_platform.supportsSystemProxy) {
      return;
    }

    if (_takeover && _settings.systemProxyEnabled) {
      // 端口被其它程序（含同机其它账户）抢先占用时内核只记一条日志照常运行，
      // 系统代理再指过去，流量就交给了那个程序
      final int port = _settings.mixedPort;
      if ((await _clash?.fetchRuntime())?.mixedPort != port) {
        throw ClashApiException('混合端口 $port 已被其它程序占用，请在设置中更换端口后重新连接');
      }
      try {
        await _platform.setSystemProxy(
          port: port,
          bypass: resolvedSystemProxyBypass(
            _platform.platformId,
            _settings.systemProxyBypass,
          ),
        );
      } on Exception catch (e) {
        Logger.instance.warn(_source, '系统代理设置失败，连接照常，可手动设置代理: $e');
      }
    } else {
      try {
        await _platform.restoreSystemProxy();
      } on Exception catch (e) {
        Logger.instance.warn(_source, '还原系统代理失败: $e');
      }
    }
  }

  bool get _sysProxyGuardActive =>
      _state == ConnectionPhase.connected &&
      _settings.systemProxyEnabled &&
      _platform.supportsSystemProxy;

  bool get _tunRouteGuardActive =>
      _state == ConnectionPhase.connected && _takeover && _settings.tunEnabled;

  void _syncSysProxyGuard() {
    final bool active = _sysProxyGuardActive || _tunRouteGuardActive;
    if (active && _sysProxyGuardTimer != null) {
      return;
    }
    _sysProxyGuardTimer?.cancel();
    _sysProxyGuardTimer = null;
    if (!active) {
      return;
    }
    _sysProxyGuardTimer = Timer.periodic(
      _sysProxyGuardInterval,
      (_) => unawaited(runGuards()),
    );
  }

  @visibleForTesting
  Future<void> runGuards() async {
    await _guardSysProxy();
    await _guardTunRoutes();
  }

  // 外部（如 systemd-networkd 重配网卡）清掉 TUN 的策略路由后内核不会补回，此时显示已连接、流量却不进 TUN
  Future<void> _guardTunRoutes() async {
    final ClashApiClient? clash = _clash;
    if (!_tunRouteGuardActive ||
        clash == null ||
        _launching ||
        _restartTimer != null ||
        _tunRouteRepairing) {
      return;
    }
    final int generation = _generation;
    final bool? intact = await _tunRoutesIntact();
    if (intact == true) {
      _tunRouteRepairs = 0;
    }
    if (intact != false ||
        generation != _generation ||
        !identical(clash, _clash) ||
        !_tunRouteGuardActive) {
      return;
    }
    if (_tunRouteRepairs > 0) {
      _escalateTunRouteRepair(L10n.t('TUN 的路由规则反复被其它程序清除'));
      return;
    }
    _tunRouteRepairs = 1;
    _tunRouteRepairing = true;
    Logger.instance.warn(_source, 'TUN 的策略路由规则已被外部清除，正在关闭再重新开启 TUN');
    try {
      await clash.setTunEnabled(false);
      if (generation != _generation) {
        return;
      }
      await clash.setTunEnabled(true);
      if (generation != _generation) {
        return;
      }
      await _ensureTunApplied(clash, true);
      if (generation == _generation && await _tunRoutesIntact() == false) {
        throw ClashApiException('内核未能接管 TUN，详见内核日志');
      }
    } on Object catch (e) {
      if (generation == _generation && !_userStopped) {
        _escalateTunRouteRepair(e.toString());
      }
    } finally {
      _tunRouteRepairing = false;
    }
  }

  // 重启内核总能成功、重启退避随之清零，靠它收不了手，只能在这里记着已经升级过几步
  void _escalateTunRouteRepair(String reason) {
    if (_tunRouteRepairs >= 2) {
      _fail(reason);
      unawaited(_teardown());
      return;
    }
    _tunRouteRepairs = 2;
    _scheduleRestart(reason);
  }

  Future<bool?> _tunRoutesIntact() async {
    final Object? tun = _profile?.config['tun'];
    final Object? table = tun is Map ? tun['iproute2-table-index'] : null;
    try {
      return await _platform.tunRoutesIntact(
        tableIndex: table is int && table > 0 ? table : null,
      );
    } on Object catch (e) {
      Logger.instance.debug(_source, 'TUN 策略路由检查失败: $e');
      return null;
    }
  }

  Future<void> _guardSysProxy() async {
    if (!_sysProxyGuardActive) {
      return;
    }
    try {
      final SystemProxyState state = await _platform.systemProxyState();
      if (!_sysProxyGuardActive) {
        return;
      }
      final String expected = '127.0.0.1:${_settings.mixedPort}';
      if (state.enabled && state.server.trim().toLowerCase() == expected) {
        return;
      }
      Logger.instance.warn(_source, '系统代理已被改动，正在恢复');
      await _applySystemProxy();
    } on Object catch (e) {
      Logger.instance.debug(_source, '系统代理守卫检查失败: $e');
    }
  }

  static const Duration _trafficHistoryWindow = Duration(seconds: 60);
  static const Duration _statsInterval = Duration(seconds: 1);
  static const Duration _sysProxyGuardInterval = Duration(seconds: 60);

  // Linux 的系统代理写在用户会话的 gsettings 里，特权 helper 还原不了：
  // 退出前必须由界面自己断开并还原，否则代理一直指向已停掉的本地端口
  @override
  Future<AppExitResponse> didRequestAppExit() async {
    if (defaultTargetPlatform == TargetPlatform.linux) {
      try {
        await shutdown();
      } on Object catch (e) {
        Logger.instance.warn(_source, '退出前清理失败: $e');
      }
    }
    return AppExitResponse.exit;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool background =
        state != AppLifecycleState.resumed &&
        state != AppLifecycleState.inactive;
    if (background == _background) {
      return;
    }
    _background = background;
    if (background) {
      _trafficRank.flush();
    }
    if (_state == ConnectionPhase.connected) {
      _scheduleStatsRefresh();
      _scheduleProxyRefresh();
      return;
    }
    // 回到前台：这期间内核可能被通知栏磁贴单独开了起来，界面得认回这条隧道，
    // 否则会显示成未连接、用户也断不开
    if (!background && !busy) {
      unawaited(_clash == null ? adoptRunningKernel() : _syncTakeover());
    }
  }

  // 常驻内核在跑时 _clash 不为空，隧道仍可能被磁贴接管：控制面没变，只把接管状态认回来
  Future<void> _syncTakeover() async {
    final ClashApiClient? clash = _clash;
    final int generation = _generation;
    if (clash == null || _takeover) {
      return;
    }
    try {
      final ({String mode, bool tunEnabled, int mixedPort}) runtime =
          await clash.fetchRuntime();
      if (generation != _generation ||
          !identical(clash, _clash) ||
          busy ||
          !runtime.tunEnabled) {
        return;
      }
    } on Object catch (_) {
      return;
    }
    _userStopped = false;
    _takeover = true;
    _connectedAt = _kernel.startedAt;
    _scheduleStatsRefresh();
    _setState(ConnectionPhase.connected, error: null);
  }

  void _scheduleStatsRefresh() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(
      _statsInterval,
      (_) => unawaited(_pollStats()),
    );
    unawaited(_pollStats());
  }

  Future<void> _pollStats() async {
    final ClashApiClient? clash = _clash;
    // 流量按两次快照差分，取数慢于轮询间隔时并发进来会把同一段增量算两遍
    if (clash == null || _pollingStats) {
      return;
    }
    _pollingStats = true;

    try {
      final (KernelStats, List<Map<String, dynamic>>) result = await clash
          .fetchStats();
      if (!identical(clash, _clash)) {
        return;
      }
      _stats = result.$1;
      _applyConnections(result.$2);
      _statsUpdates.value++;
    } on Object catch (e) {
      Logger.instance.debug(_source, '刷新内核状态失败: $e');
    } finally {
      _pollingStats = false;
    }
  }

  // 内核只统计活跃连接（tunnel/statistic 的 Snapshot），关闭即从表里消失，
  // 历史连接没有任何接口取得到。客户端按快照差分自己补一份，上限就是这里的取值。
  static const int _closedConnectionsLimit = 1000;

  void _applyConnections(List<Map<String, dynamic>> snapshot) {
    _accumulateProxyTraffic(snapshot);

    final Set<String> alive = <String>{
      for (final Map<String, dynamic> item in snapshot) '${item['id']}',
    };

    for (final Map<String, dynamic> previous in _connections) {
      if (alive.contains('${previous['id']}')) {
        continue;
      }
      _closedConnections.insert(0, <String, dynamic>{
        ...previous,
        'closedAt': DateTime.now().toIso8601String(),
      });
    }
    if (_closedConnections.length > _closedConnectionsLimit) {
      _closedConnections.removeRange(
        _closedConnectionsLimit,
        _closedConnections.length,
      );
    }

    _connections = snapshot;
    _trafficRank.flush(force: false);
  }

  // 首页流量只算走代理的部分：内核的 /traffic 与 uploadTotal 是全量，
  // 直连（规则判给 direct 的国内流量、TUN 兜底的本机流量）也在里面。
  // 逐连接按 chains 的叶子出站类型过滤，再按两次快照的增量累加。
  void _accumulateProxyTraffic(List<Map<String, dynamic>> snapshot) {
    final Map<String, (int, int)> previous = <String, (int, int)>{
      for (final Map<String, dynamic> item in _connections)
        '${item['id']}': _counters(item),
    };

    int up = 0;
    int down = 0;
    for (final Map<String, dynamic> item in snapshot) {
      if (!_viaProxy(item)) {
        continue;
      }
      final String id = '${item['id']}';
      final (int, int) current = _counters(item);
      final (int, int) last = previous[id] ?? (0, 0);
      // 内核不会把计数器往回调，负值只可能来自 id 复用，按新连接算
      final int du = max(0, current.$1 - last.$1);
      final int dd = max(0, current.$2 - last.$2);
      up += du;
      down += dd;
      if (_trafficSampledAt != null && du + dd > 0) {
        final String host = _rankHost(item);
        _trafficRank.add(
          groups: _rankGroups(item),
          host: _isProxyServer(host) ? '' : host,
          bytes: du + dd,
        );
      }
    }

    if (up > 0 || down > 0) {
      _api?.markNodeUsed();
    }

    final DateTime now = DateTime.now();
    final DateTime? last = _trafficSampledAt;
    _trafficSampledAt = now;
    _trafficTotal = TrafficSample(
      _trafficTotal.up + up,
      _trafficTotal.down + down,
    );

    // 首个样本没有区间，算速率会得到无穷大
    if (last == null) {
      return;
    }
    final double seconds = now.difference(last).inMilliseconds / 1000;
    if (seconds <= 0) {
      return;
    }

    _traffic = TrafficSample(up ~/ seconds, down ~/ seconds, now);
    _trafficHistory.add(_traffic);
    final DateTime cutoff = now.subtract(_trafficHistoryWindow);
    while (_trafficHistory.isNotEmpty) {
      final DateTime? at = _trafficHistory.first.at;
      if (at != null && !at.isBefore(cutoff)) {
        break;
      }
      _trafficHistory.removeAt(0);
    }
  }

  static (int, int) _counters(Map<String, dynamic> item) => (
    (item['upload'] as num?)?.toInt() ?? 0,
    (item['download'] as num?)?.toInt() ?? 0,
  );

  Iterable<String> _rankGroups(Map<String, dynamic> item) {
    final Object? chains = item['chains'];
    if (chains is! List) {
      return const <String>[];
    }
    return <String>[
      for (final Object? hop in chains)
        if (hop is String && groupByName(hop) != null) hop,
    ];
  }

  static String _rankHost(Map<String, dynamic> item) {
    final Object? meta = item['metadata'];
    if (meta is! Map) {
      return '';
    }
    final String host = '${meta['host'] ?? ''}'.trim();
    if (host.isNotEmpty) {
      return host;
    }
    return '${meta['destinationIP'] ?? ''}'.trim();
  }

  bool _isProxyServer(String host) {
    final String item = host.trim().toLowerCase();
    return item.isNotEmpty && _proxyServers.contains(item);
  }

  // chains 是反转过的出站链，首项即最终落地的出站。按类型判断而不是按名字：名字归
  // 面板，类型是内核的 constant.AdapterType.String()。下面这几档都不出网，内核内建的
  // 五个出站（config.go 里的 DIRECT / REJECT / REJECT-DROP / COMPATIBLE / PASS）
  // 加上 DNS 劫持用的 Dns 正好齐了。
  bool _viaProxy(Map<String, dynamic> item) {
    final Object? chains = item['chains'];
    if (chains is! List || chains.isEmpty) {
      return false;
    }
    final String type = typeOf('${chains.first}').toLowerCase();
    return type.isNotEmpty &&
        !const <String>{
          'direct',
          'reject',
          'rejectdrop',
          'compatible',
          'pass',
          'dns',
        }.contains(type);
  }

  // urltest 组的选中项由内核按自身 interval 重算，不轮询界面上的「当前」会停在旧值。
  // 纯展示用途，界面不可见时整个停掉，回到前台再挂上
  void _scheduleProxyRefresh() {
    _proxyRefreshTimer?.cancel();
    _proxyRefreshTimer = null;
    if (_background) {
      return;
    }
    _proxyRefreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_pollProxies()),
    );
  }

  Future<void> _pollProxies() async {
    try {
      if (await _refreshProxies(notify: false)) {
        notifyListeners();
      }
    } on Object catch (e) {
      Logger.instance.debug(_source, '刷新出站列表失败: $e');
    }
  }

  // 与改密吊销 token 同一思路：变更记在面板，随 /user/profile 带回；
  // 客户端在已有的 profile 刷新里发现 revision 变了再拉配置，不单独挂起等待。
  void notePanelRevision(String revision) {
    if (revision.isEmpty || revision == _configRevision) {
      return;
    }
    // 内核没跑就不去打面板：只标过期。禁止提前把 _configRevision 写成新值，
    // 否则 ensure 时 revision 探测会误判「未变」而跳过拉全量。
    if (_api == null || _clash == null) {
      if (_remote != null) {
        _remoteStale = true;
      }
      return;
    }
    Logger.instance.info(_source, '检测到面板节点/配置变更，正在刷新');
    unawaited(refreshProfileFromPanel());
  }

  void languageChanged() {
    _configRevision = '';
    if (_api != null) {
      unawaited(refreshProfileFromPanel());
    }
  }

  /// 返回给人看的结果文案；已有刷新在进行时返回 null（调用方勿提示）。
  Future<String?> refreshProfileFromPanel({
    bool force = false,
    bool refreshRules = true,
  }) async {
    final int generation = _generation;
    final PanelApiClient? api = _api;
    if (api == null) {
      return L10n.t('更新失败：未登录');
    }
    if (_profileRefreshInFlight) {
      return null;
    }

    _profileRefreshInFlight = true;
    if (force) {
      _configRevision = '';
    }
    try {
      // 比对面板下发的原始配置，而不是装配后的 JSON：装配时会给控制面重新分配端口
      // 与 secret，装配结果每次都不一样，比出来永远是「有变更」，每次刷新都会重连
      final Map<String, dynamic>? previousRemote = _remote;
      final RemoteProfile? previousProfile = _remoteProfile;
      final AssembledProfile? activeProfile = _profile;
      final String? previous = previousRemote == null
          ? null
          : jsonEncode(previousRemote);

      try {
        await _fetchRemoteConfig(api);
      } on ProfileFormatException catch (e) {
        Logger.instance.warn(_source, '刷新面板配置失败: $e');
        _emitConfigAlert(e);
        return null;
      } on ApiException catch (e) {
        Logger.instance.warn(_source, '刷新面板配置失败: $e');
        if (identical(api, _api) && e.unauthorized) {
          await _rejectSession(api);
          return null;
        }
        if (_isFormatError(e)) {
          _emitConfigAlert(e);
          return null;
        }
        return L10n.t('更新失败：{0}', <Object>['$e']);
      }

      if (!identical(api, _api)) {
        return null;
      }
      // 拉取失败但退回了离线缓存：配置没更新过，不能报成「已是最新」
      if (_panelOffline) {
        return L10n.t('更新失败：{0}', <Object>[L10n.t('面板暂不可达')]);
      }
      final bool changed = jsonEncode(_remote) != previous;
      final bool running = _clash != null && _kernel.status.running;
      if (!running && _state == ConnectionPhase.connected) {
        await _restartKernel(L10n.t('面板会话有变更，正在重启内核'));
        return L10n.t('更新成功');
      }

      // 配置 JSON 未变也会走分流规则更新：规则文件内容可能已变而 url/interval 未变
      if (!changed) {
        if (running) {
          _commitRemote();
          if (refreshRules) await _refreshRuleProviders();
          if (_groups.isEmpty) {
            await _refreshProxies();
          }
        }
        if (_groups.isEmpty) {
          _applyProfileProxies();
          notifyListeners();
        }
        return running ? L10n.t('已是最新，分流规则已刷新') : L10n.t('已是最新');
      }

      if (!running) {
        Logger.instance.info(_source, '面板配置有变更，将在下次启动内核时生效');
        _applyProfileProxies();
        notifyListeners();
        return L10n.t('更新成功，下次启动内核时生效');
      }

      try {
        await _hotReloadPanelProfile(previousRemote: previousRemote);
      } on Object catch (e) {
        if (generation != _generation || !identical(api, _api)) {
          return null;
        }
        if (previousRemote != null &&
            previousProfile != null &&
            activeProfile != null &&
            AssembledProfile.canUpdateNodes(previousRemote, _remote!)) {
          try {
            await _kernel.persistConfig(activeProfile.json);
            if (generation != _generation || !identical(api, _api)) return null;
            await _clash!.updateProxyProviders(
              (activeProfile.config['proxy-providers'] as Map).keys
                  .cast<String>()
                  .where((String name) => name.startsWith('ecy-panel-')),
            );
          } on Object catch (rollbackError) {
            Logger.instance.warn(_source, '恢复节点文件失败: $rollbackError');
          }
          if (generation != _generation || !identical(api, _api)) return null;
          _profile = activeProfile;
          _applyRemoteProfile(previousProfile, persist: false);
          Logger.instance.warn(_source, '更新面板节点失败，保持当前连接: $e');
          return L10n.t('更新失败：{0}', <Object>['$e']);
        }
        Logger.instance.warn(_source, '热载面板配置失败，回退为重启内核: $e');
        await _restartKernel(L10n.t('面板配置有变更，正在重启内核'));
      }
      await _refreshRuleProviders();
      return L10n.t('更新成功');
    } finally {
      _profileRefreshInFlight = false;
    }
  }

  Future<void> _refreshRuleProviders() async {
    final ClashApiClient? clash = _clash;
    if (clash == null) {
      return;
    }
    final List<String> names = _httpRuleProviderNames();
    if (names.isEmpty) {
      return;
    }
    try {
      Logger.instance.info(_source, '正在更新分流规则（${names.length}）');
      await clash.updateRuleProviders(names);
    } on Object catch (e) {
      Logger.instance.warn(_source, '更新分流规则失败: $e');
    }
  }

  // 内核 UpdateGeoDatabases 在远端与本地 hash 相同时直接成功且不落盘，
  // 所以不能凭 HTTP 204 就报「已更新」，要看运行目录文件有没有真变。
  static const List<String> _geoDataFiles = <String>[
    'geoip.metadb',
    'GeoSite.dat',
    'ASN.mmdb',
  ];

  Future<String> updateGeoData() async {
    final ClashApiClient? clash = _clash;
    if (clash == null) {
      throw ClashApiException('内核未运行');
    }
    Logger.instance.info(_source, '正在更新 GeoData');
    final String before = _geoDataFingerprint();
    await clash.updateGeoDatabases();
    final String after = _geoDataFingerprint();
    // 桌面运行目录只有特权侧可读，指纹恒为空：内核已应答更新成功，不能报成「已是最新」
    if (before.isNotEmpty && before == after) {
      Logger.instance.info(_source, 'GeoData 已是最新');
      return L10n.t('已是最新');
    }
    Logger.instance.info(_source, 'GeoData 已更新');
    return L10n.t('更新成功');
  }

  String _geoDataFingerprint() {
    final StringBuffer buffer = StringBuffer();
    for (final String name in _geoDataFiles) {
      final File file = File(
        '${AppPaths.kernelRunDir}${Platform.pathSeparator}$name',
      );
      if (!file.existsSync()) {
        continue;
      }
      final FileStat stat = file.statSync();
      buffer.write(
        '$name:${stat.size}:${stat.modified.millisecondsSinceEpoch};',
      );
    }
    return buffer.toString();
  }

  List<String> _httpRuleProviderNames() {
    final Map<String, dynamic>? providers = _ruleProvidersMap();
    if (providers == null || providers.isEmpty) {
      return const <String>[];
    }
    return providers.entries
        .where((MapEntry<String, Object?> e) {
          final Object? value = e.value;
          return value is Map && value['type'] == 'http';
        })
        .map((MapEntry<String, Object?> e) => e.key)
        .toList(growable: false);
  }

  // 热载交特权侧：服务 / helper 净化落盘后让内核按文件重载，Android 在封装进程内热载；GUI 不向内核提交配置原文
  Future<void> _applyRuntimeConfig(String configJson) =>
      _kernel.reloadConfig(configJson);

  Future<void> _hotReloadPanelProfile({
    Map<String, dynamic>? previousRemote,
  }) async {
    final int generation = _generation;
    final bool nodesOnly =
        previousRemote != null &&
        AssembledProfile.canUpdateNodes(previousRemote, _remote!);
    // 认回后台内核时可能没有原配置，只对已知未启用 Fake-IP 的配置允许全量热载。
    final bool canHotReload = _profile?.usesFakeIp == false;
    _captureSelectorSnapshot();
    await _rebuildProfile(
      reuseControlPlane: true,
      refreshDirectAddresses: !nodesOnly,
    );
    if (generation != _generation) {
      return;
    }
    final AssembledProfile profile = _profile!;

    final String? invalid = _takeValidated()
        ? null
        : await _kernel.validate(profile.validationJson);
    if (generation != _generation) {
      return;
    }
    if (invalid != null) {
      final KernelException error = KernelException('配置校验未通过：$invalid');
      _emitConfigAlert(error);
      throw error;
    }

    // 官方内核全量热载会重置 fake-IP 分配位置，须正常退出保存后再启动。
    if (!nodesOnly && (!canHotReload || profile.usesFakeIp)) {
      await _restartKernel(L10n.t('面板配置有变更，正在重启内核'), validated: true);
      return;
    }

    Logger.instance.info(
      _source,
      nodesOnly ? '面板节点有变更，独立更新（不重启内核）' : '面板配置有变更，热载内核（不重启进程）',
    );
    await _kernel.persistConfig(profile.json);
    if (generation != _generation) {
      return;
    }
    if (nodesOnly) {
      await _clash!.updateProxyProviders(
        (profile.config['proxy-providers'] as Map).keys.cast<String>().where(
          (String name) => name.startsWith('ecy-panel-'),
        ),
      );
    } else {
      try {
        await _applyRuntimeConfig(profile.json);
      } on KernelException catch (e) {
        // 后台组件旧于界面时不认 kernel.reload：改走同样经特权侧净化的重启，不退回直接向内核提交配置原文
        if (!e.unsupported) {
          rethrow;
        }
        Logger.instance.warn(_source, '后台组件不支持热载，改为重启内核: $e');
        await _restartKernel(L10n.t('面板配置有变更，正在重启内核'));
        return;
      }
      await _clash!.resetUrlTests(_urlTestGroupNames());
    }

    await _refreshProxies(notify: false);
    if (!nodesOnly) await _restoreSelectorSnapshot();
    _commitRemote();
    notifyListeners();
  }

  List<String> _panelProviderNames() {
    final Object? providers = _profile?.config['proxy-providers'];
    return providers is Map
        ? providers.keys
              .cast<String>()
              .where((String name) => name.startsWith('ecy-panel-'))
              .toList()
        : const <String>[];
  }

  List<String> _urlTestGroupNames() {
    final Object? groups = _profile?.config['proxy-groups'];
    return groups is List
        ? <String>[
            for (final Object? group in groups)
              if (group is Map &&
                  group['type'] == 'url-test' &&
                  group['name'] is String)
                group['name'] as String,
          ]
        : const <String>[];
  }

  Future<bool> _refreshProxies({bool notify = true}) async {
    final ClashApiClient? clash = _clash;
    if (clash == null) {
      return false;
    }
    clash.panelProviders = _panelProviderNames();

    final (List<ProxyGroup>, List<ProxyNode>) result = await clash
        .fetchProxies();
    if (!identical(clash, _clash)) {
      return false;
    }
    final List<ProxyGroup> groups = _groups;
    final List<ProxyNode> nodes = _nodes;
    _groups = _inProfileOrder(result.$1);
    _nodes = result.$2;
    _mergeCatalog();
    bool changed = !_sameGroups(groups, _groups) || !_sameNodes(nodes, _nodes);

    // 内核有新延迟才覆盖。0 不删：断开后内核重载历史是空的，
    // 删掉会把用户刚测的延迟和网速一起从界面抹掉。
    for (final ProxyNode node in _nodes) {
      if (node.delay > 0) {
        changed |= _delays[node.name] != node.delay;
        _delays[node.name] = node.delay;
        changed |= _unreachable.remove(node.name);
      }
    }
    if (notify) {
      notifyListeners();
    }
    return changed;
  }

  static bool _sameGroups(List<ProxyGroup> a, List<ProxyGroup> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length).every(
        (int i) =>
            a[i].name == b[i].name &&
            a[i].type == b[i].type &&
            a[i].now == b[i].now &&
            listEquals(a[i].members, b[i].members),
      );

  static bool _sameNodes(List<ProxyNode> a, List<ProxyNode> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length).every(
        (int i) =>
            a[i].name == b[i].name &&
            a[i].type == b[i].type &&
            a[i].delay == b[i].delay &&
            a[i].udp == b[i].udp &&
            a[i].xudp == b[i].xudp,
      );

  // 只装了一部分节点时，内核给出的分组成员与节点表都不全：成员以面板配置为准，内核里没有的节点补成未测状态。
  // 装了哪些以内核实际报告的为准，不沿用上次装配算出的结果：界面重启后接管仍在运行的内核时没有装配这一步
  void _mergeCatalog() {
    final Map<String, dynamic>? remote = _listedRemote;
    if (remote == null) {
      return;
    }
    final _Catalog catalog = _catalogOf(remote);
    final Set<String> present = <String>{
      for (final ProxyNode node in _nodes) node.name,
    };
    if (catalog.configs.keys.every(present.contains)) {
      _loadedNodes = null;
      return;
    }
    _loadedNodes = <String>{
      for (final String name in catalog.configs.keys)
        if (present.contains(name)) name,
    };
    _groups = <ProxyGroup>[
      for (final ProxyGroup group in _groups)
        catalog.members[group.name] == null
            ? group
            : ProxyGroup(
                name: group.name,
                type: group.type,
                now: group.now,
                members: catalog.members[group.name]!,
              ),
    ];
    _nodes = <ProxyNode>[
      ..._nodes,
      for (final ProxyNode node in catalog.nodes)
        if (!present.contains(node.name)) node,
    ];
  }

  // 面板配置并上浏览缓存里的节点：界面按它列成员、认未装入的节点；装配与落盘只用 _remote
  Map<String, dynamic>? get _listedRemote {
    final Map<String, dynamic>? remote = _remote;
    final NodeCatalog? catalog = _remoteProfile?.catalog;
    if (remote == null || catalog == null || _browsed.isEmpty) {
      return remote;
    }
    if (!identical(_listedSource, remote)) {
      _listed = null;
      _listedSource = remote;
    }
    return _listed ??= catalog.merge(remote, _browsed.values).config;
  }

  void _forgetBrowsed() {
    _browsed.clear();
    _paging.clear();
    _listed = null;
  }

  void _addBrowsed(List<CatalogNode> nodes) {
    final NodeCatalog? catalog = _remoteProfile?.catalog;
    if (catalog == null) {
      return;
    }
    final Map<String, String> labels = <String, String>{};
    for (final CatalogNode node in nodes) {
      if (catalog.ranks.containsKey(node.name)) {
        continue;
      }
      _browsed.remove(node.name);
      _browsed[node.name] = node;
      labels[node.name] = node.label;
    }
    while (_browsed.length > _browsedLimit) {
      _browsed.remove(_browsed.keys.first);
    }
    if (labels.isEmpty) {
      return;
    }
    _listed = null;
    NodeLabels.addNodeLabels(labels);
    unawaited(
      NodeLabels.warmRegions(labels.keys).then((_) => notifyListeners()),
    );
    _indexProxyExtra();
  }

  // 用到的节点若只在浏览缓存里，先并入面板配置：装配、落盘缓存与离线启动都只读面板配置
  void _adoptBrowsed(Iterable<String> names) {
    final RemoteProfile? profile = _remoteProfile;
    final List<CatalogNode> nodes = <CatalogNode>[
      for (final String name in names) ?_browsed[name],
    ];
    if (profile == null || nodes.isEmpty) {
      return;
    }
    for (final CatalogNode node in nodes) {
      _browsed.remove(node.name);
    }
    _setRemoteNodes(profile.withNodes(nodes));
  }

  void _setRemoteNodes(RemoteProfile profile) {
    _remoteProfile = profile;
    _remote = profile.config;
    _validated = null;
    _indexProxyExtra();
    // 还没随内核启动落过盘的配置由 _commitRemote 一并保存
    if (!_remotePending && _accountKey.isNotEmpty) {
      _panelCache.saveRemote(_accountKey, profile, _api?.cacheKey);
    }
  }

  CatalogProvider? _catalogProviderOf(String group) {
    final Map<String, dynamic>? remote = _listedRemote;
    return remote == null ? null : _catalogOf(remote).files[group];
  }

  /// 分组在面板上的成员总数；没有节点目录或该组已带全时就是当前列出的个数
  int memberTotalOf(ProxyGroup group) {
    final Map<String, dynamic>? remote = _listedRemote;
    final _Catalog? catalog = remote == null ? null : _catalogOf(remote);
    final CatalogProvider? file = catalog?.files[group.name];
    return file == null
        ? group.members.length
        : file.total + (catalog!.extras[group.name] ?? 0);
  }

  bool hasMoreNodes(String group, {String query = ''}) {
    final CatalogProvider? file = _catalogProviderOf(group);
    if (file == null) {
      return false;
    }
    final _NodePaging? paging = _paging[file.key];
    if (query.isNotEmpty) {
      return paging != null && paging.query == query && paging.searchMore;
    }
    return paging?.more ?? file.head < file.total;
  }

  bool loadingNodes(String group) =>
      _paging[_catalogProviderOf(group)?.key]?.loading ?? false;

  String? nodesErrorOf(String group) =>
      _paging[_catalogProviderOf(group)?.key]?.error;

  /// 面板按 [query] 搜到的节点：显示名是译名时本地按名称过滤会漏掉按原名命中的
  bool nodeMatched(String group, String member, String query) {
    final _NodePaging? paging = _paging[_catalogProviderOf(group)?.key];
    return paging != null &&
        paging.query == query &&
        paging.hits.contains(member);
  }

  /// 向面板取该分组的下一页成员；[query] 非空时取名称含它的成员。取到的节点进浏览缓存
  Future<void> loadMoreNodes(String group, {String query = ''}) async {
    final PanelApiClient? api = _api;
    final NodeCatalog? catalog = _remoteProfile?.catalog;
    final CatalogProvider? file = _catalogProviderOf(group);
    if (api == null || catalog == null || file == null) {
      return;
    }
    final _NodePaging paging = _paging.putIfAbsent(
      file.key,
      () => _NodePaging(file.head, file.head < file.total),
    );
    final bool searching = query.isNotEmpty;
    if (paging.loading) {
      if (searching) {
        paging.queued = query;
      }
      return;
    }
    if (searching && paging.query != query) {
      paging
        ..query = query
        ..searchOffset = 0
        ..searchMore = true
        ..hits.clear();
    }
    if (!(searching ? paging.searchMore : paging.more)) {
      return;
    }
    paging
      ..loading = true
      ..error = null;
    notifyListeners();
    try {
      final NodePage page = await api.fetchNodes(
        provider: file.key,
        offset: searching ? paging.searchOffset : paging.offset,
        limit: _nodePageSize,
        search: query,
        fallbackProxyPort: _state == ConnectionPhase.connected
            ? _settings.mixedPort
            : null,
      );
      if (!identical(api, _api) || !identical(_paging[file.key], paging)) {
        return;
      }
      if (page.stamp != catalog.stamp) {
        // 面板的节点或模板已变，这一页对不上手里的目录
        _forgetBrowsed();
        unawaited(refreshProfileFromPanel(force: true));
      } else {
        if (searching) {
          paging
            ..searchOffset += _nodePageSize
            ..searchMore = page.more
            ..hits.addAll(page.nodes.map((CatalogNode node) => node.name));
        } else {
          paging
            ..offset += _nodePageSize
            ..more = page.more;
        }
        _addBrowsed(page.nodes);
      }
      if (_clash != null) {
        await _refreshProxies(notify: false);
      } else {
        _applyProfileProxies();
      }
    } on ApiException catch (e) {
      if (!identical(api, _api)) {
        return;
      }
      paging.error = e.message;
      if (e.unauthorized) {
        await _rejectSession(api);
      }
    } on Object catch (e) {
      Logger.instance.debug(_source, '刷新出站列表失败: $e');
    } finally {
      paging.loading = false;
      if (identical(api, _api)) {
        notifyListeners();
        final String? queued = paging.queued;
        paging.queued = null;
        if (queued != null && identical(_paging[file.key], paging)) {
          unawaited(loadMoreNodes(group, query: queued));
        }
      }
    }
  }

  // 面板配置里各分组的完整成员与全部节点。节点很多时每轮刷新重算太慢，按配置对象缓存
  _Catalog _catalogOf(Map<String, dynamic> remote) {
    final _Catalog? cached = _catalog;
    if (cached != null && identical(cached.source, remote)) {
      return cached;
    }
    final List<Map<String, dynamic>> proxies = AssembledProfile.nodesOf(remote);
    final Object? groups = remote['proxy-groups'];
    final NodeCatalog? paged = _remoteProfile?.catalog;
    final Map<String, List<String>> members = <String, List<String>>{
      if (groups is List)
        for (final Object? group in groups)
          if (group is Map<String, dynamic> && group['name'] is String)
            group['name'] as String: _membersByNodeName(
              AssembledProfile.membersOf(remote, group),
            ),
    };
    final Map<String, CatalogProvider> files = <String, CatalogProvider>{
      if (groups is List && paged != null)
        for (final Object? group in groups)
          if (group is Map<String, dynamic> &&
              group['name'] is String &&
              group['use'] is List)
            for (final Object? file in group['use'] as List)
              if (paged.providers[file] case final CatalogProvider entry)
                group['name'] as String: entry,
    };
    return _catalog = (
      source: remote,
      configs: <String, Map<String, dynamic>>{
        for (final Map<String, dynamic> proxy in proxies)
          if (proxy['name'] is String) proxy['name'] as String: proxy,
      },
      nodes: <ProxyNode>[
        for (final Map<String, dynamic> proxy in proxies)
          if (proxy['name'] is String)
            ProxyNode(
              name: proxy['name'] as String,
              type: _displayType(proxy['type'] as String? ?? ''),
              delay: 0,
            ),
      ],
      members: members,
      files: files,
      extras: <String, int>{
        for (final String group in files.keys)
          group: members[group]!
              .where(
                (String member) =>
                    !paged!.ranks.containsKey(member) &&
                    !_browsed.containsKey(member),
              )
              .length,
      },
    );
  }

  // 交给内核的只有在用的节点：校验、落盘、启动都用同一份，整份节点目录不离开界面进程
  Set<String>? _workingSet(
    Map<String, dynamic> remote,
    Iterable<String> selected,
  ) => NodeWorkingSet.select(
    remote,
    pinned: <String>[..._recentNodes, ...selected],
  );

  List<String> _unloadedOf(Iterable<String> names) {
    final Set<String>? loaded = _loadedNodes;
    final Map<String, dynamic>? remote = _listedRemote;
    if (remote == null || (loaded == null && _browsed.isEmpty)) {
      return const <String>[];
    }
    final Map<String, Map<String, dynamic>> configs = _catalogOf(remote)
        .configs;
    // 已知节点全部装入时（loaded 为 null），浏览缓存里的仍是未装入
    return <String>[
      for (final String name in names)
        if (configs.containsKey(name) &&
            !(loaded?.contains(name) ?? !_browsed.containsKey(name)))
          name,
    ];
  }

  // 把选中的未装入节点装进内核：沿用「只更新节点」的做法，重写节点文件后让内核按文件重载，不重启内核
  Future<void> _loadNodes(List<String> names) async {
    final ClashApiClient? clash = _clash;
    final List<String> unloaded = _unloadedOf(names);
    final RemoteProfile? adopted = _remoteProfile;
    if ((_loadedNodes == null && unloaded.isEmpty) ||
        clash == null ||
        _remote == null) {
      return;
    }
    _adoptBrowsed(unloaded);
    final Map<String, Map<String, dynamic>> configs = _catalogOf(_listedRemote!)
        .configs;
    final List<String> nodes = <String>[
      for (final String name in names)
        if (configs.containsKey(name)) name,
    ];
    final List<String> previous = List<String>.of(_recentNodes);
    _recentNodes
      ..removeWhere(nodes.contains)
      ..insertAll(0, nodes);
    if (_recentNodes.length > _recentNodeLimit) {
      _recentNodes.removeRange(_recentNodeLimit, _recentNodes.length);
    }
    if (unloaded.isEmpty) {
      return;
    }
    _validated = null;
    try {
      await _rebuildProfile(
        reuseControlPlane: true,
        refreshDirectAddresses: false,
      );
      await _kernel.persistConfig(_profile!.json);
      if (identical(clash, _clash)) {
        await clash.updateProxyProviders(_panelProviderNames());
      }
    } on Object {
      // 内核拒收的节点不能留在装入名单里：之后每次装配都会带上它，重启内核时整份配置校验不过
      _recentNodes
        ..clear()
        ..addAll(previous);
      if (adopted != null && !identical(adopted, _remoteProfile)) {
        _setRemoteNodes(adopted);
      }
      if (identical(clash, _clash)) {
        await _rebuildProfile(
          reuseControlPlane: true,
          refreshDirectAddresses: false,
        );
        await _kernel.persistConfig(_profile!.json);
      }
      rethrow;
    }
  }

  // 未装入的节点临时放进探测节点文件再测：只重载这一个文件，分组用的节点文件及其上的连接不受影响
  Future<bool> _probe(List<String> names) async {
    final ClashApiClient? clash = _clash;
    if (clash == null || _remote == null || _launching) {
      return false;
    }
    _adoptBrowsed(names);
    final Map<String, Map<String, dynamic>> configs = _catalogOf(_listedRemote!)
        .configs;
    try {
      _probeNodes = <Object?>[
        for (final String name in names)
          if (configs.containsKey(name)) configs[name],
      ];
      await _rebuildProfile(
        reuseControlPlane: true,
        refreshDirectAddresses: false,
      );
      await _kernel.persistConfig(_profile!.json);
      if (!identical(clash, _clash)) {
        return false;
      }
      await clash.updateProxyProviders(<String>[NodeWorkingSet.probeProvider]);
      return identical(clash, _clash);
    } on Object catch (e) {
      Logger.instance.warn(_source, '装入待测节点失败: $e');
      return false;
    }
  }

  // /proxies 的分组来自内核里的一张 Go map，encoding/json 序列化时按键名排序输出，
  // 与面板 proxy-groups 的书写顺序无关。连上之后直接照单全收，界面上的分组顺序就会
  // 和未连接时对不上。面板那份配置才是权威顺序，按它重排。
  List<ProxyGroup> _inProfileOrder(List<ProxyGroup> groups) {
    final Object? configured = _remote?['proxy-groups'];
    if (configured is! List) {
      return <ProxyGroup>[
        for (final ProxyGroup group in groups) _withNodesSortedByName(group),
      ];
    }

    final Map<String, ProxyGroup> pending = <String, ProxyGroup>{
      for (final ProxyGroup group in groups) group.name: group,
    };
    final List<ProxyGroup> ordered = <ProxyGroup>[];
    for (final Object? entry in configured) {
      if (entry is! Map<String, dynamic>) {
        continue;
      }
      final ProxyGroup? group = pending.remove(entry['name']);
      if (group != null) {
        ordered.add(_withNodesSortedByName(group));
      }
    }

    // GLOBAL 这类内核自建分组不在面板配置里，缀在后面，不能丢
    ordered.addAll(
      groups
          .where((ProxyGroup g) => pending.containsKey(g.name))
          .map(_withNodesSortedByName),
    );
    return ordered;
  }

  static ProxyGroup _withNodesSortedByName(ProxyGroup group) {
    final List<String> members = _membersByNodeName(group.members);
    if (identical(members, group.members)) {
      return group;
    }
    return ProxyGroup(
      name: group.name,
      type: group.type,
      now: group.now,
      members: members,
    );
  }

  // 只重排官方客户端的 node-{id}；DIRECT / 策略组引用保持面板原位
  static List<String> _membersByNodeName(List<String> members) {
    final List<int> slots = <int>[];
    final List<String> nodes = <String>[];
    for (int i = 0; i < members.length; i++) {
      if (!members[i].startsWith('node-')) {
        continue;
      }
      slots.add(i);
      nodes.add(members[i]);
    }
    if (nodes.length < 2) {
      return members;
    }
    nodes.sort(NodeLabels.compareName);
    final List<String> out = List<String>.of(members);
    for (int i = 0; i < slots.length; i++) {
      out[slots[i]] = nodes[i];
    }
    return List<String>.unmodifiable(out);
  }

  bool get _remoteHasProxyGroups {
    final Object? groups = _remote?['proxy-groups'];
    return groups is List && groups.isNotEmpty;
  }

  bool get _remoteUpdateDue {
    final RemoteProfile? remote = _remoteProfile;
    final DateTime? fetchedAt = remote?.offlineIssuedAt;
    return fetchedAt == null ||
        DateTime.now().difference(fetchedAt) >=
            (remote!.updateInterval ?? _defaultProfileUpdateInterval);
  }

  void _indexProxyExtra() {
    final Map<String, String> networks = <String, String>{};
    final Map<String, bool> udps = <String, bool>{};
    final Map<String, String> tlsTypes = <String, String>{};
    final Set<String> servers = <String>{};
    final Map<String, dynamic>? remote = _listedRemote;
    final Object? proxies = remote == null
        ? null
        : AssembledProfile.nodesOf(remote);
    if (proxies is List) {
      for (final Object? proxy in proxies) {
        if (proxy is! Map<String, dynamic>) {
          continue;
        }
        final String name = proxy['name'] as String? ?? '';
        if (name.isEmpty) {
          continue;
        }
        final String network = (proxy['network'] as String? ?? '').trim();
        if (network.isNotEmpty) {
          networks[name] = network;
        }
        if (proxy['udp'] is bool) {
          udps[name] = proxy['udp'] as bool;
        }
        final String? tlsType = _tlsTypeOf(proxy);
        if (tlsType != null) {
          tlsTypes[name] = tlsType;
        }
        final String server = '${proxy['server'] ?? ''}'.trim().toLowerCase();
        if (server.isNotEmpty) {
          servers.add(server);
        }
      }
    }
    _proxyNetwork = networks;
    _proxyUdp = udps;
    _proxyTls = tlsTypes;
    _proxyServers = servers;
  }

  // clash 段里 hysteria / tuic / anytls 不写 tls: true，但协议本身就是 TLS
  static String? _tlsTypeOf(Map<String, dynamic> proxy) {
    final Object? realityOpts = proxy['reality-opts'];
    if (realityOpts is Map && realityOpts.isNotEmpty) {
      return 'REALITY';
    }
    if (proxy['tls'] == true) {
      return 'TLS';
    }
    switch ((proxy['type'] as String? ?? '').toLowerCase()) {
      case 'hysteria':
      case 'hysteria2':
      case 'tuic':
      case 'anytls':
        return 'TLS';
      default:
        return null;
    }
  }

  void _applyProfileProxies() {
    final Map<String, dynamic>? remote = _listedRemote;
    _nodes = remote != null
        ? <ProxyNode>[
            for (final Object? proxy in AssembledProfile.nodesOf(remote))
              if (proxy is Map<String, dynamic> &&
                  (proxy['name'] as String? ?? '').isNotEmpty)
                ProxyNode(
                  name: proxy['name'] as String,
                  type: _displayType(proxy['type'] as String? ?? ''),
                  delay: 0,
                ),
          ]
        : const <ProxyNode>[];

    _groups = remote?['proxy-groups'] is List
        ? <ProxyGroup>[
            for (final Object? group in remote!['proxy-groups'] as List)
              if (group is Map<String, dynamic> &&
                  group['hidden'] != true &&
                  (group['name'] as String? ?? '').isNotEmpty)
                ProxyGroup(
                  name: group['name'] as String,
                  type: _displayType(group['type'] as String? ?? ''),
                  // 选中项一律留空：内核启动时会从 cache.db 恢复用户上次的选择，
                  // url-test 组更是要测完延迟才定。拿配置里的首个成员顶替，界面就会
                  // 把每个分组都显示成同一个节点，而这与实际选中项无关。
                  now: '',
                  members: _membersByNodeName(
                    AssembledProfile.membersOf(remote, group),
                  ),
                ),
          ]
        : const <ProxyGroup>[];
  }

  // 配置段是 mihomo 配置名（`ss` / `vless`），Clash API 是内核 AdapterType.String()
  // （`Shadowsocks` / `Vless`）。两个来源必须归一，否则未连接和连上后标签会跳；键按
  // 小写查，两种写法共用一条。表里没有的原样透出，内核展示名本身就是官方写法。
  static String _displayType(String configType) =>
      _displayTypes[configType.toLowerCase()] ?? configType;

  static const Map<String, String> _displayTypes = <String, String>{
    'direct': 'Direct',
    'reject': 'Reject',
    'rematch': 'Rematch',
    'dns': 'DNS',
    'ss': 'Shadowsocks',
    'ssr': 'ShadowsocksR',
    'snell': 'Snell',
    'socks5': 'SOCKS5',
    'http': 'HTTP',
    'vmess': 'VMess',
    'vless': 'VLESS',
    'trojan': 'Trojan',
    'hysteria': 'Hysteria',
    'hysteria2': 'Hysteria2',
    'wireguard': 'WireGuard',
    'tuic': 'TUIC',
    'ssh': 'SSH',
    'mieru': 'Mieru',
    'anytls': 'AnyTLS',
    'sudoku': 'Sudoku',
    'masque': 'MASQUE',
    'trusttunnel': 'TrustTunnel',
    'shadowquic': 'ShadowQuic',
    'openvpn': 'OpenVPN',
    'tailscale': 'Tailscale',
    'gost-relay': 'GostRelay',
    'select': 'Selector',
    'url-test': 'URLTest',
    'fallback': 'Fallback',
    'load-balance': 'LoadBalance',
    'relay': 'Relay',
  };

  void _onKernelStatus(KernelStatus status) {
    // 通知栏磁贴关掉的内核：是用户的意思，重连等于不让人关
    if (status.stoppedByUser) {
      Logger.instance.info(_source, '内核已在界面外被停止');
      unawaited(shutdown());
      return;
    }
    if (status.state != KernelState.failed || _userStopped) {
      return;
    }
    // 主动连接/重启期间禁止 scheduleRestart：它会抬 generation 并杀掉仍在
    // 下载规则集的进程，表现为卡「正在连接」直到控制面超时。
    if (_launching) {
      _kernelDiedDuringConnect = true;
      Logger.instance.warn(
        _source,
        '连接过程中内核退出：${status.message ?? status.exitCode}',
      );
      return;
    }

    // 被系统主动终止的不重启：那是用户切到了别的 VPN，重连只会反复弹授权框抢回槽位
    if (!status.retriable) {
      _fail(L10n.message(status.message ?? '内核已被系统停止'));
      unawaited(_teardown());
      return;
    }

    _scheduleRestart(
      L10n.message(status.message ?? '内核异常退出（退出码 ${status.exitCode ?? ''}）'),
    );
  }

  // 等待期间状态留在 connecting：既让界面显示进度，也挡住 startStandby 抢走 generation
  void _scheduleAutoConnect(int generation, String reason) {
    _autoConnectTimer?.cancel();
    _autoConnectTimer = null;
    if (_autoConnectAttempt >= _backoff.length) {
      _autoConnectAttempt = _backoff.length - 1;
    }

    final Duration delay = _backoff[_autoConnectAttempt];
    _autoConnectAttempt++;
    Logger.instance.warn(
      _source,
      '$reason，${delay.inSeconds} 秒后第 $_autoConnectAttempt 次重试自动连接',
    );
    _startupStage = L10n.t('网络尚未就绪，正在等待重试');
    _setState(ConnectionPhase.connecting, error: null);
    _autoConnectTimer = Timer(delay, () {
      _autoConnectTimer = null;
      if (generation != _generation) {
        return;
      }
      unawaited(_attemptConnect(autoRetry: true));
    });
  }

  void _scheduleRestart(String reason) {
    if (_restartTimer != null || _userStopped) {
      return;
    }

    if (_restartAttempt >= _backoff.length) {
      if (_persistRestart) {
        // 面板正常改配置：继续按最长间隔重试，直到连上或用户断开
        _restartAttempt = _backoff.length - 1;
      } else {
        _fail(
          L10n.t('{0}；连续重启 {1} 次仍未成功，已停止重试', <Object>[reason, _backoff.length]),
        );
        unawaited(_teardown());
        return;
      }
    }

    final Duration delay = _backoff[_restartAttempt];
    _restartAttempt++;
    Logger.instance.warn(
      _source,
      '$reason，${delay.inSeconds} 秒后第 $_restartAttempt 次重启',
    );
    if (_persistRestart) {
      _startupStage = L10n.t('面板配置有变更，正在重启内核');
    }
    if (_takeover) {
      _setState(ConnectionPhase.connecting, error: reason);
    }

    _restartTimer = Timer(delay, () async {
      _restartTimer = null;
      if (_userStopped) {
        return;
      }

      final int generation = ++_generation;
      _kernelDiedDuringConnect = false;
      _captureSelectorSnapshot();
      try {
        await _teardown(restarting: true);
        if (generation != _generation || _userStopped) {
          return;
        }
        // 面板变更持续重试时尽量拉最新配置，避免重试用到过期节点列表
        final PanelApiClient? api = _api;
        if (_persistRestart && api != null) {
          try {
            await _ensureRemoteConfig(api);
          } on ApiException catch (e) {
            Logger.instance.warn(_source, '重试前刷新面板配置失败: $e');
            if (e.unauthorized) {
              await _rejectSession(api);
              return;
            }
          }
        }
        await _rebuildProfile();
        await _launchKernel(generation);
      } on Object catch (e) {
        if (generation != _generation || _userStopped) {
          return;
        }
        if (_isUnrecoverableConfigError(e)) {
          _persistRestart = false;
          if (_isFormatError(e)) {
            _emitConfigAlert(e);
          }
          _fail(e.toString());
          await _teardown();
          return;
        }
        _scheduleRestart(L10n.t('重启失败：{0}', <Object>[e]));
      }
    });
  }

  // restarting 表示内核随即会带新配置重新启动：此时不停内核（见下），不还原系统
  // 代理（马上要按同一端口设回去，中间还原一次只会让浏览器多断一次、这段时间还
  // 绕过代理直连），也不发通知，避免界面在断开态上闪一帧
  Future<void> _teardown({
    bool restarting = false,
    bool clearSession = false,
    String session = '',
  }) async {
    final int generation = _generation;
    _proxyRefreshTimer?.cancel();
    _proxyRefreshTimer = null;
    _sysProxyGuardTimer?.cancel();
    _sysProxyGuardTimer = null;
    _statsTimer?.cancel();
    _statsTimer = null;

    _trafficRank.flush();
    _clash?.close();
    _clash = null;

    // 三端的 kernel.start 都自带「先停后起」（Windows 与 Unix helper 的
    // kernelManager.start 写完配置就调 k.stop()，Android 的 startOrReloadService
    // 就地重载），重启路径上再停一次纯属多余。Android 上那一次还会连 VpnService
    // 一起停掉，逼得随后的 start 在后台调 startForegroundService 被 API 31+ 拒
    Object? stopError;
    try {
      if (clearSession) {
        await _kernel.clearSession(session);
      } else if (!restarting) {
        await _kernel.stop();
      }
    } on Object catch (e) {
      stopError = e;
    }
    if (generation != _generation) {
      if (stopError != null) {
        throw stopError;
      }
      return;
    }

    // 下一轮不接管出口（断开，或常驻重载）时同样要立刻交还系统代理，不能等到
    // 内核重载完：那期间浏览器仍指着一个已经停掉的 mixed 口。停内核失败也要还原
    if ((!restarting || !_takeover) && _platform.supportsSystemProxy) {
      try {
        await _platform.restoreSystemProxy();
      } on Object catch (e) {
        Logger.instance.error(_source, '还原系统代理失败', e);
      }
    }
    if (!restarting || !_takeover) {
      _connectedAt = null;
    }
    if (stopError != null) {
      throw stopError;
    }

    _traffic = const TrafficSample(0, 0);
    _trafficTotal = const TrafficSample(0, 0);
    _trafficSampledAt = null;
    _trafficHistory.clear();
    _stats = KernelStats.empty;
    _connections = const <Map<String, dynamic>>[];
    _closedConnections.clear();
    _testing.clear();
    _testingGroups.clear();
    _testingSpeeds.clear();
    _testingSpeedGroups.clear();
    _applyProfileProxies();

    if (!restarting) {
      _selectorSnapshot = null;
      notifyListeners();
    }
  }

  void _forgetTestResults() {
    _delays.clear();
    _unreachable.clear();
    _speeds.clear();
    _speedFailed.clear();
  }

  void _setState(ConnectionPhase state, {required String? error}) {
    final bool becameConnected =
        state == ConnectionPhase.connected &&
        _state != ConnectionPhase.connected;
    _state = state;
    _api?.fallbackProxyPort = state == ConnectionPhase.connected
        ? _settings.mixedPort
        : null;
    _api?.fallbackProxyCredential = mixedProxyCredential;
    _api?.reportConnected = state == ConnectionPhase.connected;
    if (becameConnected) {
      final PanelApiClient? api = _api;
      _armAuthorizationExpiry();
      if (api != null) {
        _startPanelSync(api);
        unawaited(api.reportNodeUsed());
      }
    }
    _error = error;
    if (state != ConnectionPhase.connecting) {
      _startupStage = null;
    }
    _syncSysProxyGuard();
    notifyListeners();
  }

  void _fail(String message) {
    Logger.instance.error(_source, message);
    _setState(ConnectionPhase.failed, error: message);
  }

  void _emitConfigAlert(Object error) {
    final String message = error.toString();
    _formatError = message;
    if (_lastConfigAlert == message) {
      return;
    }
    _lastConfigAlert = message;
    onConfigAlert?.call(message);
  }

  void _clearFormatError() {
    _formatError = null;
    _lastConfigAlert = null;
  }

  bool _isFormatError(Object error) {
    if (error is ProfileAssemblyException || error is ProfileFormatException) {
      return true;
    }
    final String message = switch (error) {
      ApiException() => error.message,
      KernelException() => error.message,
      _ => error.toString(),
    };
    return message.contains('面板配置不规范') ||
        message.contains('配置校验未通过') ||
        message.contains('面板下发的不是一份完整配置') ||
        message.contains('面板未下发任何可用节点') ||
        message.contains('面板配置缺少');
  }

  Future<void> _acceptRemote(
    RemoteProfile remote, {
    required bool persist,
  }) async {
    final PanelApiClient? api = _api;
    ProfileInspector.ensureValid(remote.config);
    if (api == null) {
      return;
    }
    await _kernel.bindSession(AppPaths.session);
    if (!identical(api, _api)) {
      return;
    }
    // 与随后热载、启动用的装配条件一致，校验过的才是内核实际要加载的那份
    final bool takeover = _takeover;
    final AppSettings settings = _settings;
    final AssembledProfile candidate = const ProfileAssembler().assemble(
      remote: NodeWorkingSet.restrict(
        remote.config,
        _workingSet(remote.config, <String>[
          ...?_selectorSnapshot?.values,
          ...?_loadSelectorSnapshot()?.values,
        ]),
        _probeNodes,
      ),
      template: LocalTemplate(
        _settings.toTemplateOptions(
          tunInterfaceName: _platform.tunInterfaceName,
          tunSetsSystemDns: _platform.tunSetsSystemDns,
          strictRouteNeedsTunIPv6: _platform.strictRouteNeedsTunIPv6,
          lanNamesViaSystemDns: _platform.lanNamesViaSystemDns,
          takeover: takeover,
          supportsSystemProxy: _platform.supportsSystemProxy,
          extraTunExcludeAddresses: api.configDirectCidrs,
        ),
        _clashApiOptions ??
            ClashApiOptions(port: _settings.mixedPort, secret: _randomSecret()),
      ),
    );
    final String? invalid = await _kernel.validate(candidate.validationJson);
    if (!identical(api, _api)) {
      return;
    }
    if (invalid != null) {
      throw ProfileFormatException(<String>[
        L10n.t('内核配置校验失败：{0}', <Object>[invalid]),
      ]);
    }
    _clearFormatError();
    _applyRemoteProfile(remote, persist: persist);
    _validated = (
      remote: remote.config,
      takeover: takeover,
      settings: settings,
    );
  }

  // 只认紧接着的那一次：之后的启动仍各自校验
  bool _takeValidated() {
    final ({Map<String, dynamic> remote, bool takeover, AppSettings settings})?
    validated = _validated;
    _validated = null;
    return validated != null &&
        identical(validated.remote, _remote) &&
        validated.takeover == _takeover &&
        identical(validated.settings, _settings);
  }

  static Future<int> _pickFreePort() async {
    final ServerSocket socket = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final int port = socket.port;
    await socket.close();
    return port;
  }

  static String _randomSecret() {
    final Random random = Random.secure();
    return List<String>.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<String> readRunFile(String relativePath) async {
    final String path = _normalizeRunRelative(relativePath);
    final String content = await _kernel.readRunFile(path);
    if (content.contains('\u0000')) {
      throw KernelException('该文件为二进制规则集，无法以文本查看');
    }
    return content;
  }

  Future<String> readRuntimeConfig() async {
    try {
      final String raw = await readRunFile('config.json');
      return NodeLabels.annotateRuntimeConfig(
        maskRuntimeSecrets(raw, nodes: await _panelNodesFor(raw)),
      );
    } on Object {
      final String? json = _profile?.json;
      if (json != null && json.isNotEmpty) {
        return NodeLabels.annotateRuntimeConfig(maskRuntimeSecrets(json));
      }
      rethrow;
    }
  }

  // 落盘配置里的节点 provider 不带 payload，节点只在节点文件里；查看时从 ecy-panel-nodes 的文件补回全部节点
  Future<List<Object?>?> _panelNodesFor(String raw) async {
    final Object? config = jsonDecode(raw);
    final Object? providers = config is Map ? config['proxy-providers'] : null;
    final Object? panel = providers is Map
        ? providers['ecy-panel-nodes']
        : null;
    if (panel is! Map || panel['payload'] != null) {
      return null;
    }
    final Object? file = jsonDecode(await readRunFile('ecy-panel-nodes.json'));
    final Object? proxies = file is Map ? file['proxies'] : null;
    return proxies is List ? proxies.cast<Object?>() : null;
  }

  // 运行配置只供查看：控制面 secret、本设备的节点凭据与测速入站口令都不得出现在界面上。
  // 节点只在 ecy-panel-nodes 下列一次，各组节点 provider 不再重复列出
  @visibleForTesting
  static String maskRuntimeSecrets(String raw, {List<Object?>? nodes}) {
    final Object? config = jsonDecode(raw);
    if (config is! Map<String, dynamic>) {
      throw const FormatException('运行配置不是 JSON 对象');
    }
    final Object? panelProviders = config['proxy-providers'];
    if (panelProviders is Map) {
      for (final MapEntry<dynamic, dynamic> entry in panelProviders.entries) {
        final Object? provider = entry.value;
        if (provider is! Map || !'${entry.key}'.startsWith('ecy-panel-')) {
          continue;
        }
        if (entry.key == 'ecy-panel-nodes') {
          if (provider['payload'] == null && nodes != null) {
            provider['payload'] = nodes;
          }
        } else {
          provider.remove('payload');
        }
      }
    }
    if (config.containsKey('secret')) {
      config['secret'] = '******';
    }
    _maskCredentials(config['proxies']);
    _maskCredentials(config['listeners']);
    final Object? providers = config['proxy-providers'];
    if (providers is Map) {
      for (final Object? provider in providers.values) {
        _maskCredentials(provider is Map ? provider['payload'] : null);
      }
    }
    return const JsonEncoder.withIndent('  ').convert(config);
  }

  static const Set<String> _credentialKeys = <String>{
    'uuid',
    'password',
    'auth',
    'auth-str',
    'obfs-password',
    'private-key',
    'pre-shared-key',
    'public-key',
    'short-id',
    'psk',
    'token',
  };

  static void _maskCredentials(Object? value) {
    if (value is List) {
      value.forEach(_maskCredentials);
    } else if (value is Map) {
      for (final Object? key in value.keys.toList()) {
        final Object? item = value[key];
        if (_credentialKeys.contains(key) &&
            item is String &&
            item.isNotEmpty) {
          value[key] = '******';
        } else {
          _maskCredentials(item);
        }
      }
    }
  }

  List<RuleProviderRef> ruleProviderRefs() {
    final Map<String, dynamic>? providers = _ruleProvidersMap();
    if (providers == null || providers.isEmpty) {
      return const <RuleProviderRef>[];
    }
    final List<RuleProviderRef> items = <RuleProviderRef>[];
    providers.forEach((String name, Object? value) {
      if (value is! Map) {
        return;
      }
      final Map<String, dynamic> provider = value.cast<String, dynamic>();
      final Object? path = provider['path'];
      if (path is! String || path.trim().isEmpty) {
        return;
      }
      try {
        items.add(
          RuleProviderRef(
            name: name,
            relativePath: _normalizeRunRelative(path),
            format: '${provider['format'] ?? ''}',
          ),
        );
      } on Object catch (_) {}
    });
    items.sort(
      (RuleProviderRef a, RuleProviderRef b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return items;
  }

  Map<String, dynamic>? _ruleProvidersMap() {
    final Object? fromProfile = _profile?.config['rule-providers'];
    if (fromProfile is Map) {
      return fromProfile.cast<String, dynamic>();
    }
    try {
      final Object? providers = _panelCache
          .loadRemote(_accountKey, _api?.cacheKey)
          ?.config['rule-providers'];
      if (providers is! Map) {
        return null;
      }
      return providers.cast<String, dynamic>();
    } on Object {
      return null;
    }
  }

  static String _normalizeRunRelative(String path) {
    var normalized = path.trim().replaceAll('\\', '/');
    while (normalized.startsWith('./')) {
      normalized = normalized.substring(2);
    }
    while (normalized.startsWith('/')) {
      normalized = normalized.substring(1);
    }
    if (normalized.isEmpty ||
        normalized == '.' ||
        normalized.contains('..') ||
        normalized.contains(':')) {
      throw KernelException('非法路径');
    }
    return normalized;
  }

  @override
  void dispose() {
    _panelSyncTimer?.cancel();
    _authorizationTimer?.cancel();
    _api = null;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_kernelStatusSubscription.cancel());
    unawaited(_kernelLogSubscription.cancel());
    unawaited(_trayActionSubscription?.cancel());
    _restartTimer?.cancel();
    _autoConnectTimer?.cancel();
    _proxyRefreshTimer?.cancel();
    _sysProxyGuardTimer?.cancel();
    _statsTimer?.cancel();
    _statsUpdates.dispose();
    _trafficRank.flush();
    _clash?.close();
    _clash = null;
    unawaited(_kernel.dispose());
    super.dispose();
  }
}

// 一次测试只属于发起时的内核与账户：任一换掉后，排队和在途的步骤不再继续，也不写结果
class _TestRun {
  _TestRun(this._owner, this.clash, this.api);

  final ConnectionController _owner;
  final ClashApiClient clash;
  final PanelApiClient? api;

  bool get isCurrent =>
      identical(clash, _owner._clash) && identical(api, _owner._api);
}
