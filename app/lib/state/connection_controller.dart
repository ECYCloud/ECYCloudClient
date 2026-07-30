import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;

import '../core/app_paths.dart';
import '../core/logger.dart';
import '../data/api/api_exception.dart';
import '../data/api/panel_api_client.dart';
import '../data/store/settings_store.dart';
import '../domain/config/local_template.dart';
import '../domain/config/profile_assembler.dart';
import '../domain/kernel/clash_api_client.dart';
import '../domain/kernel/kernel_controller.dart';
import '../domain/kernel/kernel_update.dart';
import '../domain/platform/platform_service.dart';
import '../ui/node_labels.dart';

// 不叫 ConnectionState，避免与 Flutter 的同名枚举冲突
enum ConnectionPhase { disconnected, connecting, connected, failed }

class ConnectionController extends ChangeNotifier {
  // 命名参数不能写成 this._field，只能在初始化列表里赋值
  // ignore_for_file: prefer_initializing_formals
  ConnectionController({
    required PlatformService platform,
    required KernelController kernel,
    required SettingsStore settingsStore,
  }) : _platform = platform,
       _kernel = kernel,
       _settingsStore = settingsStore,
       _settings = settingsStore.load() {
    _kernelStatusSubscription = _kernel.statusStream.listen(_onKernelStatus);
    _kernelLogSubscription = _kernel.kernelLog.listen((String line) {
      Logger.instance.log(Logger.kernelLevel(line), 'sing-box', line);
      _trackStartupStage(line);
    });
    if (_platform.supportsTray) {
      _trayActionSubscription = _platform.trayActions.listen(_onTrayAction);
      addListener(_syncTray);
    }
  }

  static const String _source = 'connection';
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

  late StreamSubscription<KernelStatus> _kernelStatusSubscription;
  late StreamSubscription<String> _kernelLogSubscription;
  StreamSubscription<TrayAction>? _trayActionSubscription;
  Timer? _restartTimer;
  Timer? _profileRefreshTimer;
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

  Map<String, dynamic>? _remote;
  Map<String, String> _groupIcons = const <String, String>{};
  AssembledProfile? _profile;
  ClashApiOptions? _clashApiOptions;
  Duration _profileInterval = const Duration(hours: 24);
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
  int _restartAttempt = 0;

  // connect()/_restartKernel()/自动重连每次各领一个新编号；某一轮在 await 期间
  // 发现自己的编号已经落后，说明中途被 disconnect() 或更新的一轮取代，
  // 后续动作（拉起内核、写状态、挂定时器）全部作废，避免把状态改回去
  int _generation = 0;

  AppSettings get settings => _settings;

  ConnectionPhase get state => _state;

  String? get error => _error;

  List<String> get preflightProblems => _preflightProblems;

  List<ProxyGroup> get groups => _groups;

  List<ProxyNode> get nodes => _nodes;

  // 延迟以叶子节点名为键：逐个探测的结果先落在这里，界面不必等整批结束
  int delayOf(String name) => _delays[name] ?? 0;

  String typeOf(String name) {
    for (final ProxyNode node in _nodes) {
      if (node.name == name) {
        return node.type;
      }
    }
    return '';
  }

  Set<String> get testingNodes => _testing;

  Set<String> get testingGroups => _testingGroups;

  Set<String> get unreachableNodes => _unreachable;

  // 本机从未跑过内核时远程规则集要现下载，启动明显更慢，需要向用户交代
  bool get kernelCacheReady => _kernel.cacheReady;

  // 内核版本由特权服务代跑 `sing-box version` 拿到，未连接时也问得到
  Future<String> kernelVersion() => _kernel.kernelVersion();

  Future<KernelUpdate> checkKernelUpdate() async =>
      KernelUpdate.check(await kernelVersion());

