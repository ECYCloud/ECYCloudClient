import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ecycloud_client/core/app_paths.dart';
import 'package:ecycloud_client/core/logger.dart';
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
import 'package:ecycloud_client/domain/config/node_catalog.dart';
import 'package:ecycloud_client/domain/config/node_working_set.dart';
import 'package:ecycloud_client/domain/config/profile_assembler.dart';
import 'package:ecycloud_client/domain/kernel/kernel_controller.dart';
import 'package:ecycloud_client/domain/kernel/node_speed_tester.dart';
import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/l10n/app_language.dart';
import 'package:ecycloud_client/l10n/l10n.dart';
import 'package:ecycloud_client/state/connection_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
    AppPaths.useSession(_sessionA);
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
    cache = PanelResponseCache();
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
    await kernel.statuses.close();
    client.close();
    JsonFileStore(AppPaths.selectorCache, 'test').clear();
    JsonFileStore(AppPaths.speedTestQuota, 'test').clear();
    JsonFileStore(AppPaths.trafficRank, 'test').clear();
    HttpOverrides.global = overrides;
    AppPaths.useSession('');
    // 会话已是空时 useSession 不会关日志句柄，Windows 上删不掉打开中的日志
    await Logger.instance.dispose();
    if (AppPaths.sessions.existsSync()) {
      AppPaths.sessions.deleteSync(recursive: true);
    }
  });

  Future<void> endSession() async {
    AppPaths.useSession('');
    await connection.shutdown(clearSession: true);
  }

  void seed({Duration lifetime = const Duration(hours: 2)}) {
    cache.saveProfile(
      'a@example.test',
      UserProfile.fromJson(<String, dynamic>{
        'id': 1,
        'email': 'a@example.test',
      }),
    );
    cache.saveRemote(
      'a@example.test',
      client.profile(lifetime),
      client.cacheKey,
    );
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
        await endSession();
        client.token = null;
        connection.attachApi(null);
      };
      await connection.connect();
      await connection.testSpeed('node-1');
      expect(rejected, isTrue);
      expect(client.token, isNull);
      expect(kernel.status.state, KernelState.stopped);
      expect(cache.loadRemote('a@example.test', client.cacheKey), isNull);
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
      i < 80 &&
          cache.loadRemote('a@example.test', client.cacheKey)?.revision !=
              'candidate';
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(
      cache.loadRemote('a@example.test', client.cacheKey)?.revision,
      'candidate',
    );
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

  // 修复前：重启途中控制面还没接上，第二项改动只落盘不重启，内核一直跑着旧值
  test('内核重启途中再改设置，新设置同样生效', () async {
    seed();
    await connection.connect();
    final Future<void> first = connection.updateSettings(
      connection.settings.copyWith(allowLan: true),
    );
    for (int i = 0; i < 100 && kernel.starts < 2; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(kernel.starts, 2);
    await connection.updateSettings(
      connection.settings.copyWith(ipv6Enabled: true),
    );
    await first;
    expect(connection.state, ConnectionPhase.connected);
    expect(kernel.config['allow-lan'], isTrue);
    expect(kernel.config['ipv6'], isTrue);
  });

  test('首次配置校验失败不能提交离线缓存', () async {
    client.fresh = true;
    kernel.invalid = 'invalid protocol';
    connection.attachApi(client, accountKey: 'a@example.test');
    await connection.connect();
    expect(kernel.starts, 0);
    expect(cache.loadRemote('a@example.test', client.cacheKey), isNull);
  });

  test('仅客户端无法访问面板时从有效缓存启动内核，不等待资料接口', () async {
    seed();
    await connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(connection.state, ConnectionPhase.connected);
    expect(client.profileCalls, 0);
    expect(kernel.starts, 1);
    expect(connection.panelOffline, isTrue);
    expect(
      cache.loadRemote('a@example.test', client.cacheKey)?.revision,
      'verified',
    );
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
      await endSession();
      rejected = true;
    };
    await connection.connect();
    for (int i = 0; i < 50 && !rejected; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(rejected, isTrue);
    expect(kernel.status.running, isFalse);
    expect(cache.loadRemote('a@example.test', client.cacheKey), isNull);
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

  test('排队中的测速在退出重新登录后不再继续', () async {
    kernel.probeSpeeds = true;
    seed();
    connection.attachProfileLookup(
      () => UserProfile.fromJson(<String, dynamic>{'id': 2}),
    );
    await connection.connect();
    speedTester.hold = Completer<void>();
    final Future<String?> first = connection.testSpeed('node-1');
    final Future<String?> queued = connection.testSpeed('node-2');
    while (speedTester.downloads == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await endSession();
    connection.attachApi(null);
    seed();
    await connection.connect();
    speedTester.hold!.complete();
    await first;
    await queued;
    expect(speedTester.downloads, 1);
    expect(client.speedReservations, 1);
    expect(connection.speedOf('node-1'), 0);
    expect(connection.testingSpeedNodes, isEmpty);
  });

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

  // 修复前：内核没停掉也被当成「常驻起不来」，界面显示无错误的未连接，TUN 与内核却还在接管
  test('断开时特权侧挂起、内核停不掉：显示失败原因，不显示成已断开', () async {
    seed();
    await connection.connect();
    expect(connection.state, ConnectionPhase.connected);

    kernel.serviceHung = true;
    await connection.disconnect();
    kernel.serviceHung = false;

    expect(connection.state, ConnectionPhase.failed);
    expect(connection.error, contains('停止内核失败'));
    expect(kernel.server, isNotNull);
  });

  test('停内核失败后重新连接，连接时长从这次连上算起', () async {
    seed();
    await connection.connect();
    final DateTime first = connection.connectedAt!;

    kernel.serviceHung = true;
    await connection.disconnect();
    kernel.serviceHung = false;
    expect(connection.state, ConnectionPhase.failed);
    expect(connection.connectedAt, isNull);

    await Future<void>.delayed(const Duration(milliseconds: 20));
    await connection.connect();
    expect(connection.state, ConnectionPhase.connected);
    expect(connection.connectedAt!.isAfter(first), isTrue);
  });

  // 修复前：kernel.start 先推送的失败状态把「连接中内核退出」标记置上且不复位，界面只剩「内核启动失败，请重试」
  test('连接时内核启动失败，界面显示特权侧给出的原因', () async {
    seed();
    kernel.startError = '用户未授予 VPN 权限';
    await connection.connect();
    kernel.startError = null;

    expect(connection.state, ConnectionPhase.failed);
    expect(connection.error, contains('用户未授予 VPN 权限'));
  });

  test('启动时常驻内核起不来：仍是无错误的未连接', () async {
    seed();
    kernel.serviceHung = true;
    await connection.startStandby();
    kernel.serviceHung = false;

    expect(connection.state, ConnectionPhase.disconnected);
    expect(connection.error, isNull);
  });

  test('普通下线立即保存排行并保留内核待机、缓存和令牌，原会话可以重连', () async {
    kernel.probeTraffic = true;
    final Completer<void> sampled = Completer<void>();
    connection.statsUpdates.addListener(() {
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
    expect(cache.loadRemote('a@example.test', client.cacheKey), isNotNull);
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
      expect(
        cache.loadRemote('a@example.test', client.cacheKey)?.revision,
        'verified',
      );
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

  // 修复前：到点直接停用，面板在到期前一刻已续期也没用
  test('缓存授权到点先向面板取一次配置，面板已续期则保持连接', () async {
    seed(lifetime: const Duration(milliseconds: 700));
    await connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    client.fresh = true;
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(kernel.status.running, isTrue);
    expect(kernel.starts, 1);
    expect(connection.state, ConnectionPhase.connected);
    expect(
      cache.loadRemote('a@example.test', client.cacheKey)?.revision,
      'candidate',
    );
  });

  // 修复前：载入已过期的缓存即停用，正在进行的连接（桌面为启动后自动连接）被作废
  test('缓存授权已过期而面板已续期时，载入缓存不打断随后的连接', () async {
    client.fresh = true;
    client.clashDelay = const Duration(milliseconds: 50);
    seed(lifetime: const Duration(seconds: -1));
    await connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(connection.state, ConnectionPhase.connected);
    expect(connection.error, isNull);
    expect(kernel.status.running, isTrue);
  });

  // 修复前：封禁账户访问配置接口回 401 即退出登录，进不了受限页
  test('非放行接口返回 401 而账户状态接口仍应答时不清除会话', () async {
    seed();
    client.revisionError = ApiException('账号不存在或已被禁用', statusCode: 401);
    int verified = 0;
    bool rejected = false;
    connection.onPanelSync = () async => verified++;
    connection.onSessionRejected = () async => rejected = true;
    await connection.connect();
    for (int i = 0; i < 50 && verified < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(verified, 2);
    expect(rejected, isFalse);
  });

  test('账户状态接口同样返回 401 时才清除会话', () async {
    seed();
    final ApiException revoked = ApiException('登录已失效', statusCode: 401);
    client.revisionError = revoked;
    bool rejected = false;
    connection.onPanelSync = () async => throw revoked;
    connection.onSessionRejected = () async => rejected = true;
    await connection.connect();
    for (int i = 0; i < 50 && !rejected; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(rejected, isTrue);
  });

  // 修复前：选择与模式只改运行态，原生侧按落盘配置重新拉起内核时退回连接时的值
  test('运行中换节点与路由模式写回落盘配置，不重启内核', () async {
    client.nodes = <String>['node-1', 'node-2'];
    seed();
    await connection.connect();
    final int starts = kernel.starts;
    await connection.selectProxy('group', 'node-2');
    expect(
      (kernel.config['proxy-groups'] as List).cast<Map>().firstWhere(
        (Map group) => group['name'] == 'group',
      )['default-selected'],
      'node-2',
    );
    await connection.setRouteMode('global');
    expect(kernel.config['mode'], 'global');
    expect(kernel.starts, starts);
    expect(kernel.status.running, isTrue);
    expect(connection.state, ConnectionPhase.connected);
  });

  // 修复前：TUN 没起来（内核把 tun.enable 抹成 false）界面仍显示已连接
  test('开启 TUN 而内核未能接管时连接失败，不显示已连接', () async {
    seed();
    await connection.updateSettings(
      connection.settings.copyWith(tunEnabled: true),
    );
    await connection.connect();
    expect(connection.state, ConnectionPhase.failed);
    expect(connection.error, contains('TUN'));
  });

  // 修复前：未连接时升级内核，待机内核被停后不再拉起，控制面一直指着已停的内核
  test('未连接时升级内核后重启待机内核', () async {
    seed();
    for (int i = 0; i < 100 && !connection.controlPlaneReady; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(connection.state, ConnectionPhase.disconnected);
    expect(kernel.starts, 1);
    await connection.upgradeKernel('v-test');
    expect(kernel.starts, 2);
    expect(kernel.status.running, isTrue);
    expect(connection.controlPlaneReady, isTrue);
    expect(connection.state, ConnectionPhase.disconnected);
  });

  test('配置戳接口明确拒绝时，不用全量接口的网络故障掩盖撤销', () async {
    seed();
    client.revisionError = ApiException('revoked', statusCode: 401);
    connection.onSessionRejected = endSession;
    await connection.connect();
    for (int i = 0; i < 50 && kernel.status.running; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(kernel.status.running, isFalse);
    expect(cache.loadRemote('a@example.test', client.cacheKey), isNull);
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
    expect(
      cache.loadRemote('a@example.test', client.cacheKey)?.revision,
      'verified',
    );
    expect(connection.groups.single.name, 'group');
  });

  // 只检查不改写：弹窗列出问题，正在用的配置与持久化缓存都不动
  test('候选配置含明文 http 下载地址时拒绝并保留上一份可用缓存', () async {
    seed();
    await connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    client
      ..fresh = true
      ..extra = <String, Object>{
        'geox-url': <String, String>{
          'mmdb': 'http://example.test/geoip.metadb',
        },
      };
    expect(await connection.refreshProfileFromPanel(), isNull);
    expect(connection.formatError, contains('geox-url「mmdb」必须使用 https'));
    expect(kernel.status.running, isTrue);
    expect(kernel.starts, 1);
    expect(
      cache.loadRemote('a@example.test', client.cacheKey)?.revision,
      'verified',
    );
    expect(
      cache
          .loadRemote('a@example.test', client.cacheKey)
          ?.config
          .containsKey('geox-url'),
      isFalse,
    );
  });

  // 修复前桌面直接向内核 PUT /configs 提交整份原文，特权侧落盘前的净化管不到；改为交特权侧净化落盘后按文件重载
  test('全量热载交特权侧 kernel.reload，不向内核提交配置原文，连接与选中节点保持', () async {
    client.extra = <String, Object>{
      'dns': <String, Object>{'enable': true, 'enhanced-mode': 'redir-host'},
    };
    seed();
    await connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final DateTime connectedAt = connection.connectedAt!;
    client
      ..fresh = true
      ..extra = <String, Object>{
        ...client.extra,
        'rules': <String>['DOMAIN,reload.example.test,DIRECT', 'MATCH,group'],
      };
    expect(await connection.refreshProfileFromPanel(), '更新成功');
    expect(kernel.fullReloads, 0);
    expect(kernel.privilegedReloads, hasLength(1));
    expect(
      kernel.privilegedReloads.single['rules'],
      contains('DOMAIN,reload.example.test,DIRECT'),
    );
    expect((kernel.starts, kernel.stops, kernel.closedConnections), (1, 0, 0));
    expect(connection.connectedAt, connectedAt);
    expect(connection.groups.single.now, 'node-1');
  });

  // 节点文件加载前 TUN 劫持的 DNS 等也会读 url-test，内核把空组回落的 REJECT 缓存 10 秒，界面不读分组也躲不开
  test('内核启动与全量热载后先清 url-test 缓存再读分组，且只清 url-test', () async {
    final String reset = 'DELETE /proxies/${Uri.encodeComponent('自动选择')}';
    List<String> order(int from) => kernel.requests
        .sublist(from)
        .where((String r) => r == reset || r == 'GET /proxies')
        .take(2)
        .toList();
    client
      ..nodeProviders = true
      ..extra = <String, Object>{
        'dns': <String, Object>{'enable': true, 'enhanced-mode': 'redir-host'},
        'proxy-groups': <Object>[
          <String, Object>{
            'name': 'group',
            'type': 'select',
            'use': <String>['ecy-panel-nodes'],
          },
          <String, Object>{
            'name': '自动选择',
            'type': 'url-test',
            'use': <String>['ecy-panel-nodes'],
            'url': 'https://cp.cloudflare.com/generate_204',
            'interval': 300,
          },
        ],
      };
    seed();
    await connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(connection.state, ConnectionPhase.connected);
    expect(order(0), <String>[reset, 'GET /proxies']);
    expect(
      kernel.requests.where((String r) => r.startsWith('DELETE /proxies/')),
      <String>[reset],
    );

    final int before = kernel.requests.length;
    client
      ..fresh = true
      ..extra = <String, Object>{
        ...client.extra,
        'rules': <String>['DOMAIN,reload.example.test,DIRECT', 'MATCH,group'],
      };
    expect(await connection.refreshProfileFromPanel(), '更新成功');
    expect(kernel.privilegedReloads, hasLength(1));
    expect(kernel.starts, 1);
    expect(order(before), <String>[reset, 'GET /proxies']);
  });

  // 旧版后台组件不认 kernel.reload：改为经特权侧净化的重启，不能退回原文热载，也不能静默失败
  test('后台组件不支持热载时改为重启内核，不退回原文热载', () async {
    client.extra = <String, Object>{
      'dns': <String, Object>{'enable': true, 'enhanced-mode': 'redir-host'},
    };
    seed();
    await connection.connect();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    kernel.reloadUnsupported = true;
    client
      ..fresh = true
      ..extra = <String, Object>{
        ...client.extra,
        'rules': <String>['DOMAIN,reload.example.test,DIRECT', 'MATCH,group'],
      };
    expect(await connection.refreshProfileFromPanel(), '更新成功');
    expect(kernel.fullReloads, 0);
    expect(kernel.privilegedReloads, isEmpty);
    expect(kernel.starts, 2);
    expect(
      kernel.config['rules'],
      contains('DOMAIN,reload.example.test,DIRECT'),
    );
    expect(connection.state, ConnectionPhase.connected);
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

  test('节点副本超过内核装载上限时只装在用的节点，选中与测延迟按需装入，不重启内核', () async {
    final int total = NodeWorkingSet.copyBudget + 500;
    client
      ..nodeProviders = true
      ..nodes = <String>[for (int id = 1; id <= total; id++) 'node-$id'];
    seed();
    await connection.connect();
    expect(
      connection.state,
      ConnectionPhase.connected,
      reason: connection.error,
    );
    List<String> inKernel(String provider) => <String>[
      for (final Object? node
          in ((kernel.config['proxy-providers'] as Map)[provider]
                  as Map)['payload']
              as List)
        (node as Map)['name'] as String,
    ];
    expect(inKernel('ecy-panel-nodes'), hasLength(NodeWorkingSet.copyBudget));
    expect(connection.groups.single.members, hasLength(total));

    final String far = 'node-${total - 10}';
    expect(inKernel('ecy-panel-nodes'), isNot(contains(far)));
    await connection.selectProxy('group', far);
    expect(inKernel('ecy-panel-nodes'), contains(far));
    expect(inKernel('ecy-panel-nodes'), hasLength(NodeWorkingSet.copyBudget));
    expect(connection.groups.single.now, far);
    expect(connection.groups.single.members, hasLength(total));

    final String other = 'node-${total - 20}';
    final int updates = kernel.providerUpdates;
    await connection.testDelay(other);
    expect(inKernel(NodeWorkingSet.probeProvider), <String>[other]);
    expect(inKernel('ecy-panel-nodes'), isNot(contains(other)));
    expect(kernel.providerUpdates, updates + 1);
    expect(kernel.starts, 1);
    expect(kernel.stops, 0);
    expect(kernel.fullReloads, 0);

    // 选中的节点记进了选择记录，重装配置后仍在内核里
    client
      ..fresh = true
      ..nodePort = 8443;
    expect(await connection.refreshProfileFromPanel(), '更新成功');
    expect(inKernel('ecy-panel-nodes'), contains(far));
    expect(kernel.starts, 1);
    // 接受新配置时的候选校验同样只带在用的节点，整份目录不交给内核
    expect(kernel.validatedNodes, NodeWorkingSet.copyBudget);
  });

  test('内核拒收装入的节点时撤回，之后的装配不再带它', () async {
    final int total = NodeWorkingSet.copyBudget + 500;
    client
      ..nodeProviders = true
      ..nodes = <String>[for (int id = 1; id <= total; id++) 'node-$id'];
    seed();
    await connection.connect();
    List<String> inKernel() => <String>[
      for (final Object? node
          in ((kernel.config['proxy-providers'] as Map)['ecy-panel-nodes']
                  as Map)['payload']
              as List)
        (node as Map)['name'] as String,
    ];

    final String far = 'node-${total - 10}';
    kernel.failUpdate = true;
    await expectLater(connection.selectProxy('group', far), throwsA(anything));
    expect(inKernel(), isNot(contains(far)));
    expect(connection.groups.single.now, isNot(far));

    client
      ..fresh = true
      ..nodePort = 8443;
    expect(await connection.refreshProfileFromPanel(), '更新成功');
    expect(inKernel(), isNot(contains(far)));
    expect(kernel.starts, 1);
  });

  group('节点目录分页', () {
    List<String> inKernel([String provider = 'ecy-panel-nodes']) => <String>[
      for (final Object? node
          in ((kernel.config['proxy-providers'] as Map)[provider]
                  as Map)['payload']
              as List)
        (node as Map)['name'] as String,
    ];
    List<String> cached() => <String>[
      for (final Object? node
          in ((cache
                          .loadRemote('a@example.test', client.cacheKey)!
                          .config['proxy-providers']
                      as Map)['ecy-panel-nodes']
                  as Map)['payload']
              as List)
        (node as Map)['name'] as String,
    ];
    Future<void> connectPaged() async {
      client
        ..nodeProviders = true
        ..fresh = true
        ..pagedHead = 3
        ..nodes = <String>[for (int id = 1; id <= 500; id++) 'node-$id'];
      connection.attachApi(client, accountKey: 'a@example.test');
      await connection.connect();
      expect(
        connection.state,
        ConnectionPhase.connected,
        reason: connection.error,
      );
    }

    test('取配置后按名补齐用户选过的节点，并入的配置落盘，离线重启仍带着它', () async {
      JsonFileStore(AppPaths.selectorCache, 'test').write(<String, dynamic>{
        'account': 'a@example.test',
        'selected': <String, String>{'group': 'node-400'},
      });
      await connectPaged();
      expect(client.nodeRequests, <Map<String, Object?>>[
        <String, Object?>{
          'names': <String>['node-400'],
        },
      ]);
      expect(inKernel(), <String>['node-1', 'node-2', 'node-3', 'node-400']);
      expect(connection.groups.single.now, 'node-400');
      expect(connection.memberTotalOf(connection.groups.single), 500);
      final RemoteProfile saved = cache.loadRemote(
        'a@example.test',
        client.cacheKey,
      )!;
      expect(saved.catalog!.ranks['node-400'], 399);
      expect(saved.nodeLabels['node-400'], 'label-node-400');
      expect(cached(), <String>['node-1', 'node-2', 'node-3', 'node-400']);

      await connection.shutdown();
      client.fresh = false;
      await connection.connect();
      expect(connection.state, ConnectionPhase.connected);
      expect(inKernel(), contains('node-400'));
      expect(connection.groups.single.now, 'node-400');
    });

    test('按名补齐选过的节点时请求失败，这次取配置按失败处理，沿用上一份缓存', () async {
      JsonFileStore(AppPaths.selectorCache, 'test').write(<String, dynamic>{
        'account': 'a@example.test',
        'selected': <String, String>{'group': 'node-400'},
      });
      await connectPaged();
      final List<String> before = cached();
      expect(before, contains('node-400'));

      client
        ..revision += 1
        ..nodePort = 8443
        ..nodesError = ApiException('模拟面板不可达', connectFailed: true);
      expect(await connection.refreshProfileFromPanel(), startsWith('更新失败'));
      final RemoteProfile kept = cache.loadRemote(
        'a@example.test',
        client.cacheKey,
      )!;
      expect(kept.revision, 'candidate-0');
      expect(cached(), before);
      expect(inKernel(), before);
      expect(connection.groups.single.now, 'node-400');
      expect(kernel.starts, 1);

      client.nodesError = null;
      expect(await connection.refreshProfileFromPanel(), '更新成功');
      expect(
        cache.loadRemote('a@example.test', client.cacheKey)!.revision,
        'candidate-1',
      );
      expect(inKernel(), before);
      expect(connection.groups.single.now, 'node-400');
    });

    test('面板成功应答但不含某个选过的节点（已删除或已无权限）时照常接受配置', () async {
      JsonFileStore(AppPaths.selectorCache, 'test').write(<String, dynamic>{
        'account': 'a@example.test',
        'selected': <String, String>{'group': 'node-9999'},
      });
      await connectPaged();
      expect(client.nodeRequests.single['names'], <String>['node-9999']);
      expect(inKernel(), <String>['node-1', 'node-2', 'node-3']);
      expect(cached(), <String>['node-1', 'node-2', 'node-3']);
      expect(connection.groups.single.now, 'node-1');
    });

    test('翻页取到的节点只供界面列出，选中时才并入、落盘并装入内核，不重启', () async {
      await connectPaged();
      expect(client.nodeRequests, isEmpty);
      expect(connection.groups.single.members, hasLength(3));
      expect(connection.memberTotalOf(connection.groups.single), 500);
      expect(connection.hasMoreNodes('group'), isTrue);

      await connection.loadMoreNodes('group');
      await connection.loadMoreNodes('group');
      expect(client.nodeRequests, <Map<String, Object?>>[
        <String, Object?>{'provider': 'ecy-panel-nodes', 'offset': 3},
        <String, Object?>{'provider': 'ecy-panel-nodes', 'offset': 103},
      ]);
      expect(connection.groups.single.members, hasLength(203));
      expect(connection.memberTotalOf(connection.groups.single), 500);
      expect(connection.typeOf('node-150'), 'Shadowsocks');
      expect(inKernel(), hasLength(3));
      expect(cached(), hasLength(3));

      await connection.selectProxy('group', 'node-150');
      expect(inKernel(), <String>['node-1', 'node-2', 'node-3', 'node-150']);
      expect(connection.groups.single.now, 'node-150');
      expect(cached(), <String>['node-1', 'node-2', 'node-3', 'node-150']);
      expect(connection.groups.single.members, hasLength(203));
      expect(kernel.starts, 1);
      expect(kernel.stops, 0);
      expect(kernel.fullReloads, 0);

      // 翻到最后一页后不再请求
      for (int page = 0; page < 6; page++) {
        await connection.loadMoreNodes('group');
      }
      expect(connection.hasMoreNodes('group'), isFalse);
      expect(connection.groups.single.members, hasLength(500));
      expect(client.nodeRequests, hasLength(5));
    });

    test('搜索向面板查，命中的节点进列表，换关键字重新查', () async {
      await connectPaged();
      expect(connection.hasMoreNodes('group', query: 'node-49'), isFalse);
      await connection.loadMoreNodes('group', query: 'node-49');
      expect(client.nodeRequests.single, <String, Object?>{
        'provider': 'ecy-panel-nodes',
        'offset': 0,
        'search': 'node-49',
      });
      expect(connection.groups.single.members, hasLength(3 + 11));
      expect(connection.nodeMatched('group', 'node-490', 'node-49'), isTrue);
      expect(connection.nodeMatched('group', 'node-1', 'node-49'), isFalse);
      expect(connection.hasMoreNodes('group', query: 'node-49'), isFalse);

      await connection.loadMoreNodes('group', query: 'node-2');
      expect(client.nodeRequests.last['search'], 'node-2');
      expect(connection.hasMoreNodes('group', query: 'node-2'), isTrue);
      expect(connection.nodeMatched('group', 'node-490', 'node-49'), isFalse);
      await connection.loadMoreNodes('group', query: 'node-2');
      expect(client.nodeRequests.last['offset'], 100);
      expect(connection.hasMoreNodes('group', query: 'node-2'), isFalse);
      expect(inKernel(), hasLength(3));
    });

    test('给只在浏览缓存里的节点测延迟：先并入面板配置，再经探测节点文件测', () async {
      await connectPaged();
      await connection.loadMoreNodes('group');
      final int updates = kernel.providerUpdates;
      await connection.testDelay('node-50');
      expect(inKernel(NodeWorkingSet.probeProvider), <String>['node-50']);
      expect(cached(), contains('node-50'));
      expect(kernel.providerUpdates, updates + 1);
      expect(kernel.starts, 1);
    });

    test('面板的节点已变（目录换版）时丢弃这一页、清空浏览缓存并刷新配置', () async {
      await connectPaged();
      await connection.loadMoreNodes('group');
      expect(connection.groups.single.members, hasLength(103));
      final int calls = client.clashCalls;
      client.catalogStamp = 's2';
      await connection.loadMoreNodes('group');
      expect(connection.groups.single.members, hasLength(3));
      for (int i = 0; i < 80 && client.clashCalls == calls; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(client.clashCalls, calls + 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await connection.loadMoreNodes('group');
      expect(connection.groups.single.members, hasLength(103));
      expect(client.nodeRequests.last['offset'], 3);
    });

    test('面板不可达时翻页给出失败原因，已知节点照常可用，恢复后可重试', () async {
      await connectPaged();
      client.nodesError = ApiException('模拟面板不可达', connectFailed: true);
      await connection.loadMoreNodes('group');
      expect(connection.nodesErrorOf('group'), '模拟面板不可达');
      expect(connection.loadingNodes('group'), isFalse);
      expect(connection.groups.single.members, hasLength(3));
      await connection.selectProxy('group', 'node-2');
      expect(connection.groups.single.now, 'node-2');
      expect(connection.state, ConnectionPhase.connected);

      client.nodesError = null;
      await connection.loadMoreNodes('group');
      expect(connection.nodesErrorOf('group'), isNull);
      expect(connection.groups.single.members, hasLength(103));
    });

    test('内核拒收从浏览缓存选中的节点时，面板配置与缓存都恢复原样', () async {
      await connectPaged();
      await connection.loadMoreNodes('group');
      kernel.failUpdate = true;
      await expectLater(
        connection.selectProxy('group', 'node-50'),
        throwsA(anything),
      );
      expect(inKernel(), <String>['node-1', 'node-2', 'node-3']);
      expect(cached(), <String>['node-1', 'node-2', 'node-3']);
    });
  });

  test('内核用缓存的配置启动失败后，再点连接会向面板核对并换用新配置', () async {
    seed();
    kernel.invalid = 'invalid protocol';
    await connection.connect();
    expect(connection.state, ConnectionPhase.failed);
    expect(kernel.starts, 0);

    client.fresh = true;
    kernel.invalid = null;
    await connection.connect();
    expect(connection.state, ConnectionPhase.connected);
    expect(client.clashCalls, 1);
    expect(
      cache.loadRemote('a@example.test', client.cacheKey)?.revision,
      'candidate',
    );
  });

  test('面板配置有变更需重启内核时，同一份配置只校验一次', () async {
    client
      ..nodeProviders = true
      ..fresh = true
      ..extra = <String, Object>{
        'dns': <String, Object>{'enable': true, 'enhanced-mode': 'fake-ip'},
      };
    connection.attachApi(client, accountKey: 'a@example.test');
    await connection.connect();
    expect(connection.state, ConnectionPhase.connected);
    expect(kernel.validations, 1);

    client
      ..revision += 1
      ..extra = <String, Object>{
        'dns': <String, Object>{'enable': true, 'enhanced-mode': 'fake-ip'},
        'rules': <String>['DOMAIN,example.test,DIRECT', 'MATCH,group'],
      };
    expect(await connection.refreshProfileFromPanel(), '更新成功');
    expect(kernel.starts, 2);
    expect(kernel.validations, 2);
    expect(connection.state, ConnectionPhase.connected);

    // 设置变了，装配条件与校验过的那份不同：仍要校验
    await connection.updateSettings(
      connection.settings.copyWith(ipv6Enabled: true),
    );
    expect(kernel.starts, 3);
    expect(kernel.validations, 3);
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

  for (final (Duration? interval, Duration age, bool due)
      in <(Duration?, Duration, bool)>[
        (null, const Duration(hours: 23), false),
        (null, const Duration(hours: 25), true),
        (const Duration(hours: 1), const Duration(minutes: 30), false),
        (const Duration(hours: 1), const Duration(hours: 2), true),
      ]) {
    test('配置戳未变时按更新间隔 ${interval?.inHours ?? '默认'} 小时、距上次 ${age.inMinutes} 分钟'
        '${due ? '' : '不'}重拉全量，内容相同不重启不断开', () async {
      client.nodeProviders = true;
      seed();
      await connection.connect();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      client
        ..fresh = true
        ..updateInterval = interval
        ..fetchedAgo = age;
      await connection.refreshProfileFromPanel();
      final int calls = client.clashCalls;
      expect(await connection.refreshProfileFromPanel(), '已是最新，分流规则已刷新');
      expect(client.clashCalls, calls + (due ? 1 : 0));
      expect(kernel.starts, 1);
      expect(kernel.stops, 0);
      expect(kernel.fullReloads, 0);
      expect(kernel.privilegedReloads, isEmpty);
      expect(kernel.closedConnections, 0);
      expect(connection.state, ConnectionPhase.connected);
      expect(
        cache.loadRemote('a@example.test', client.cacheKey)?.updateInterval,
        interval,
      );
    });
  }

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
      expect(
        cache.loadRemote('a@example.test', client.cacheKey)?.revision,
        'verified',
      );
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
    AppPaths.useSession(_sessionB);
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
    expect(
      cache.loadRemote('a@example.test', next.cacheKey)?.cacheBinding,
      next.cacheBinding,
    );
    expect(cache.loadRemote('a@example.test', client.cacheKey), isNull);
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

      await endSession();
      expect(kernel.status.running, isFalse);
      expect(connection.groups, isEmpty);
      expect(cache.loadProfile('a@example.test'), isNull);
      expect(cache.loadRemote('a@example.test', client.cacheKey), isNull);
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

      AppPaths.useSession(_sessionB);
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
      expect(
        cache.loadRemote(account, next.cacheKey)?.cacheBinding,
        next.cacheBinding,
      );
    });
  }
}

final String _sessionA = 'a' * 64;
final String _sessionB = 'b' * 64;

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
  Map<String, Object> extra = <String, Object>{};
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
  // 非空即分页模式：配置只带前 pagedHead 个节点，其余经 fetchNodes 取
  int? pagedHead;
  String catalogStamp = 's1';
  ApiException? nodesError;
  final List<Map<String, Object?>> nodeRequests = <Map<String, Object?>>[];
  Duration fetchedAgo = const Duration(seconds: 1);
  Duration clashDelay = Duration.zero;
  Duration? updateInterval;
  RemoteProfile profile(Duration lifetime) => RemoteProfile(
    config: <String, dynamic>{
      'proxies': nodeProviders ? <Object>[] : nodeConfigs,
      if (nodeProviders)
        'proxy-providers': <String, Object>{
          'ecy-panel-nodes': <String, Object>{
            'type': 'file',
            'path': 'ecy-panel-nodes.json',
            'payload': nodeConfigs.take(pagedHead ?? nodes.length).toList(),
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
      ...extra,
    },
    revision: fresh
        ? (nodeProviders ? 'candidate-$revision' : 'candidate')
        : 'verified',
    groupIcons: const <String, String>{},
    nodeLabels: const <String, String>{},
    flagRegex: '',
    offlineIssuedAt: DateTime.now().subtract(fetchedAgo),
    offlineUntil: DateTime.now().add(lifetime),
    cacheBinding: cacheBinding,
    updateInterval: updateInterval,
    catalog: pagedHead == null
        ? null
        : NodeCatalog(
            stamp: catalogStamp,
            providers: <String, CatalogProvider>{
              'ecy-panel-nodes': (
                key: 'ecy-panel-nodes',
                total: nodes.length,
                head: pagedHead!,
              ),
            },
            ranks: <String, int>{
              for (int i = 0; i < pagedHead!; i++) nodes[i]: i,
            },
          ),
  );
  @override
  Future<NodePage> fetchNodes({
    String? provider,
    int offset = 0,
    int limit = 100,
    String search = '',
    List<String>? names,
    int? fallbackProxyPort,
  }) async {
    nodeRequests.add(<String, Object?>{
      'provider': ?provider,
      'offset': ?(names == null ? offset : null),
      'search': ?(search.isEmpty ? null : search),
      'names': ?names,
    });
    if (nodesError != null) throw nodesError!;
    final List<int> ranks = <int>[
      for (int i = 0; i < nodes.length; i++)
        if (names?.contains(nodes[i]) ?? 'label-${nodes[i]}'.contains(search))
          i,
    ].skip(offset).toList();
    final List<Object> configs = nodeConfigs;
    return (
      stamp: catalogStamp,
      more: names == null && ranks.length > limit,
      nodes: <CatalogNode>[
        for (final int rank in names == null ? ranks.take(limit) : ranks)
          CatalogNode(
            name: nodes[rank],
            rank: rank,
            label: 'label-${nodes[rank]}',
            providers: const <String>['ecy-panel-nodes'],
            proxy: (configs[rank] as Map).cast<String, dynamic>(),
          ),
      ],
    );
  }

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
    await Future<void>.delayed(clashDelay);
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
  // 控制面直接收到的 PUT /configs（原文热载）与交给特权侧的 kernel.reload 分开计
  int fullReloads = 0;
  final List<Map<String, dynamic>> privilegedReloads = <Map<String, dynamic>>[];
  final List<String> requests = <String>[];
  bool reloadUnsupported = false;
  int closedConnections = 0;
  int providerUpdates = 0;
  bool failWrite = false;
  bool failUpdate = false;
  // 特权侧挂起不应答：经它的指令全部失败，内核本身仍在跑
  bool serviceHung = false;
  // 与 ServiceKernelController 一致：kernel.start 出错时先推送失败状态，再抛出带原因的异常
  String? startError;
  final StreamController<KernelStatus> statuses =
      StreamController<KernelStatus>.broadcast();
  Map<String, dynamic> config = <String, dynamic>{};
  String binding = '';
  String? invalid;
  @override
  KernelStatus get status => server == null
      ? const KernelStatus.stopped()
      : const KernelStatus(state: KernelState.running);
  @override
  Stream<KernelStatus> get statusStream => statuses.stream;
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

  int validatedNodes = 0;
  int validations = 0;
  @override
  Future<String?> validate(String configJson) async {
    if (serviceHung) throw KernelException('后台服务暂不可用：模拟挂起');
    validations++;
    final Object? providers =
        (jsonDecode(configJson) as Map)['proxy-providers'];
    final Object? panel = providers is Map
        ? providers['ecy-panel-nodes']
        : null;
    final int nodes = panel is Map ? (panel['payload'] as List).length : 0;
    if (nodes > validatedNodes) {
      validatedNodes = nodes;
    }
    return invalid;
  }

  @override
  Future<void> start({
    required String configJson,
    required ClashApiOptions clashApi,
  }) async {
    await stop();
    starts++;
    final String? error = startError;
    if (error != null) {
      statuses.add(KernelStatus(state: KernelState.failed, message: error));
      throw KernelException('内核启动失败：$error');
    }
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
      requests.add('${request.method} ${request.uri.path}');
      if (request.method == 'DELETE' &&
          request.uri.pathSegments.first == 'proxies') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
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
        final String path when path.startsWith('/providers/proxies/') =>
          <String, Object>{
            'proxies': <Object>[
              <String, String>{'name': 'loaded'},
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
    if (serviceHung) throw KernelException('停止内核失败：模拟挂起');
    final old = server;
    if (old != null) stops++;
    server = null;
    await old?.close(force: true);
    final HttpServer? probe = speedProbe;
    speedProbe = null;
    await probe?.close(force: true);
  }

  @override
  Future<void> clearSession(String cacheKey) => stop();
  @override
  Future<void> persistConfig(String configJson) async {
    if (failWrite || serviceHung) throw KernelException('模拟写入失败');
    config = jsonDecode(configJson) as Map<String, dynamic>;
  }

  @override
  Future<void> reloadConfig(String configJson) async {
    if (reloadUnsupported) {
      throw KernelException('热载配置失败：未知指令 "kernel.reload"', unsupported: true);
    }
    config = jsonDecode(configJson) as Map<String, dynamic>;
    privilegedReloads.add(config);
  }

  // 与特权侧一致：替换文件前先停内核
  @override
  Future<String> upgrade(String version, {int? proxyPort}) async {
    await stop();
    return version;
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
  bool get tunSetsSystemDns => false;
  @override
  bool get strictRouteNeedsTunIPv6 => false;
  @override
  bool get lanNamesViaSystemDns => false;
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
  Completer<void>? hold;

  @override
  Future<int> download({
    required int proxyPort,
    required String credential,
    void Function(int speed)? onPeak,
  }) async {
    downloads++;
    await hold?.future;
    if (failed) throw NodeSpeedTestException('模拟下载失败');
    return 65536;
  }
}
