import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ecycloud_client/core/app_paths.dart';
import 'package:ecycloud_client/data/api/api_exception.dart';
import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:ecycloud_client/data/models/user_profile.dart';
import 'package:ecycloud_client/data/models/online_device.dart';
import 'package:ecycloud_client/data/store/json_file_store.dart';
import 'package:ecycloud_client/data/store/panel_response_cache.dart';
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:ecycloud_client/data/store/speed_test_quota_store.dart';
import 'package:ecycloud_client/data/store/traffic_rank_store.dart';
import 'package:ecycloud_client/domain/config/local_template.dart';
import 'package:ecycloud_client/domain/config/profile_assembler.dart';
import 'package:ecycloud_client/domain/kernel/kernel_controller.dart';
import 'package:ecycloud_client/domain/kernel/node_speed_tester.dart';
import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/l10n/app_language.dart';
import 'package:ecycloud_client/l10n/l10n.dart';
import 'package:ecycloud_client/state/connection_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late _Client client;
  late _Kernel kernel;
  late PanelResponseCache cache;
  late ConnectionController connection;
  late _SpeedTester speedTester;
  late _Settings settings;
  late HttpOverrides? overrides;

  setUp(() async {
    overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    dir = Directory.systemTemp.createTempSync('ecycloud-offline-');
    JsonFileStore(AppPaths.selectorCache, 'test').clear();
    JsonFileStore(AppPaths.speedTestQuota, 'test').clear();
    JsonFileStore(AppPaths.trafficRank, 'test').clear();
    final ServerSocket probe = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    settings = _Settings()
      ..mixedPort = probe.port < 65535 ? probe.port - 1 : probe.port;
    await probe.close();
    speedTester = _SpeedTester();
    client = _Client()..token = 'test-token';
    kernel = _Kernel();
    cache = PanelResponseCache(
      profileStore: JsonFileStore(File('${dir.path}/profile.json'), 'test'),
      remoteStore: JsonFileStore(File('${dir.path}/remote.json'), 'test'),
    );
    connection = ConnectionController(
      platform: _Platform(),
      kernel: kernel,
      settingsStore: settings,
      panelCache: cache,
      speedTester: speedTester,
    );
  });
  tearDown(() async {
    L10n.current = AppLanguage.zhCN;
    await connection.shutdown();
    connection.dispose();
    client.close();
    JsonFileStore(AppPaths.selectorCache, 'test').clear();
    JsonFileStore(AppPaths.speedTestQuota, 'test').clear();
    JsonFileStore(AppPaths.trafficRank, 'test').clear();
    HttpOverrides.global = overrides;
    dir.deleteSync(recursive: true);
  });

  void seed({Duration lifetime = const Duration(hours: 2)}) {
    cache.saveProfile(
      'a@example.test',
      UserProfile.fromJson(<String, dynamic>{
        'id': 1,
        'email': 'a@example.test',
      }),
    );
    cache.saveRemote('a@example.test', client.profile(lifetime));
    connection.attachApi(client, accountKey: 'a@example.test');
  }

  for (final int limit in <int>[0, 1]) {
    test('旧在线快照或拒绝通知不拦截连接，上限$limit', () async {
      client
        ..fresh = true
        ..profileExtras = <String, dynamic>{
          'node_connector': limit,
          'online_client_count': 99,
          'device_kick_notice': true,
          'device_kick_reason': 'limit_denied',
        };
      int confirmations = 0;
      connection.confirmDeviceLimitKick = (_) async {
        confirmations++;
        return null;
      };
      seed();
      await connection.connect();
      expect(
        connection.state,
        ConnectionPhase.connected,
        reason: connection.error,
      );
      expect(confirmations, 0);
      final int stops = kernel.stops;
      await connection.handleDeviceLimitDenied();
      expect(kernel.stops, stops);
      expect(connection.state, ConnectionPhase.connected);
      expect(confirmations, limit == 0 ? 0 : 1);
    });
  }

  for (final int limit in <int>[0, 1]) {
    for (final String reason in <String>['limit', 'limit_denied']) {
      test('缓存自动通知不阻止离线连接，上限$limit，原因$reason', () async {
        seed();
        cache.saveProfile(
          'a@example.test',
          UserProfile.fromJson(<String, dynamic>{
            'id': 1,
            'email': 'a@example.test',
            'node_connector': limit,
            'device_kick_notice': true,
            'device_kick_reason': reason,
          }),
        );
        await connection.connect();
        expect(
          connection.state,
          ConnectionPhase.connected,
          reason: connection.error,
        );
        expect(kernel.starts, 1);
        expect(client.profileCalls, 0);
      });
    }
  }

  test('缓存主动下线通知仍要求在线复核', () async {
    seed();
    cache.saveProfile(
      'a@example.test',
      UserProfile.fromJson(<String, dynamic>{
        'id': 1,
        'email': 'a@example.test',
        'device_kick_notice': true,
        'device_kick_reason': 'remove',
      }),
    );
    await connection.connect();
    expect(kernel.starts, 0);
    expect(client.profileCalls, 1);
  });

  test('已在线设备收到迟到拒绝通知不腾位、不停止内核', () async {
    client
      ..fresh = true
      ..profileExtras = <String, dynamic>{
        'node_connector': 1,
        'online_client_count': 1,
        'online_client_self': true,
        'device_kick_notice': true,
        'device_kick_reason': 'limit_denied',
      };
    connection.confirmDeviceLimitKick = (_) async => throw StateError('不应确认腾位');
    seed();
    await connection.connect();
    final int stops = kernel.stops;
    await connection.handleDeviceLimitDenied();
    expect(connection.state, ConnectionPhase.connected);
    expect(kernel.stops, stops);
  });

  test('接受腾位只申请名额，不重启现有连接', () async {
    client
      ..fresh = true
      ..profileExtras = <String, dynamic>{
        'node_connector': 1,
        'online_client_count': 1,
        'device_kick_notice': true,
        'device_kick_reason': 'limit_denied',
      };
    connection.confirmDeviceLimitKick = (_) async => 'other-device';
    seed();
    await connection.connect();
    final int starts = kernel.starts;
    final int stops = kernel.stops;
    await connection.handleDeviceLimitDenied();
    expect(client.reclaimTargets, <String>['other-device']);
    expect(kernel.starts, starts);
    expect(kernel.stops, stops);
    expect(connection.state, ConnectionPhase.connected);
  });

  for (final String stage in <String>['reserve', 'report']) {
    test('测速 $stage 返回 401 时立即清除本地会话并停止内核', () async {
      kernel.probeSpeeds = true;
      final ApiException denied = ApiException('revoked', statusCode: 401);
      if (stage == 'reserve') {
        client.reserveError = denied;
      } else {
        client.reportError = denied;
      }
      seed();
      connection.attachProfileLookup(
        () => UserProfile.fromJson(<String, dynamic>{'id': 2}),
      );
      bool rejected = false;
      connection.onSessionRejected = () async {
        rejected = true;
        await connection.shutdown(clearSession: true);
        client.token = null;
        connection.attachApi(null);
      };
      await connection.connect();
      await connection.testSpeed('node-1');
      expect(rejected, isTrue);
      expect(client.token, isNull);
      expect(kernel.status.state, KernelState.stopped);
      expect(cache.loadRemote('a@example.test'), isNull);
    });
  }

  test('账户配置版本改变后立即刷新，不等待定时刷新', () async {
    seed();
    await connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    client.fresh = true;
    connection.notePanelRevision('candidate');
    for (
      int i = 0;
      i < 80 && cache.loadRemote('a@example.test')?.revision != 'candidate';
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(cache.loadRemote('a@example.test')?.revision, 'candidate');
  });

  for (final AppLanguage language in AppLanguage.values) {
    test('配置校验失败显示目标语言并停止重试：${language.name}', () async {
      L10n.current = language;
      client.fresh = true;
      seed();
      await connection.connect();
      expect(connection.state, ConnectionPhase.connected);
      kernel.invalid = 'invalid protocol';
      await connection.updateSettings(
        connection.settings.copyWith(ipv6Enabled: true),
      );
      expect(connection.state, ConnectionPhase.failed);
      expect(
        connection.formatError,
        L10n.t('配置校验未通过：{0}', <Object>['invalid protocol']),
      );
      expect(kernel.starts, 1);
    });
  }

  test('首次配置校验失败不能提交离线缓存', () async {
    client.fresh = true;
    kernel.invalid = 'invalid protocol';
    connection.attachApi(client, accountKey: 'a@example.test');
    await connection.connect();
    expect(kernel.starts, 0);
    expect(cache.loadRemote('a@example.test'), isNull);
  });

  test('仅客户端无法访问面板时从有效缓存启动内核，不等待资料接口', () async {
    seed();
    await connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(connection.state, ConnectionPhase.connected);
    expect(client.profileCalls, 0);
    expect(kernel.starts, 1);
    expect(connection.panelOffline, isTrue);
    expect(cache.loadRemote('a@example.test')?.revision, 'verified');
  });

  test('面板签发的配置未到期时，超过 24 小时仍能从缓存连接', () async {
    seed(lifetime: const Duration(hours: 48));
    await connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(connection.state, ConnectionPhase.connected);
    expect(client.profileCalls, 0);
    expect(kernel.starts, 1);
    expect(connection.panelOffline, isTrue);
  });

  test('明确 401 拒绝后停止内核并清除可用缓存', () async {
    seed();
    client.configError = ApiException('revoked', statusCode: 401);
    bool rejected = false;
    connection.onSessionRejected = () async {
      rejected = true;
      await connection.shutdown(clearSession: true);
    };
    await connection.connect();
    for (int i = 0; i < 50 && !rejected; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(rejected, isTrue);
    expect(kernel.status.running, isFalse);
    expect(cache.loadRemote('a@example.test'), isNull);
  });

  for (final String scenario in <String>[
    'reported',
    'timeout',
    'denied',
    'download-failed',
  ]) {
    test('测速 $scenario 的本地计次与已测得结果保持一致', () async {
      kernel.probeSpeeds = true;
      if (scenario == 'timeout') {
        client.reportError = ApiException('模拟上报超时', transportFailure: true);
      }
      client.denyReport = scenario == 'denied';
      speedTester.failed = scenario == 'download-failed';
      seed();
      connection.attachProfileLookup(
        () => UserProfile.fromJson(<String, dynamic>{'id': 2}),
      );
      await connection.connect();
      await connection.testSpeed('node-1');
      final SpeedTestQuotaStore quota = SpeedTestQuotaStore()
        ..bindAccount('a@example.test');
      expect(
        quota.remaining('node-1'),
        scenario == 'download-failed'
            ? 5
            : scenario == 'denied'
            ? 0
            : 4,
      );
      expect(client.speedReports, scenario == 'download-failed' ? 0 : 1);
      expect(
        connection.speedOf('node-1') > 0,
        scenario == 'reported' || scenario == 'timeout',
      );
    });
  }

  test('连续上报失败仍只允许五次成功测速，第六次在本地拒绝', () async {
    kernel.probeSpeeds = true;
    client.reportError = ApiException('模拟上报失败', statusCode: 503);
    seed();
    connection.attachProfileLookup(
      () => UserProfile.fromJson(<String, dynamic>{'id': 2}),
    );
    await connection.connect();
    for (int count = 1; count <= 5; count++) {
      await connection.testSpeed('node-1');
      final SpeedTestQuotaStore quota = SpeedTestQuotaStore()
        ..bindAccount('a@example.test');
      expect(quota.remaining('node-1'), 5 - count);
    }
    expect(await connection.testSpeed('node-1'), contains('5'));
    expect(speedTester.downloads, 5);
    expect(client.speedReports, 5);
    expect(client.speedReservations, 5);
  });

  test('普通下线立即保存排行并保留内核待机、缓存和令牌，原会话可以重连', () async {
    kernel.probeTraffic = true;
    final Completer<void> sampled = Completer<void>();
    connection.addListener(() {
      final List<TrafficRankRow> hosts = connection.trafficRankHosts(
        TrafficRankDay.today,
      );
      if (!sampled.isCompleted &&
          hosts.isNotEmpty &&
          hosts.single.bytes >= 200) {
        sampled.complete();
      }
    });
    seed();
    await connection.connect();
    await sampled.future.timeout(const Duration(seconds: 5));
    final int live = connection
        .trafficRankHosts(TrafficRankDay.today)
        .single
        .bytes;
    final TrafficRankStore saved = TrafficRankStore()
      ..bindAccount('a@example.test');
    expect(saved.topHosts(TrafficRankDay.today).single.bytes, 100);
    final int starts = kernel.starts;
    final int stops = kernel.stops;
    await connection.disconnect();
    final TrafficRankStore reopened = TrafficRankStore()
      ..bindAccount('a@example.test');
    expect(reopened.topHosts(TrafficRankDay.today).single.bytes, live);
    expect(connection.state, ConnectionPhase.disconnected);
    expect(kernel.status.running, isTrue);
    expect(kernel.starts, starts);
    expect(kernel.stops, stops);
    expect(client.token, 'test-token');
    expect(cache.loadRemote('a@example.test'), isNotNull);
    await connection.connect();
    expect(connection.state, ConnectionPhase.connected);
    expect(kernel.starts, starts);
  });

  for (final String source in <String>[
    'config',
    'revision',
    'account-status',
  ]) {
    test('$source 返回 403 不撤销登录或停止有效缓存连接', () async {
      seed();
      final ApiException forbidden = ApiException('forbidden', statusCode: 403);
      if (source == 'account-status') {
        connection.onPanelSync = () async => throw forbidden;
      } else if (source == 'revision') {
        client.revisionError = forbidden;
      } else {
        client.configError = forbidden;
      }
      bool rejected = false;
      connection.onSessionRejected = () async {
        rejected = true;
        await connection.shutdown(clearSession: true);
      };
      await connection.connect();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(rejected, isFalse);
      expect(client.token, 'test-token');
      expect(kernel.status.running, isTrue);
      expect(connection.state, ConnectionPhase.connected);
      expect(cache.loadRemote('a@example.test')?.revision, 'verified');
    });
  }

  test('缓存授权到期后自动停用，面板失联不会延长期限', () async {
    seed(lifetime: const Duration(milliseconds: 700));
    await connection.connect();
    expect(kernel.starts, 1);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(kernel.status.running, isFalse);
    expect(connection.state, ConnectionPhase.failed);
    expect(connection.error, contains('授权已到期'));
  });

  test('配置戳接口明确拒绝时，不用全量接口的网络故障掩盖撤销', () async {
    seed();
    client.revisionError = ApiException('revoked', statusCode: 401);
    await connection.connect();
    for (int i = 0; i < 50 && kernel.status.running; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(kernel.status.running, isFalse);
    expect(cache.loadRemote('a@example.test'), isNull);
  });

  test('不同登录令牌不能使用旧会话缓存', () async {
    seed();
    client.token = 'another-token';
    await connection.connect();
    expect(client.profileCalls, 1);
    expect(kernel.starts, 0);
  });

  test('候选配置校验失败后保留正在使用的配置和持久化缓存', () async {
    seed();
    await connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    client.fresh = true;
    kernel.invalid = 'invalid protocol';
    await connection.refreshProfileFromPanel();
    expect(kernel.status.running, isTrue);
    expect(kernel.starts, 1);
    expect(cache.loadRemote('a@example.test')?.revision, 'verified');
    expect(connection.groups.single.name, 'group');
  });

  test('面板节点变化重启保留已连接时间，主动断开后重新计时', () async {
    seed();
    await connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final DateTime connectedAt = connection.connectedAt!;
    client
      ..fresh = true
      ..nodes = <String>['node-1', 'node-2'];

    expect(await connection.refreshProfileFromPanel(), '更新成功');
    expect(kernel.starts, 2);
    expect(connection.state, ConnectionPhase.connected);
    expect(connection.groups.single.members, <String>['node-1', 'node-2']);
    expect(connection.connectedAt, connectedAt);

    await connection.disconnect();
    expect(connection.connectedAt, isNull);
    await connection.connect();
    expect(connection.state, ConnectionPhase.connected);
    expect(connection.connectedAt!.isAfter(connectedAt), isTrue);
  });

  test('Fake-IP 下更新节点参数、增删节点不重启，不关闭已有连接', () async {
    client.nodeProviders = true;
    seed();
    await connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final DateTime connectedAt = connection.connectedAt!;
    client
      ..fresh = true
      ..nodes = <String>['node-1', 'node-2']
      ..nodePort = 8443;
    expect(await connection.refreshProfileFromPanel(), '更新成功');
    expect(kernel.starts, 1);
    expect(kernel.stops, 0);
    expect(kernel.fullReloads, 0);
    expect(kernel.closedConnections, 0);
    expect(kernel.providerUpdates, greaterThan(0));
    expect(connection.groups.single.members, <String>['node-1', 'node-2']);
    expect(connection.connectedAt, connectedAt);
    client.nodes = <String>['node-2'];
    client.revision++;
    expect(await connection.refreshProfileFromPanel(), '更新成功');
    expect(kernel.starts, 1);
    expect(connection.groups.single.members, <String>['node-2']);
    expect(connection.connectedAt, connectedAt);
  });

  test('手动刷新面板配置在配置戳未变时仍拉取全量配置', () async {
    client.nodeProviders = true;
    seed();
    await connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    client.fresh = true;
    await connection.refreshProfileFromPanel();
    final int calls = client.clashCalls;
    await connection.refreshProfileFromPanel();
    expect(client.clashCalls, calls);
    await connection.refreshProfileFromPanel(force: true);
    expect(client.clashCalls, calls + 1);
  });

  for (final String stage in <String>['write', 'update']) {
    test('节点独立更新 $stage 失败保留当前连接和原有缓存', () async {
      client.nodeProviders = true;
      seed();
      await connection.connect();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final DateTime connectedAt = connection.connectedAt!;
      client
        ..fresh = true
        ..nodes = <String>['node-1', 'node-2'];
      kernel.failWrite = stage == 'write';
      kernel.failUpdate = stage == 'update';
      expect(await connection.refreshProfileFromPanel(), startsWith('更新失败'));
      expect(kernel.starts, 1);
      expect(kernel.stops, 0);
      expect(kernel.closedConnections, 0);
      expect(connection.state, ConnectionPhase.connected);
      expect(connection.connectedAt, connectedAt);
      expect(connection.groups.single.members, <String>['node-1']);
      expect(cache.loadRemote('a@example.test')?.revision, 'verified');
    });
  }

  test('已连接时更换令牌会清理旧会话并重新启动内核', () async {
    seed();
    await connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final _Client next = _Client()
      ..token = 'new-token'
      ..fresh = true;
    addTearDown(next.close);
    connection.attachApi(next, accountKey: 'a@example.test');
    for (
      int i = 0;
      i < 100 &&
          (kernel.starts < 2 || connection.state != ConnectionPhase.connected);
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(kernel.starts, 2);
    expect(connection.state, ConnectionPhase.connected);
    expect(cache.loadRemote('a@example.test')?.cacheBinding, next.cacheBinding);
  });

  for (final (String label, String account, List<String> nodes, String expected)
      in <(String, String, List<String>, String)>[
        ('同账户重新登录保留各组选中节点', 'a@example.test', ['node-1', 'node-2'], 'node-2'),
        ('其他账户不继承选中节点', 'b@example.test', ['node-1', 'node-2'], 'node-1'),
        ('原节点已移除时不恢复无效选择', 'a@example.test', ['node-1'], 'node-1'),
      ]) {
    test(label, () async {
      client
        ..fresh = true
        ..nodes = <String>['node-1', 'node-2']
        ..groups = <String>['group', 'secondary'];
      seed();
      await connection.connect();
      expect(connection.state, ConnectionPhase.connected);
      for (final String group in client.groups) {
        await connection.selectProxy(group, 'node-2');
        expect(connection.groupByName(group)?.now, 'node-2');
      }

      await connection.shutdown(clearSession: true);
      expect(kernel.status.running, isFalse);
      expect(connection.groups, isEmpty);
      expect(cache.loadProfile('a@example.test'), isNull);
      expect(cache.loadRemote('a@example.test'), isNull);
      expect(
        JsonFileStore(AppPaths.selectorCache, 'test').read(),
        <String, Object>{
          'account': 'a@example.test',
          'selected': <String, String>{
            'group': 'node-2',
            'secondary': 'node-2',
          },
        },
      );
      connection.dispose();

      final _Client next = _Client()
        ..token = 'new-token'
        ..fresh = true
        ..account = account
        ..nodes = nodes
        ..groups = client.groups;
      addTearDown(next.close);
      kernel = _Kernel();
      connection = ConnectionController(
        platform: _Platform(),
        kernel: kernel,
        settingsStore: _Settings(),
        panelCache: cache,
      )..attachApi(next, accountKey: account);
      await connection.connect();
      expect(
        connection.state,
        ConnectionPhase.connected,
        reason: connection.error,
      );
      for (final String group in next.groups) {
        expect(connection.groupByName(group)?.now, expected);
      }
      expect(cache.loadRemote(account)?.cacheBinding, next.cacheBinding);
    });
  }
}

class _Client extends PanelApiClient {
  _Client()
    : super(
        baseUrl: 'https://panel.example.test',
        configBaseUrl: 'https://sub.example.test',
        device: const DeviceInfo(
          platform: 'windows',
          deviceId: 'device-1',
          deviceName: '',
          deviceModel: '',
          osVersion: '',
          appVersion: 'test',
        ),
      );
  int profileCalls = 0;
  int clashCalls = 0;
  Map<String, dynamic> profileExtras = <String, dynamic>{};
  final List<String> reclaimTargets = <String>[];
  bool fresh = false;
  String account = 'a@example.test';
  List<String> nodes = <String>['node-1'];
  List<String> groups = <String>['group'];
  bool nodeProviders = false;
  int nodePort = 443;
  int revision = 0;
  int speedReports = 0;
  int speedReservations = 0;
  ApiException? reportError;
  ApiException? reserveError;
  bool denyReport = false;
  ApiException configError = ApiException('offline', connectFailed: true);
  ApiException? revisionError;
  RemoteProfile profile(Duration lifetime) => RemoteProfile(
    config: <String, dynamic>{
      'proxies': nodeProviders ? <Object>[] : nodeConfigs,
      if (nodeProviders)
        'proxy-providers': <String, Object>{
          'ecy-panel-nodes': <String, Object>{
            'type': 'file',
            'path': 'ecy-panel-nodes.json',
            'payload': nodeConfigs,
          },
        },
      'proxy-groups': <Object>[
        for (final String group in groups)
          <String, Object>{
            'name': group,
            'type': 'select',
            if (nodeProviders)
              'use': <String>['ecy-panel-nodes']
            else
              'proxies': nodes,
          },
      ],
      'rules': <String>['MATCH,group'],
    },
    revision: fresh
        ? (nodeProviders ? 'candidate-$revision' : 'candidate')
        : 'verified',
    groupIcons: const <String, String>{},
    nodeLabels: const <String, String>{},
    flagRegex: '',
    offlineIssuedAt: DateTime.now().subtract(const Duration(seconds: 1)),
    offlineUntil: DateTime.now().add(lifetime),
    cacheBinding: cacheBinding,
  );
  List<Object> get nodeConfigs => <Object>[
    for (final String node in nodes)
      <String, Object>{
        'name': node,
        'type': 'ss',
        'server': '127.0.0.1',
        'port': nodePort,
        'cipher': 'aes-128-gcm',
        'password': 'test',
      },
  ];
  @override
  Future<UserProfile> fetchProfile() async {
    profileCalls++;
    if (fresh) {
      return UserProfile.fromJson(<String, dynamic>{
        'id': 1,
        'email': account,
        ...profileExtras,
      });
    }
    throw ApiException('offline', connectFailed: true);
  }

  @override
  Future<List<OnlineDevice>> fetchOnlineDevices() async =>
      const <OnlineDevice>[];

  @override
  Future<String> reclaimDeviceSlot({String targetDeviceId = ''}) async {
    reclaimTargets.add(targetDeviceId);
    return '';
  }

  @override
  Future<RemoteProfile> fetchClashProfile({int? fallbackProxyPort}) async {
    clashCalls++;
    if (fresh) return profile(const Duration(hours: 2));
    throw configError;
  }

  @override
  Future<String> fetchConfigRevision({int? fallbackProxyPort}) async {
    if (fresh) return nodeProviders ? 'candidate-$revision' : 'candidate';
    throw revisionError ?? configError;
  }

  @override
  Future<void> refreshConfigDirectAddresses() async {}
  @override
  Future<void> ensureConfigDirectAddresses() async {}
  @override
  Future<void> reportNodeUsed() async {}
  @override
  Future<SpeedTestReserveResult> reserveSpeedTest(
    List<String> proxyNames,
  ) async {
    if (reserveError != null) throw reserveError!;
    speedReservations++;
    return SpeedTestReserveResult(
      allowed: proxyNames,
      denied: const <SpeedTestDenied>[],
    );
  }

  @override
  Future<SpeedTestReserveResult> reportSpeedTest(
    List<({String proxyName, int bytesPerSecond})> results,
  ) async {
    speedReports++;
    final ApiException? error = reportError;
    if (error != null) throw error;
    return SpeedTestReserveResult(
      allowed: denyReport
          ? const <String>[]
          : results.map((result) => result.proxyName).toList(),
      denied: denyReport
          ? <SpeedTestDenied>[
              SpeedTestDenied(
                proxyName: results.single.proxyName,
                message: '模拟额度已满',
                resetAt: DateTime.now().add(const Duration(hours: 1)),
              ),
            ]
          : const <SpeedTestDenied>[],
    );
  }
}

class _Kernel implements KernelController {
  HttpServer? server;
  HttpServer? speedProbe;
  bool probeSpeeds = false;
  bool probeTraffic = false;
  int trafficSamples = 0;
  int starts = 0;
  int stops = 0;
  int fullReloads = 0;
  int closedConnections = 0;
  int providerUpdates = 0;
  bool failWrite = false;
  bool failUpdate = false;
  Map<String, dynamic> config = <String, dynamic>{};
  String binding = '';
  String? invalid;
  @override
  KernelStatus get status => server == null
      ? const KernelStatus.stopped()
      : const KernelStatus(state: KernelState.running);
  @override
  Stream<KernelStatus> get statusStream => const Stream<KernelStatus>.empty();
  @override
  Stream<String> get kernelLog => const Stream<String>.empty();
  @override
  bool get cacheReady => true;
  @override
  bool get upgradable => false;
  @override
  Future<void> bindSession(String cacheKey) async {
    if (cacheKey != binding) {
      await stop();
      binding = cacheKey;
    }
  }

  @override
  Future<String?> validate(String configJson) async => invalid;
  @override
  Future<void> start({
    required String configJson,
    required ClashApiOptions clashApi,
  }) async {
    await stop();
    starts++;
    config = jsonDecode(configJson) as Map<String, dynamic>;
    if (probeSpeeds) {
      final Map listener = (config['listeners'] as List).single as Map;
      speedProbe = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        listener['port'] as int,
      );
      speedProbe!.listen((HttpRequest request) async {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
      });
    }
    final Map<String, Map<String, Object>> proxies =
        <String, Map<String, Object>>{
          for (final dynamic node in config['proxies'] as List)
            node['name'] as String: <String, Object>{'type': 'Shadowsocks'},
          for (final dynamic group in config['proxy-groups'] as List)
            group['name'] as String: <String, Object>{
              'type': 'Selector',
              'all': AssembledProfile.membersOf(config, group as Map),
              'now':
                  (group['default-selected'] ??
                          AssembledProfile.membersOf(config, group).first)
                      as String,
            },
        };
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, clashApi.port);
    server!.listen((HttpRequest request) async {
      if (request.method == 'DELETE' &&
          request.uri.pathSegments.first == 'connections') {
        closedConnections++;
      }
      if (request.method == 'PUT' && request.uri.path == '/configs') {
        fullReloads++;
      }
      if (request.method == 'PUT' &&
          request.uri.path.startsWith('/providers/proxies/')) {
        if (failUpdate) {
          failUpdate = false;
          request.response.statusCode = 500;
          await request.response.close();
          return;
        }
        providerUpdates++;
        for (final Map group in (config['proxy-groups'] as List).cast<Map>()) {
          final List<String> members = AssembledProfile.membersOf(
            config,
            group,
          );
          final Map<String, Object> current = proxies[group['name']]!;
          current['all'] = members;
          if (!members.contains(current['now'])) current['now'] = members.first;
        }
      }
      if (request.method == 'PUT' &&
          request.uri.pathSegments.first == 'proxies') {
        final Map<String, dynamic> selected = jsonDecode(
          await utf8.decoder.bind(request).join(),
        ) as Map<String, dynamic>;
        proxies[request.uri.pathSegments.last]!['now'] =
            selected['name'] as String;
      }
      final Object body = switch (request.uri.path) {
        '/proxies' => <String, Object>{'proxies': proxies},
        '/connections' => <String, Object>{
          'connections': <Object>[
            if (probeTraffic)
              <String, Object>{
                'id': 'live-connection',
                'upload': 0,
                'download': ++trafficSamples * 100,
                'chains': <String>['node-1'],
                'metadata': <String, String>{'host': 'live.test'},
              },
          ],
        },
        '/providers/proxies' => <String, Object>{
          'providers': <String, Object>{
            if ((config['proxy-providers'] as Map?)?.containsKey(
                  'ecy-panel-nodes',
                ) ==
                true)
              'ecy-panel-nodes': <String, Object>{
                'proxies': <Object>[
                  for (final Map node in AssembledProfile.nodesOf(config))
                    <String, Object>{
                      'name': node['name'] as String,
                      'type': 'Shadowsocks',
                    },
                ],
              },
          },
        },
        '/configs' => <String, Object>{
          'mode': 'rule',
          'tun': <String, bool>{'enable': false},
        },
        _ => <String, Object>{'version': 'test'},
      };
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body));
      await request.response.close();
    });
  }

  @override
  Future<void> stop() async {
    final old = server;
    if (old != null) stops++;
    server = null;
    await old?.close(force: true);
    final HttpServer? probe = speedProbe;
    speedProbe = null;
    await probe?.close(force: true);
  }

  @override
  Future<void> clearSession() => stop();
  @override
  Future<void> persistConfig(String configJson) async {
    if (failWrite) throw KernelException('模拟写入失败');
    config = jsonDecode(configJson) as Map<String, dynamic>;
  }

  @override
  Future<void> commitKernelUpgrade() async {}
  @override
  Future<void> rollbackKernelUpgrade() async {}
  @override
  Future<void> dispose() => stop();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Platform implements PlatformService {
  @override
  bool get supportsLaunchAtLogin => false;
  @override
  String get tunInterfaceName => 'ECYCloud';
  @override
  bool get supportsSystemProxy => false;
  @override
  bool get supportsTray => false;
  @override
  bool get requiresTun => false;
  @override
  Stream<TrayAction> get trayActions => const Stream<TrayAction>.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings extends SettingsStore {
  int? mixedPort;
  @override
  AppSettings load() => const AppSettings.defaults().copyWith(
    autoConnect: false,
    tunEnabled: false,
    systemProxyEnabled: false,
    mixedPort: mixedPort,
  );
}

class _SpeedTester extends NodeSpeedTester {
  int downloads = 0;
  bool failed = false;

  @override
  Future<int> download({
    required int proxyPort,
    required String credential,
    void Function(int speed)? onPeak,
  }) async {
    downloads++;
    if (failed) throw NodeSpeedTestException('模拟下载失败');
    return 65536;
  }
}