  /// 升级内核。下载与校验期间连接不断（网络受限时只有隧道通着才取得到 GitHub），
  /// 替换文件前由服务停掉内核，因此这里要先摘掉「内核意外退出就自动重启」那条路，
  /// 换完再按升级前的状态重连。
  Future<String> upgradeKernel(String version) async {
    final bool wasConnected = _state == ConnectionPhase.connected;
    _userStopped = true;
    _restartTimer?.cancel();
    _restartTimer = null;

    try {
      return await _kernel.upgrade(version);
    } finally {
      if (wasConnected) {
        _userStopped = false;
        _restartAttempt = 0;
        await _restartKernel('内核已更新，正在重启');
      }
    }
  }

  // 首次启动的绝大部分耗时花在逐个下载并编译远程规则集上，
  // 干等一句「请稍候」看不出进度，这里把内核当前动作透出去
  String? get startupStage => _startupStage;

  int get remoteRuleSetCount => _ruleSetTotal;

  // 内核在 info 级为每个远程规则集各输出一行完成日志，文案见
  // sing-box route/rule/rule_set_remote.go：成功是「updated rule-set <tag>」，
  // 命中缓存未变更是「update rule-set <tag>: not modified」。
  // 下载开始那行是 debug 级，默认拿不到，因此进度按已完成数量统计。
  static final RegExp _ruleSetDone = RegExp(r'updated? rule-set ([^\s:]+)');

  final Set<String> _ruleSetReady = <String>{};
  int _ruleSetTotal = 0;

  void _trackStartupStage(String line) {
    if (_state != ConnectionPhase.connecting) {
      return;
    }

    final RegExpMatch? match = _ruleSetDone.firstMatch(line);
    if (match != null) {
      _ruleSetReady.add(match.group(1)!);
    }

    final String? next = match != null && _ruleSetTotal > 0
        ? '正在准备分流规则集 ${_ruleSetReady.length}/$_ruleSetTotal'
        : line.contains('sing-box started')
        ? '内核已启动，正在建立控制面'
        : null;

    if (next == null || next == _startupStage) {
      return;
    }
    _startupStage = next;
    notifyListeners();
  }

  // 面板 route.final 指向的分组才是默认出站，分组顺序不保证它在最前
  ProxyGroup? get mainGroup {
    final Object? route = _remote?['route'];
    final Object? tag = route is Map<String, dynamic> ? route['final'] : null;
    return (tag is String ? groupByName(tag) : null) ??
        (_groups.isEmpty ? null : _groups.first);
  }

  ProxyGroup? groupByName(String name) {
    for (final ProxyGroup group in _groups) {
      if (group.name == name) {
        return group;
      }
    }
    return null;
  }

  // 面板在 sing-box 模板的 x-sspanel.group_icons 里维护，没配的分组返回 null
  String? groupIconOf(String tag) => _groupIcons[tag];

  // 成员可能是嵌套分组，延迟一律按它解析出的叶子节点取
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

  // 本次连接以来走代理的累计量，直连不计
  TrafficSample get trafficTotal => _trafficTotal;

  List<TrafficSample> get trafficHistory => _trafficHistory;

  KernelStats get stats => _stats;

  List<Map<String, dynamic>> get connections => _connections;

  // 新的在前
  List<Map<String, dynamic>> get closedConnections => _closedConnections;

  String get routeMode => _routeMode;

  DateTime? get connectedAt => _connectedAt;

  ClashApiClient? get clash => _clash;

  bool get busy => _state == ConnectionPhase.connecting;

  void attachApi(PanelApiClient? api) {
    final bool changed = !identical(api, _api);
    _api = api;
    if (api == null) {
      _remote = null;
      unawaited(disconnect());
      return;
    }
    if (changed) {
      unawaited(preloadProxies());
    }
  }

  Future<void> preloadProxies() async {
    final PanelApiClient? api = _api;
    if (api == null || _state == ConnectionPhase.connected) {
      return;
    }

    try {
      await _fetchProfile(api);
    } on Object catch (e) {
      Logger.instance.warn(_source, '预取面板配置失败: $e');
    }

    _applyProfileProxies();
    notifyListeners();
  }

  Future<void> runPreflight() async {
    _preflightProblems = await _kernel.preflight();
    notifyListeners();
  }

