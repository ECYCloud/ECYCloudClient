import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
import '../domain/config/local_template.dart';
import '../domain/config/network_bypass.dart';
import '../domain/config/profile_assembler.dart';
import '../domain/kernel/clash_api_client.dart';
import '../domain/kernel/kernel_controller.dart';
import '../domain/kernel/kernel_update.dart';
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

class ConnectionController extends ChangeNotifier with WidgetsBindingObserver {
  // 命名参数不能写成 this._field，只能在初始化列表里赋值
  // ignore_for_file: prefer_initializing_formals
  ConnectionController({
    required PlatformService platform,
    required KernelController kernel,
    required SettingsStore settingsStore,
    PanelResponseCache? panelCache,
  }) : _platform = platform,
       _kernel = kernel,
       _settingsStore = settingsStore,
       _settings = settingsStore.load(),
       _panelCache = panelCache ?? PanelResponseCache(),
       _selectorCache = JsonFileStore(
         AppPaths.selectorCache,
         'selector-cache',
       ) {
    WidgetsBinding.instance.addObserver(this);
    _routeMode = _settings.routeMode;
    _kernelStatusSubscription = _kernel.statusStream.listen(_onKernelStatus);
    _kernelLogSubscription = _kernel.kernelLog.listen((String line) {
      Logger.instance.log(
        Logger.kernelLevel(line),
        'mihomo',
        Logger.kernelMessage(line),
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

  late StreamSubscription<KernelStatus> _kernelStatusSubscription;
  late StreamSubscription<String> _kernelLogSubscription;
  StreamSubscription<TrayAction>? _trayActionSubscription;
  Timer? _restartTimer;
  Timer? _proxyRefreshTimer;
  Timer? _statsTimer;
  TrayState? _trayState;

  AppSettings _settings;
  ConnectionPhase _state = ConnectionPhase.disconnected;
  String? _error;
  String? _startupStage;
  List<String> _preflightProblems = const <String>[];

  PanelApiClient? _api;
  ClashApiClient? _clash;
  UserProfile? Function()? _profileOf;

  /// 返回用户选定要挤下线的 IP；返回 null 表示取消连接，空串表示交给节点挑最旧的
  Future<String?> Function(List<OnlineDevice> devices)? confirmIpLimitKick;

  Map<String, dynamic>? _remote;
  Map<String, String> _proxyNetwork = const <String, String>{};
  Map<String, bool> _proxyUdp = const <String, bool>{};
  Map<String, String> _proxyTls = const <String, String>{};
  Map<String, String> _groupIcons = const <String, String>{};
  AssembledProfile? _profile;
  ClashApiOptions? _clashApiOptions;
  String _configRevision = '';
  DateTime? _connectedAt;

  List<ProxyGroup> _groups = const <ProxyGroup>[];
  List<ProxyNode> _nodes = const <ProxyNode>[];
  final Map<String, int> _delays = <String, int>{};
  final Set<String> _testing = <String>{};
  final Set<String> _testingGroups = <String>{};
  final Set<String> _unreachable = <String>{};
  TrafficSample _traffic = const TrafficSample(0, 0);
  TrafficSample _trafficTotal = const TrafficSample(0, 0);
  DateTime? _trafficSampledAt;
  bool _pollingStats = false;
  final List<TrafficSample> _trafficHistory = <TrafficSample>[];
  KernelStats _stats = KernelStats.empty;
  List<Map<String, dynamic>> _connections = const <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> _closedConnections =
      <Map<String, dynamic>>[];
  String _routeMode = 'rule';

  bool _userStopped = true;
  // 内核常驻，界面上的「连接」只切换出口接管（TUN + 系统代理）。未接管时内核照样
  // 在跑、控制面照样在线，选节点与测延迟因此不需要先连接
  bool _takeover = false;
  // 界面不可见（Android 切后台/息屏）：控制面轮询只保留流量累计所需的最低频率
  bool _background = false;
  int _restartAttempt = 0;
  bool _profileRefreshInFlight = false;
  // 面板对 /config/clash 有最小请求间隔，超了直接 429。手上的配置只有在面板
  // 报出新的 revision 后才算过期，在那之前一律复用，不再重复请求
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

  AppSettings get settings => _settings;

  ConnectionPhase get state => _state;

  String? get error => _error;

  List<String> get preflightProblems => _preflightProblems;

  List<ProxyGroup> get groups => <ProxyGroup>[
    for (final ProxyGroup group in _groups)
      if (group.name != ClashApiClient.globalGroupName) group,
  ];

  ProxyGroup? get globalGroup => groupByName(ClashApiClient.globalGroupName);

  List<ProxyGroup> get groupsForMode {
    if (_routeMode == 'global') {
      final ProxyGroup? group = globalGroup;
      return group == null ? const <ProxyGroup>[] : <ProxyGroup>[group];
    }
    return groups;
  }

  List<ProxyNode> get nodes => _nodes;

  int delayOf(String name) => _delays[name] ?? 0;

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

  Future<String> kernelVersion() => _kernel.kernelVersion();

  bool get kernelUpgradeSupported => _kernel.upgradable;

  Future<KernelUpdate> checkKernelUpdate() async =>
      KernelUpdate.check(await kernelVersion());

  /// 升级内核。下载与校验期间连接不断，GitHub 经本地 mixed 出网；
  /// 替换文件前由服务停掉内核，因此这里要先摘掉「内核意外退出就自动重启」那条路，
  /// 换完再按升级前的状态重连。
  Future<String> upgradeKernel(String version) async {
    final bool wasConnected = _state == ConnectionPhase.connected;
    _userStopped = true;
    _restartTimer?.cancel();
    _restartTimer = null;

    try {
      return await _kernel.upgrade(
        version,
        proxyPort: wasConnected ? _settings.mixedPort : null,
      );
    } finally {
      if (wasConnected) {
        _userStopped = false;
        _restartAttempt = 0;
        await _restartKernel(L10n.t('内核已更新，正在重启'));
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

  TrafficSample get traffic => _traffic;

  TrafficSample get trafficTotal => _trafficTotal;

  List<TrafficSample> get trafficHistory => _trafficHistory;

  KernelStats get stats => _stats;

  List<Map<String, dynamic>> get connections => _connections;

  List<Map<String, dynamic>> get closedConnections => _closedConnections;

  String get routeMode => _routeMode;

  DateTime? get connectedAt => _connectedAt;

  ClashApiClient? get clash => _clash;

  /// 控制面是否在线。内核常驻，未连接时它同样为真，节点操作据此放行。
  bool get controlPlaneReady => _clash != null;

  bool get busy =>
      _state == ConnectionPhase.connecting ||
      _state == ConnectionPhase.disconnecting;

  void attachProfileLookup(UserProfile? Function()? lookup) {
    _profileOf = lookup;
  }

  void attachApi(PanelApiClient? api, {String? accountKey}) {
    final bool changed = !identical(api, _api);
    final String nextKey = (accountKey ?? '').trim();
    final bool accountChanged =
        nextKey.isNotEmpty &&
        nextKey.toLowerCase() != _accountKey.toLowerCase();
    _api = api;
    api?.fallbackProxyPort = _state == ConnectionPhase.connected
        ? _settings.mixedPort
        : null;
    if (api != null) {
      unawaited(api.refreshConfigDirectAddresses());
    }
    if (nextKey.isNotEmpty) {
      _accountKey = nextKey;
    }
    if (api == null) {
      _remote = null;
      _indexProxyExtra();
      _remoteStale = false;
      _remoteCooldownUntil = null;
      _accountKey = '';
      unawaited(shutdown());
      return;
    }
    if (accountChanged || (_remote == null && _accountKey.isNotEmpty)) {
      _hydrateRemoteFromCache();
    }
    if (changed) {
      // 新 token 限流计数独立；清掉旧退避，避免刚登录还背着上一会话的冷却
      _remoteCooldownUntil = null;
      unawaited(preloadProxies());
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
      Logger.instance.warn(_source, '预取面板配置失败: $e');
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
  Future<void> adoptRunningKernel() async {
    final ClashApiOptions? live = await _kernel.attach();
    if (live == null) {
      return;
    }

    final int generation = ++_generation;
    _userStopped = false;
    _setState(ConnectionPhase.connecting, error: null);

    final ClashApiClient clash = ClashApiClient(live);
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
      await _refreshProxies();
      final ({String mode, bool tunEnabled}) runtime = await clash
          .fetchRuntime();
      _routeMode = runtime.mode;
      // 认回来的可能是一个常驻但没接管出口的内核，此时界面该显示未连接
      _takeover = runtime.tunEnabled;
    } on Object catch (e) {
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
    if (_clash != null || busy || _api == null) {
      return;
    }
    await _switchTakeover(false, L10n.t('正在准备内核'));
  }

  Future<void> connect() async {
    if (busy || _state == ConnectionPhase.connected) {
      return;
    }

    final UserProfile? profile = _profileOf?.call();
    if (profile != null && profile.onlineIpLimitReached) {
      final Future<String?> Function(List<OnlineDevice>)? confirm =
          confirmIpLimitKick;
      if (confirm == null) {
        return;
      }
      final PanelApiClient? api = _api;
      if (api == null) {
        _fail(L10n.t('尚未登录'));
        return;
      }
      List<OnlineDevice> devices;
      try {
        devices = await api.fetchOnlineDevices();
      } on ApiException {
        // 列不出来时仍可连接，只是没得选，由节点挑最旧的那个
        devices = const <OnlineDevice>[];
      }
      final String? targetIp = await confirm(devices);
      if (targetIp == null) {
        return;
      }
      try {
        await api.reclaimIp(targetIp: targetIp);
      } on ApiException catch (e) {
        _fail(e.message);
        return;
      }
    }

    await _switchTakeover(true, L10n.t('正在连接'));
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
  Future<void> shutdown() async {
    _generation++;
    _takeover = false;
    _userStopped = true;
    _persistRestart = false;
    _restartTimer?.cancel();
    _restartTimer = null;

    _setState(ConnectionPhase.disconnecting, error: null);
    await _teardown();
    _setState(ConnectionPhase.disconnected, error: null);
  }

  Future<void> _switchTakeover(bool takeover, String stage) async {
    final PanelApiClient? api = _api;
    if (api == null) {
      if (takeover) {
        _fail(L10n.t('尚未登录'));
      }
      return;
    }

    final int generation = ++_generation;
    _takeover = takeover;
    _userStopped = false;
    _restartAttempt = 0;
    _persistRestart = false;
    _kernelDiedDuringConnect = false;
    _restartTimer?.cancel();
    _restartTimer = null;
    _captureSelectorSnapshot();
    _startupStage = stage;
    if (takeover) {
      _setState(ConnectionPhase.connecting, error: null);
    } else {
      notifyListeners();
    }

    try {
      await _ensureRemoteConfig(api);
      await _teardown(restarting: true);
      if (generation != _generation) {
        return;
      }
      await _rebuildProfile();
      await _launchKernel(generation);
    } on Object catch (e) {
      if (generation != _generation) {
        return;
      }
      final String reason = _kernelDiedDuringConnect
          ? L10n.t('内核启动失败，请重试')
          : e.toString();
      await _teardown();
      // 常驻起不来不该弹成连接失败：用户没按连接，界面退回面板配置那份节点列表即可
      if (takeover) {
        _fail(reason);
      } else {
        Logger.instance.warn(_source, '内核常驻启动失败：$reason');
        _setState(ConnectionPhase.disconnected, error: null);
      }
    }
  }

  Future<void> updateSettings(AppSettings next) async {
    final bool needsRestart = _settings.affectsKernel(next) && _clash != null;
    final bool proxyChanged =
        _settings.systemProxyEnabled != next.systemProxyEnabled ||
        !listEquals(_settings.systemProxyBypass, next.systemProxyBypass);

    _settings = next;
    _settingsStore.save(next);
    Logger.instance.level = next.logLevel;
    notifyListeners();

    await syncPlatformSettings();

    if (needsRestart) {
      await _restartKernel(L10n.t('正在应用新设置'));
      return;
    }

    if (proxyChanged && _state == ConnectionPhase.connected) {
      await _applySystemProxy();
    }
  }

  // 内核的 PATCH / PUT /configs 能热改端口、TUN、IPv6、日志级别，但客户端每次都是
  // 拿面板配置加本地模板整份重装：走重启这一条路，落盘的那份配置始终等于运行中的
  // 状态，界面之外读回控制面端口与 secret 时才不会读到已被增量改掉的旧值
  Future<void> _restartKernel(String stage) async {
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
      await _launchKernel(generation);
    } on Object catch (e) {
      if (generation != _generation || _userStopped) {
        return;
      }
      // 配置本身非法：重试无意义，直接失败
      if (_isUnrecoverableConfigError(e)) {
        _persistRestart = false;
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
    if (error is ProfileAssemblyException) {
      return true;
    }
    final String message = error.toString();
    return message.contains('配置校验未通过') ||
        message.contains('面板未下发任何可用节点') ||
        message.contains('尚未获取面板配置');
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
    final bool proxyOn = active && _settings.systemProxyEnabled;
    final bool tunOn = active && _settings.tunEnabled;
    final String on = L10n.t('已开启');
    final String off = L10n.t('已关闭');
    final TrayState next = TrayState(
      connected: active,
      busy: busy,
      systemProxyEnabled: proxyOn,
      tunEnabled: tunOn,
      routeMode: _routeMode,
      modeEnabled: controlPlaneReady,
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

    await clash.selectProxy(group, member);
    _rememberSelector(group, member);
    await _refreshProxies();

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
    if (_accountKey.isNotEmpty &&
        storedAccount.isNotEmpty &&
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
        replaced.add(group.now);
      } on Object catch (e) {
        Logger.instance.warn(_source, '恢复分组「${group.name}」选中项失败: $e');
      }
    }
    if (replaced.isNotEmpty) {
      await clash.closeConnectionsVia(replaced);
      await _refreshProxies(notify: false);
    }
  }

  Future<void> setRouteMode(String mode) async {
    if (mode != 'rule' && mode != 'global' && mode != 'direct') {
      return;
    }
    final ClashApiClient? clash = _clash;
    if (clash != null) {
      await clash.setMode(mode);
    }

    _routeMode = mode;
    if (_settings.routeMode != mode) {
      _settings = _settings.copyWith(routeMode: mode);
      _settingsStore.save(_settings);
    }
    notifyListeners();
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
    if (await _ensureControlPlane()) {
      await _testNodes(<String>[resolveNode(name)]);
    }
  }

  Future<bool> _ensureControlPlane() async {
    if (_clash != null) {
      return true;
    }
    await startStandby();
    return _clash != null;
  }

  // 不用 /group/{name}/delay：一批才返回、urltest 会忽略 url/timeout，
  // 且静默跳过距上次不足 interval 的成员，失败与跳过都表现为缺项。
  Future<void> testGroup(String group) async {
    if (!await _ensureControlPlane()) {
      return;
    }

    final ProxyGroup? target = groupByName(group);
    if (target == null || !_testingGroups.add(group)) {
      return;
    }
    notifyListeners();

    try {
      await _testNodes(
        <String>{
          for (final String member in target.members) resolveNode(member),
        }.toList(growable: false),
      );

      // selector 组的选中项归用户；urltest 组要让内核按新延迟立刻重选
      if (!target.selectable) {
        await _reselect(group);
      }
    } finally {
      _testingGroups.remove(group);
      notifyListeners();
    }
  }

  Future<void> _reselect(String group) async {
    try {
      await _clash?.reselectGroup(group);
      await _refreshProxies();
    } on Object catch (e) {
      Logger.instance.warn(_source, '分组 $group 重选失败: $e');
    }
  }

  // 内核对整组是并发 10 分批测的，客户端逐个打也按同一量级并发，
  // 再高就会互相抢带宽、把延迟测虚高
  static const int _testConcurrency = 8;

  Future<void> _testNodes(List<String> names) async {
    final ClashApiClient? clash = _clash;
    if (clash == null) {
      return;
    }

    final List<String> pending = names
        .where((String name) => name.isNotEmpty && _testing.add(name))
        .toList(growable: false);
    if (pending.isEmpty) {
      return;
    }
    notifyListeners();

    final Iterator<String> queue = pending.iterator;

    Future<void> worker() async {
      while (queue.moveNext()) {
        final String name = queue.current;
        try {
          _delays[name] = await clash.testDelay(name);
          _unreachable.remove(name);
        } on Object {
          _delays.remove(name);
          _unreachable.add(name);
        } finally {
          _testing.remove(name);
          notifyListeners();
        }
      }
    }

    await Future.wait(<Future<void>>[
      for (int i = 0; i < min(_testConcurrency, pending.length); i++) worker(),
    ]);
  }

  Future<void> _ensureRemoteConfig(PanelApiClient api) {
    if (_remote != null && !_remoteStale) {
      return Future<void>.value();
    }
    // 限流窗口内：有旧配置就先用（哪怕标了过期），绝不连打面板
    final DateTime? until = _remoteCooldownUntil;
    if (_remote != null && until != null && DateTime.now().isBefore(until)) {
      _remoteStale = false;
      return Future<void>.value();
    }
    if (_remote == null) {
      _hydrateRemoteFromCache();
      if (_remote != null && !_remoteStale) {
        return Future<void>.value();
      }
    }
    return _fetchRemoteConfig(api);
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

    final int? fallbackProxyPort = _state == ConnectionPhase.connected
        ? _settings.mixedPort
        : null;

    // 本地已有配置时先探轻量 revision，未变则绝不打昂贵的 /config/clash；
    // 本地若尚无分组则不能跳过（戳不变也会一直空着）。
    if (_remote != null &&
        _configRevision.isNotEmpty &&
        _remoteHasProxyGroups &&
        await _remoteRevisionUnchanged(api, fallbackProxyPort)) {
      _remoteStale = false;
      return;
    }
    try {
      final RemoteProfile remote = await api.fetchClashProfile(
        fallbackProxyPort: fallbackProxyPort,
      );
      _applyRemoteProfile(remote, persist: true);
    } on ApiException catch (e) {
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
      try {
        final RemoteProfile remote = await api.fetchClashProfile(
          fallbackProxyPort: fallbackProxyPort,
        );
        _applyRemoteProfile(remote, persist: true);
      } on ApiException catch (retryError) {
        if (retryError.rateLimited && _useCachedRemote()) {
          return;
        }
        if (retryError.rateLimited) {
          throw ApiException(
            '面板繁忙，请稍后再试连接',
            statusCode: 429,
            retryAfterSeconds: retryError.retryAfterSeconds,
          );
        }
        rethrow;
      }
    }
  }

  Future<bool> _remoteRevisionUnchanged(
    PanelApiClient api,
    int? fallbackProxyPort,
  ) async {
    try {
      final String remote = await api.fetchConfigRevision(
        fallbackProxyPort: fallbackProxyPort,
      );
      if (remote.isEmpty) {
        return false;
      }
      return remote == _configRevision;
    } on ApiException catch (e) {
      if (e.rateLimited) {
        Logger.instance.warn(_source, '配置戳探测限流，改用本地缓存');
        return _useCachedRemote();
      }
      Logger.instance.warn(_source, '配置戳探测失败，将尝试拉全量: $e');
      return false;
    } on Object catch (e) {
      Logger.instance.warn(_source, '配置戳探测失败，将尝试拉全量: $e');
      return false;
    }
  }

  void _applyRemoteProfile(RemoteProfile remote, {required bool persist}) {
    _configRevision = remote.revision;
    _remote = remote.config;
    _indexProxyExtra();
    _groupIcons = remote.groupIcons;
    _remoteStale = false;
    _remoteCooldownUntil = null;
    NodeLabels.configure(remote.flagRegex, remote.nodeLabels);
    // 这里不装配：装配会换掉控制面端口/secret，旧内核仍在跑时改掉这些字段
    // 没有意义，还会干扰并发重启。需要配置的一方自行 _rebuildProfile()
    _providerTotal = AssembledProfile.countRemoteProviders(remote.config);
    if (persist && _accountKey.isNotEmpty) {
      _panelCache.saveRemote(_accountKey, remote);
    }
  }

  bool _hydrateRemoteFromCache() {
    if (_accountKey.isEmpty) {
      return false;
    }
    final RemoteProfile? cached = _panelCache.loadRemote(_accountKey);
    if (cached == null) {
      return false;
    }
    _applyRemoteProfile(cached, persist: false);
    _remoteStale = true;
    Logger.instance.info(_source, '已载入本地面板配置缓存，待空闲时刷新');
    return true;
  }

  bool _useCachedRemote() {
    if (_remote != null) {
      _remoteStale = false;
      return true;
    }
    if (!_hydrateRemoteFromCache()) {
      return false;
    }
    _remoteStale = false;
    return true;
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

  Future<void> _rebuildProfile({bool reuseControlPlane = false}) async {
    final Map<String, dynamic>? remote = _remote;
    if (remote == null) {
      throw StateError('尚未获取面板配置');
    }

    // 热载必须复用端口/secret：PUT /configs 不重建控制面，换掉会使 ClashApiClient 失联；
    // 冷启动 / 进程重启仍每次重新分配
    if (!reuseControlPlane || _clashApiOptions == null) {
      _clashApiOptions = ClashApiOptions(
        port: await _pickFreePort(),
        secret: _randomSecret(),
      );
    }

    final PanelApiClient? api = _api;
    if (api != null) {
      await api.refreshConfigDirectAddresses();
    }

    final Map<String, String> selectorDefaults = <String, String>{
      ...?_selectorSnapshot,
      ...?_loadSelectorSnapshot(),
    };
    _selectorSnapshot = selectorDefaults.isEmpty ? null : selectorDefaults;
    _profile = const ProfileAssembler().assemble(
      remote: remote,
      template: LocalTemplate(
        _settings.toTemplateOptions(
          tunInterfaceName: _platform.tunInterfaceName,
          takeover: _takeover,
          extraTunExcludeAddresses: api?.configDirectCidrs ?? const <String>[],
        ),
        _clashApiOptions!,
      ),
      selectorDefaults: selectorDefaults,
    );

    _providerReady.clear();
    _providerTotal = _profile!.remoteProviderCount;
  }

  Future<void> _launchKernel(int generation) async {
    _launching = true;
    try {
      await _launchKernelOnce(generation);
    } finally {
      _launching = false;
    }
  }

  Future<void> _launchKernelOnce(int generation) async {
    final AssembledProfile? profile = _profile;
    final ClashApiOptions? clashApi = _clashApiOptions;
    if (profile == null || clashApi == null) {
      throw StateError('配置尚未生成');
    }

    final String? invalid = await _kernel.validate(profile.json);
    if (invalid != null) {
      throw KernelException('配置校验未通过：$invalid');
    }
    // 校验期间可能已被 disconnect() 或更晚一轮取代，不该再去拉起内核
    if (generation != _generation) {
      return;
    }

    await _kernel.start(configJson: profile.json, clashApi: clashApi);
    // 重启不再先停内核，轮询会一直开着：旧内核在这之前退出报的 failed 说的是上一个
    // 进程，带进下面的 waitReady 会让刚拉起来的这个被当场判死
    _kernelDiedDuringConnect = false;

    final ClashApiClient clash = ClashApiClient(clashApi);
    // 控制面要等远程规则集下载编译完才监听；分流配置变更后缓存失效时明显变慢
    final int readySeconds = (60 + _providerTotal * 8).clamp(60, 180);
    await clash.waitReady(
      timeout: Duration(seconds: readySeconds),
      isCancelled: () => generation != _generation || _kernelDiedDuringConnect,
    );

    if (generation != _generation) {
      clash.close();
      await _kernel.stop();
      return;
    }
    _clash = clash;

    await _refreshProxies(notify: false);
    await _restoreSelectorSnapshot();
    _captureSelectorSnapshot();
    _routeMode = (await clash.fetchRuntime()).mode;

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

    _connectedAt = _takeover ? DateTime.now() : null;
    _restartAttempt = 0;
    _persistRestart = false;
    _setState(
      _takeover ? ConnectionPhase.connected : ConnectionPhase.disconnected,
      error: null,
    );
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
    } on PlatformServiceException catch (e) {
      Logger.instance.error(_source, '还原系统代理失败', e);
    }
  }

  Future<void> _applySystemProxy() async {
    if (!_platform.supportsSystemProxy) {
      return;
    }

    if (_takeover && _settings.systemProxyEnabled) {
      await _platform.setSystemProxy(
        port: _settings.mixedPort,
        bypass: resolvedSystemProxyBypass(
          _platform.platformId,
          _settings.systemProxyBypass,
        ),
      );
    } else {
      await _platform.restoreSystemProxy();
    }
  }

  static const int _trafficHistoryLength = 60;
  static const Duration _statsInterval = Duration(seconds: 1);
  static const Duration _statsBackgroundInterval = Duration(seconds: 10);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool background =
        state != AppLifecycleState.resumed &&
        state != AppLifecycleState.inactive;
    if (background == _background) {
      return;
    }
    _background = background;
    if (_state == ConnectionPhase.connected) {
      _scheduleStatsRefresh();
      _scheduleProxyRefresh();
      return;
    }
    // 回到前台：这期间内核可能被通知栏磁贴单独开了起来，界面得认回这条隧道，
    // 否则会显示成未连接、用户也断不开
    if (!background && !busy && _clash == null) {
      unawaited(adoptRunningKernel());
    }
  }

  void _scheduleStatsRefresh() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(
      _background ? _statsBackgroundInterval : _statsInterval,
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
      _stats = result.$1;
      _applyConnections(result.$2);
      notifyListeners();
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
      final (int, int) current = _counters(item);
      final (int, int) last = previous['${item['id']}'] ?? (0, 0);
      // 内核不会把计数器往回调，负值只可能来自 id 复用，按新连接算
      up += max(0, current.$1 - last.$1);
      down += max(0, current.$2 - last.$2);
    }

    final DateTime now = DateTime.now();
    final DateTime? last = _trafficSampledAt;
    _trafficSampledAt = now;
    _trafficTotal = TrafficSample(
      _trafficTotal.up + up,
      _trafficTotal.down + down,
    );

    // 首个样本没有区间，算速率会得到无穷大；后台样本跨度是前台的十倍，
    // 混进走势图会把「最近一分钟」的横轴悄悄拉长
    if (last == null || _background) {
      return;
    }
    final double seconds = now.difference(last).inMilliseconds / 1000;
    if (seconds <= 0) {
      return;
    }

    _traffic = TrafficSample(up ~/ seconds, down ~/ seconds);
    _trafficHistory.add(_traffic);
    if (_trafficHistory.length > _trafficHistoryLength) {
      _trafficHistory.removeRange(
        0,
        _trafficHistory.length - _trafficHistoryLength,
      );
    }
  }

  static (int, int) _counters(Map<String, dynamic> item) => (
    (item['upload'] as num?)?.toInt() ?? 0,
    (item['download'] as num?)?.toInt() ?? 0,
  );

  // chains 是反转过的出站链，首项即最终落地的出站。按类型判断而不是按名字：名字归
  // 面板，类型是内核的 constant.AdapterType.String()。下面这几档都不出网，内核内建的
  // 五个出站（config.go 里的 DIRECT / REJECT / REJECT-DROP / COMPATIBLE / PASS）
  // 加上 DNS 劫持用的 Dns 正好齐了。
  bool _viaProxy(Map<String, dynamic> item) {
    final Object? chains = item['chains'];
    if (chains is! List || chains.isEmpty) {
      return false;
    }
    return !const <String>{
      'direct',
      'reject',
      'rejectdrop',
      'compatible',
      'pass',
      'dns',
    }.contains(typeOf('${chains.first}').toLowerCase());
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
      await _refreshProxies();
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

  /// 返回给人看的结果文案；已有刷新在进行时返回 null（调用方勿提示）。
  Future<String?> refreshProfileFromPanel() async {
    final PanelApiClient? api = _api;
    if (api == null) {
      return L10n.t('更新失败：未登录');
    }
    if (_profileRefreshInFlight) {
      return null;
    }

    _profileRefreshInFlight = true;
    try {
      // 比对面板下发的原始配置，而不是装配后的 JSON：装配时会给控制面重新分配端口
      // 与 secret，装配结果每次都不一样，比出来永远是「有变更」，每次刷新都会重连
      final String? previous = _remote == null ? null : jsonEncode(_remote);

      try {
        await _fetchRemoteConfig(api);
      } on ApiException catch (e) {
        Logger.instance.warn(_source, '刷新面板配置失败: $e');
        return L10n.t('更新失败：{0}', <Object>['$e']);
      }

      final bool changed = jsonEncode(_remote) != previous;
      final bool running = _clash != null && _kernel.status.running;

      // 配置 JSON 未变也会走分流规则更新：规则文件内容可能已变而 url/interval 未变
      if (!changed) {
        if (running) {
          await _refreshRuleProviders();
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
        await _hotReloadPanelProfile();
      } on Object catch (e) {
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
    if (before == after) {
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

  /// Verge / CMFA 同思路：复用控制面，热载 proxies/rules，不进 connecting、不断系统代理。
  /// 桌面：落盘 + `PUT /configs?force=true`（executor.ApplyConfig，不重建控制器）。
  /// Android：Dart 侧 PUT 带不上 VpnService fd，走 `kernel.reload`（保留 fd 的
  /// executor.ApplyConfig）；禁止再走 `kernel.start`（会 re-establish TUN 并重建控制面）。
  Future<void> _hotReloadPanelProfile() async {
    final ClashApiClient clash = _clash!;
    _captureSelectorSnapshot();
    await _rebuildProfile(reuseControlPlane: true);
    final AssembledProfile profile = _profile!;

    final String? invalid = await _kernel.validate(profile.json);
    if (invalid != null) {
      throw KernelException('配置校验未通过：$invalid');
    }

    Logger.instance.info(_source, '面板配置有变更，热载内核（不重启进程）');
    await _kernel.persistConfig(profile.json);
    if (Platform.isAndroid) {
      await _kernel.reloadConfig(profile.json);
    } else {
      await clash.applyConfigPayload(profile.json);
    }

    await _refreshProxies(notify: false);
    await _restoreSelectorSnapshot();
    notifyListeners();
  }

  Future<void> _refreshProxies({bool notify = true}) async {
    final ClashApiClient? clash = _clash;
    if (clash == null) {
      return;
    }

    final (List<ProxyGroup>, List<ProxyNode>) result = await clash
        .fetchProxies();
    _groups = _inProfileOrder(result.$1);
    _nodes = result.$2;

    // 内核是延迟的唯一权威来源：它自身的周期探测同样会写历史，
    // 探测失败的节点会被删掉历史、这里表现为延迟归零
    for (final ProxyNode node in _nodes) {
      if (node.delay > 0) {
        _delays[node.name] = node.delay;
        _unreachable.remove(node.name);
      } else if (!_testing.contains(node.name)) {
        _delays.remove(node.name);
      }
    }
    if (notify) {
      notifyListeners();
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

  void _indexProxyExtra() {
    final Map<String, String> networks = <String, String>{};
    final Map<String, bool> udps = <String, bool>{};
    final Map<String, String> tlsTypes = <String, String>{};
    final Object? proxies = _remote?['proxies'];
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
      }
    }
    _proxyNetwork = networks;
    _proxyUdp = udps;
    _proxyTls = tlsTypes;
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
    _nodes = _remote?['proxies'] is List
        ? <ProxyNode>[
            for (final Object? proxy in _remote!['proxies'] as List)
              if (proxy is Map<String, dynamic> &&
                  (proxy['name'] as String? ?? '').isNotEmpty)
                ProxyNode(
                  name: proxy['name'] as String,
                  type: _displayType(proxy['type'] as String? ?? ''),
                  delay: 0,
                ),
          ]
        : const <ProxyNode>[];

    _groups = _remote?['proxy-groups'] is List
        ? <ProxyGroup>[
            for (final Object? group in _remote!['proxy-groups'] as List)
              if (group is Map<String, dynamic> &&
                  (group['name'] as String? ?? '').isNotEmpty)
                ProxyGroup(
                  name: group['name'] as String,
                  type: _displayType(group['type'] as String? ?? ''),
                  // 选中项一律留空：内核启动时会从 cache.db 恢复用户上次的选择，
                  // url-test 组更是要测完延迟才定。拿配置里的首个成员顶替，界面就会
                  // 把每个分组都显示成同一个节点，而这与实际选中项无关。
                  now: '',
                  members: _membersByNodeName(
                    group['proxies'] is List
                        ? (group['proxies'] as List).whereType<String>().toList(
                            growable: false,
                          )
                        : const <String>[],
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
      _fail(status.message ?? L10n.t('内核已被系统停止'));
      unawaited(_teardown());
      return;
    }

    _scheduleRestart(
      status.message ??
          L10n.t('内核异常退出（退出码 {0}）', <Object>[status.exitCode ?? '']),
    );
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
        if (_persistRestart && _api != null) {
          try {
            await _ensureRemoteConfig(_api!);
          } on ApiException catch (e) {
            Logger.instance.warn(_source, '重试前刷新面板配置失败: $e');
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
  Future<void> _teardown({bool restarting = false}) async {
    _proxyRefreshTimer?.cancel();
    _proxyRefreshTimer = null;
    _statsTimer?.cancel();
    _statsTimer = null;

    _clash?.close();
    _clash = null;

    // 三端的 kernel.start 都自带「先停后起」（Windows 与 Unix helper 的
    // kernelManager.start 写完配置就调 k.stop()，Android 的 startOrReloadService
    // 就地重载），重启路径上再停一次纯属多余。Android 上那一次还会连 VpnService
    // 一起停掉，逼得随后的 start 在后台调 startForegroundService 被 API 31+ 拒
    if (!restarting) {
      await _kernel.stop();
    }

    // 下一轮不接管出口（断开，或常驻重载）时同样要立刻交还系统代理，不能等到
    // 内核重载完：那期间浏览器仍指着一个已经停掉的 mixed 口
    if ((!restarting || !_takeover) && _platform.supportsSystemProxy) {
      try {
        await _platform.restoreSystemProxy();
      } on PlatformServiceException catch (e) {
        Logger.instance.error(_source, '还原系统代理失败', e);
      }
    }

    _connectedAt = null;
    _traffic = const TrafficSample(0, 0);
    _trafficTotal = const TrafficSample(0, 0);
    _trafficSampledAt = null;
    _trafficHistory.clear();
    _stats = KernelStats.empty;
    _connections = const <Map<String, dynamic>>[];
    _closedConnections.clear();
    _delays.clear();
    _testing.clear();
    _testingGroups.clear();
    _unreachable.clear();
    _applyProfileProxies();

    if (!restarting) {
      _selectorSnapshot = null;
      notifyListeners();
    }
  }

  void _setState(ConnectionPhase state, {required String? error}) {
    _state = state;
    _api?.fallbackProxyPort = state == ConnectionPhase.connected
        ? _settings.mixedPort
        : null;
    _error = error;
    if (state != ConnectionPhase.connecting) {
      _startupStage = null;
    }
    notifyListeners();
  }

  void _fail(String message) {
    Logger.instance.error(_source, message);
    _setState(ConnectionPhase.failed, error: message);
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
      return NodeLabels.annotateRuntimeConfig(await readRunFile('config.json'));
    } on Object {
      final String? json = _profile?.json;
      if (json != null && json.isNotEmpty) {
        return NodeLabels.annotateRuntimeConfig(json);
      }
      rethrow;
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
      if (!AppPaths.remoteConfigCache.existsSync()) {
        return null;
      }
      final Object? decoded = jsonDecode(
        AppPaths.remoteConfigCache.readAsStringSync(),
      );
      if (decoded is! Map) {
        return null;
      }
      final Object? config = decoded['config'];
      if (config is! Map) {
        return null;
      }
      final Object? providers = config['rule-providers'];
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
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_kernelStatusSubscription.cancel());
    unawaited(_kernelLogSubscription.cancel());
    unawaited(_trayActionSubscription?.cancel());
    _restartTimer?.cancel();
    _proxyRefreshTimer?.cancel();
    _statsTimer?.cancel();
    _clash?.close();
    unawaited(_kernel.dispose());
    super.dispose();
  }
}