  Future<void> connect() async {
    if (_state == ConnectionPhase.connecting ||
        _state == ConnectionPhase.connected) {
      return;
    }

    final PanelApiClient? api = _api;
    if (api == null) {
      _fail('尚未登录');
      return;
    }

    final int generation = ++_generation;
    _userStopped = false;
    _restartAttempt = 0;
    _setState(ConnectionPhase.connecting, error: null);

    try {
      await _fetchProfile(api);
      await _launchKernel(generation);
    } on Object catch (e) {
      if (generation != _generation) {
        return;
      }
      _fail(e.toString());
      await _teardown();
    }
  }

  Future<void> disconnect() async {
    _generation++;
    _userStopped = true;
    _restartTimer?.cancel();
    _restartTimer = null;

    await _teardown();
    _setState(ConnectionPhase.disconnected, error: null);
  }

  Future<void> updateSettings(AppSettings next) async {
    final bool needsRestart =
        _settings.affectsKernel(next) && _state == ConnectionPhase.connected;
    final bool proxyChanged =
        _settings.systemProxyEnabled != next.systemProxyEnabled;

    _settings = next;
    _settingsStore.save(next);
    Logger.instance.level = next.logLevel;
    notifyListeners();

    await syncPlatformSettings();

    if (needsRestart) {
      await _restartKernel('正在应用新设置');
      return;
    }

    if (proxyChanged && _state == ConnectionPhase.connected) {
      await _applySystemProxy();
    }
  }

  // sing-box 只在进程启动时读配置：Clash API 的 PUT /configs 是空实现，
  // PATCH /configs 只收 mode（experimental/clashapi/configs.go），端口、TUN、
  // IPv6、日志级别这类改动没有热重载入口，只能换配置重启内核
  Future<void> _restartKernel(String stage) async {
    final int generation = ++_generation;
    await _teardown(restarting: true);
    if (generation != _generation) {
      return;
    }

    _startupStage = stage;
    _setState(ConnectionPhase.connecting, error: null);

    try {
      await _rebuildProfile();
      await _launchKernel(generation);
    } on Object catch (e) {
      if (generation != _generation) {
        return;
      }
      _fail(e.toString());
      await _teardown();
    }
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
    final TrayState next = TrayState(
      connected: _state == ConnectionPhase.connected,
      busy: _state == ConnectionPhase.connecting,
      systemProxyEnabled: _settings.systemProxyEnabled,
      tunEnabled: _settings.tunEnabled,
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
      case TrayAction.toggleSystemProxy:
        unawaited(
          updateSettings(
            _settings.copyWith(
              systemProxyEnabled: !_settings.systemProxyEnabled,
            ),
          ),
        );
      case TrayAction.toggleTun:
        unawaited(
          updateSettings(_settings.copyWith(tunEnabled: !_settings.tunEnabled)),
        );
    }
  }

  Future<void> selectProxy(String group, String member) async {
    final ClashApiClient? clash = _clash;
    if (clash == null) {
      return;
    }

    await clash.selectProxy(group, member);
    // 面板下发的 selector 没开 interrupt_exist_connections，内核只断自己发起的
    // 连接，浏览器的 keep-alive / HTTP2 连接会继续留在旧节点上，表现为切换后
    // 出口 IP 不变。这里主动清掉存量连接，后续请求才会按新选中项重新建连。
    await clash.closeAllConnections();
    await _refreshProxies();
  }

  Future<void> setRouteMode(String mode) async {
    final ClashApiClient? clash = _clash;
    if (clash == null) {
      return;
    }

    await clash.setMode(mode);
    _routeMode = mode;
    notifyListeners();
  }

  // 分组成员本身也可能是分组（面板下发的「主节点」「自动选择」就是）。这类成员
  // 的延迟拿不到：内核读分组延迟用的是分组自身的 tag（clashapi/proxies.go 的
  // proxyInfo），而测完延迟是存到 group.RealTag 解析出的叶子节点上，两边键不一致。
  // 所以客户端照内核的办法把分组顺着选中项解析到叶子节点，延迟、探测进度、
  // 不可用标记一律以叶子名为键。
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
    if (await _ensureLive()) {
      await _testNodes(<String>[resolveNode(name)]);
    }
  }

  // 延迟测试要经内核的控制接口，内核没跑就没有这个接口。与其把按钮置灰
  // （禁用态的按钮连鼠标指针都不是手型，用户只会以为功能坏了），不如先连接再测
  Future<bool> _ensureLive() async {
    if (_state == ConnectionPhase.connected) {
      return true;
    }
    await connect();
    return _state == ConnectionPhase.connected;
  }

  // 逐个探测本组成员，测完一个就回填一个。
  //
  // 不用内核的 /group/{name}/delay：那是一批测完才一次性返回，界面在整批结束前
  // 看不到任何进度；而且它对 urltest 组会忽略 url 与 timeout 参数、还会静默跳过
  // 距上次探测不足 interval 的成员，失败与跳过在返回值里都表现为缺项，分不开。
  Future<void> testGroup(String group) async {
    if (!await _ensureLive()) {
      return;
    }

    final ProxyGroup? target = groupByName(group);
    if (target == null || !_testingGroups.add(group)) {
      return;
    }
    notifyListeners();

    try {
      // 成员本身可能是分组，同一叶子只测一次
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

    // Dart 单线程事件循环，取任务与记结果都发生在 await 之间，不需要额外加锁
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

  Future<void> _fetchProfile(PanelApiClient api) async {
    final RemoteProfile remote = await api.fetchSingBoxProfile();
    _profileInterval = remote.updateInterval;
    _remote = remote.config;
    _groupIcons = remote.groupIcons;
    NodeLabels.configure(remote.flagRegex);
    await _rebuildProfile();
  }

  Future<void> _rebuildProfile() async {
    final Map<String, dynamic>? remote = _remote;
    if (remote == null) {
      throw StateError('尚未获取面板配置');
    }

    _clashApiOptions = ClashApiOptions(
      port: await _pickFreePort(),
      secret: _randomSecret(),
      // goroutine 数量只有这个口有，见 ClashApiClient.fetchStats
      debugPort: await _pickFreePort(),
    );

    _profile = const ProfileAssembler().assemble(
      remote: remote,
      template: LocalTemplate(
        _settings.toTemplateOptions(),
        _clashApiOptions!,
        AppPaths.kernelCacheFile,
      ),
    );

    _ruleSetReady.clear();
    _ruleSetTotal = _profile!.remoteRuleSetCount;
  }

  Future<void> _launchKernel(int generation) async {
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

    final ClashApiClient clash = ClashApiClient(clashApi);
    await clash.waitReady();

    // 等待内核就绪期间同样可能被取代：这次连接已经没有意义。
    // 大多数情况下取代者（disconnect 的兜底还原，或新一轮重启）已经停过内核，
    // 这里的 stop 只是兜底；真正要避免的是继续往下改共享状态、把界面显示改回「已连接」
    if (generation != _generation) {
      clash.close();
      await _kernel.stop();
      return;
    }
    _clash = clash;

    await _refreshProxies();
    _routeMode = await clash.fetchMode();
    await _applySystemProxy();

    if (generation != _generation) {
      return;
    }

    _scheduleProxyRefresh();
    _scheduleStatsRefresh();
    _scheduleProfileRefresh();

    _connectedAt = DateTime.now();
    _restartAttempt = 0;
    _setState(ConnectionPhase.connected, error: null);
  }

  Future<void> _applySystemProxy() async {
    if (!_platform.supportsSystemProxy) {
      return;
    }

    if (_settings.systemProxyEnabled) {
      await _platform.setSystemProxy(port: _settings.mixedPort);
    } else {
      await _platform.restoreSystemProxy();
    }
  }

  // 走势图的采样点数：每秒一个样本，60 点即最近一分钟
  static const int _trafficHistoryLength = 60;

  void _scheduleStatsRefresh() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_pollStats()),
    );
    unawaited(_pollStats());
  }

  Future<void> refreshStats() => _pollStats();

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

  // 内核内部留了最近 1000 条已关闭连接（trafficontrol 的 closedConnectionsLimit），
  // 但只有 libbox 命令接口取得到，Clash API 的 /connections 只给活跃项。
  // 客户端按快照差分自己补一份，上限对齐内核。
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

    // 首个样本没有区间，算速率会得到无穷大
    if (last == null) {
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

  // chains 是反转过的出站链，首项即最终落地的出站。按类型判断而不是按 tag：
  // Clash API 给的类型来自 constant.ProxyDisplayName，block 那一档被 clashapi
  // 改成了 Reject（clashapi/proxies.go proxyInfo），这几类都没出网。
  bool _viaProxy(Map<String, dynamic> item) {
    final Object? chains = item['chains'];
    if (chains is! List || chains.isEmpty) {
      return false;
    }
    return !const <String>{
      'direct',
      'block',
      'reject',
      'dns',
    }.contains(typeOf('${chains.first}').toLowerCase());
  }

  // urltest 组的选中项由内核按自身 interval 重算，不轮询界面上的「当前」会停在旧值
  void _scheduleProxyRefresh() {
    _proxyRefreshTimer?.cancel();
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

  void _scheduleProfileRefresh() {
    _profileRefreshTimer?.cancel();
    _profileRefreshTimer = Timer.periodic(
      _profileInterval,
      (_) => unawaited(refreshProfileFromPanel()),
    );
  }

  Future<void> refreshProfileFromPanel() async {
    final PanelApiClient? api = _api;
    if (api == null) {
      return;
    }

    // 比对面板下发的原始配置，而不是装配后的 JSON：装配时会给控制面重新分配端口
    // 与 secret，装配结果每次都不一样，比出来永远是「有变更」，每次刷新都会重连
    final String? previous = _remote == null ? null : jsonEncode(_remote);

    try {
      await _fetchProfile(api);
    } on ApiException catch (e) {
      Logger.instance.warn(_source, '刷新面板配置失败: $e');
      return;
    }

    if (_state != ConnectionPhase.connected ||
        jsonEncode(_remote) == previous) {
      return;
    }

    Logger.instance.info(_source, '面板配置有变更，重启内核以应用');
    await _restartKernel('面板配置有变更，正在重启内核');
  }

  Future<void> _refreshProxies() async {
    final ClashApiClient? clash = _clash;
    if (clash == null) {
      return;
    }

    final (List<ProxyGroup>, List<ProxyNode>) result = await clash
        .fetchProxies();
    _groups = result.$1;
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
    notifyListeners();
  }

  void _applyProfileProxies() {
    final Object? outbounds = _remote?['outbounds'];
    if (outbounds is! List) {
      _groups = const <ProxyGroup>[];
      _nodes = const <ProxyNode>[];
      return;
    }

    final List<ProxyGroup> groups = <ProxyGroup>[];
    final List<ProxyNode> nodes = <ProxyNode>[];

    for (final Object? outbound in outbounds) {
      if (outbound is! Map<String, dynamic>) {
        continue;
      }

      final String tag = outbound['tag'] as String? ?? '';
      if (tag.isEmpty) {
        continue;
      }

      final String type = outbound['type'] as String? ?? '';
      final Object? members = outbound['outbounds'];

      if (members is List) {
        groups.add(
          ProxyGroup(
            name: tag,
            type: _displayType(type),
            // 选中项一律留空：内核启动时会从 cache_file 恢复用户上次的选择，
            // urltest 组更是要测完延迟才定。拿配置里的 default 或首个成员顶替，
            // 界面就会把每个分组都显示成「自动选择」，而这与实际选中项无关。
            now: '',
            members: members.whereType<String>().toList(growable: false),
          ),
        );
      } else {
        nodes.add(ProxyNode(name: tag, type: _displayType(type), delay: 0));
      }
    }

    _groups = groups;
    _nodes = nodes;
  }

  // 面板配置里的类型是 sing-box 的原名（全小写），Clash API 给的是内核自己的
  // 展示名。两个来源必须归一：组类型不对齐就共用不了 ProxyGroup.selectable，
  // 协议名不对齐则未连接时显示 vless、连上后变 VLESS，同一节点看着像换了协议。
  // 对照表照抄内核 constant.ProxyDisplayName，表里没有的原样透出。
  static String _displayType(String configType) =>
      _displayTypes[configType] ?? configType;

  static const Map<String, String> _displayTypes = <String, String>{
    'direct': 'Direct',
    'block': 'Block',
    'dns': 'DNS',
    'socks': 'SOCKS',
    'http': 'HTTP',
    'mixed': 'Mixed',
    'shadowsocks': 'Shadowsocks',
    'shadowsocksr': 'ShadowsocksR',
    'shadowtls': 'ShadowTLS',
    'vmess': 'VMess',
    'vless': 'VLESS',
    'trojan': 'Trojan',
    'naive': 'Naive',
    'wireguard': 'WireGuard',
    'hysteria': 'Hysteria',
    'hysteria2': 'Hysteria2',
    'tuic': 'TUIC',
    'anytls': 'AnyTLS',
    'tor': 'Tor',
    'ssh': 'SSH',
    'tailscale': 'Tailscale',
    'selector': 'Selector',
    'urltest': 'URLTest',
  };

  void _onKernelStatus(KernelStatus status) {
    if (status.state != KernelState.failed || _userStopped) {
      return;
    }

    _scheduleRestart(status.message ?? '内核异常退出（退出码 ${status.exitCode}）');
  }

  void _scheduleRestart(String reason) {
    if (_restartTimer != null) {
      return;
    }

    if (_restartAttempt >= _backoff.length) {
      _fail('$reason；连续重启 ${_backoff.length} 次仍未成功，已停止重试');
      unawaited(_teardown());
      return;
    }

    final Duration delay = _backoff[_restartAttempt];
    _restartAttempt++;
    Logger.instance.warn(
      _source,
      '$reason，${delay.inSeconds} 秒后第 $_restartAttempt 次重启',
    );
    _setState(ConnectionPhase.connecting, error: reason);

    _restartTimer = Timer(delay, () async {
      _restartTimer = null;
      if (_userStopped) {
        return;
      }

      final int generation = ++_generation;
      try {
        await _teardown(restarting: true);
        if (generation != _generation) {
          return;
        }
        await _rebuildProfile();
        await _launchKernel(generation);
      } on Object catch (e) {
        if (generation == _generation) {
          _scheduleRestart('重启失败：$e');
        }
      }
    });
  }

  // restarting 表示内核随即会带新配置重新启动：此时不还原系统代理（马上要按同一
  // 端口设回去，中间还原一次只会让浏览器多断一次、这段时间还绕过代理直连），
  // 也不发通知，避免界面在断开态上闪一帧
  Future<void> _teardown({bool restarting = false}) async {
    _profileRefreshTimer?.cancel();
    _profileRefreshTimer = null;
    _proxyRefreshTimer?.cancel();
    _proxyRefreshTimer = null;
    _statsTimer?.cancel();
    _statsTimer = null;

    _clash?.close();
    _clash = null;

    await _kernel.stop();

    if (!restarting && _platform.supportsSystemProxy) {
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
      notifyListeners();
    }
  }

  void _setState(ConnectionPhase state, {required String? error}) {
    _state = state;
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

  @override
  void dispose() {
    unawaited(_kernelStatusSubscription.cancel());
    unawaited(_kernelLogSubscription.cancel());
    unawaited(_trayActionSubscription?.cancel());
    _restartTimer?.cancel();
    _profileRefreshTimer?.cancel();
    _proxyRefreshTimer?.cancel();
    _statsTimer?.cancel();
    _clash?.close();
    unawaited(_kernel.dispose());
    super.dispose();
  }
}
