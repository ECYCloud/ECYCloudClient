import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:ecycloud_client/core/app_paths.dart';
import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:ecycloud_client/data/models/announcement.dart';
import 'package:ecycloud_client/data/store/panel_response_cache.dart';
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:ecycloud_client/data/store/traffic_rank_store.dart';
import 'package:ecycloud_client/domain/kernel/kernel_controller.dart';
import 'package:ecycloud_client/domain/config/local_template.dart';
import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/state/connection_controller.dart';
import 'package:ecycloud_client/state/announcement_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    final String base = Directory('build/test-data').absolute.path
        .replaceAll('\\', '/');
    expect(AppPaths.userData.path.replaceAll('\\', '/'), startsWith(base));
  });

  test('无账户归属的流量历史不能出现在登录前或新账户中', () async {
    AppPaths.trafficRank.writeAsStringSync(
      jsonEncode(<String, Object>{
        TrafficRankStore.dayKey(DateTime.now()): <String, Object>{
          'hosts': <String, int>{'private-old.test': 123},
        },
      }),
    );
    final _Controller connection = _Controller(_Cache());
    addTearDown(connection.dispose);
    expect(connection.trafficRankHosts(TrafficRankDay.today), isEmpty);
    connection.attachApi(null);
    expect(connection.trafficRankHosts(TrafficRankDay.today), isEmpty);
  });

  test('启动恢复的空接口和退出登录不能删除已有排行', () async {
    AppPaths.trafficRank.writeAsStringSync(
      jsonEncode(<String, Object>{
        'account': 'saved@test',
        'days': <String, Object>{
          TrafficRankStore.dayKey(DateTime.now()): <String, Object>{
            'hosts': <String, int>{'saved.test': 123},
          },
        },
      }),
    );
    final ConnectionController connection = ConnectionController(
      platform: _Platform(),
      kernel: _Kernel(),
      settingsStore: _Settings(),
      panelCache: _Cache(),
    );
    addTearDown(connection.dispose);
    connection.attachApi(null, accountKey: 'saved@test');
    expect(connection.trafficRankHosts(TrafficRankDay.today), isEmpty);
    expect(AppPaths.trafficRank.readAsStringSync(), contains('saved.test'));
    final _Client client = _Client('saved');
    addTearDown(client.close);
    connection.attachApi(client, accountKey: 'saved@test');
    expect(connection.trafficRankHosts(TrafficRankDay.today).single.bytes, 123);
    await connection.shutdown(clearSession: true);
    expect(connection.trafficRankHosts(TrafficRankDay.today), isEmpty);
    expect(AppPaths.trafficRank.readAsStringSync(), contains('saved.test'));
    connection.attachApi(client, accountKey: 'saved@test');
    expect(connection.trafficRankHosts(TrafficRankDay.today).single.bytes, 123);
  });

  test('新连接首次流量计入排行，后台和断开保存，重新接管不重复计数', () async {
    final HttpOverrides? overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    int samples = 0;
    server.listen((HttpRequest request) async {
      final Object body = switch (request.uri.path) {
        '/proxies' => <String, Object>{
          'proxies': <String, Object>{
            'batch': <String, Object>{'type': 'Shadowsocks'},
            'DIRECT': <String, Object>{'type': 'Direct'},
            'batch-group': <String, Object>{
              'type': 'Selector',
              'all': <String>['batch'],
            },
          },
        },
        '/configs' => <String, Object>{
          'mode': 'rule',
          'tun': <String, bool>{'enable': true},
        },
        '/connections' => <String, Object>{
          'connections': <Object>[
            <String, Object>{
              'id': 'batch-connection',
              'upload': 0,
              'download': ++samples * 100,
              'chains': <String>['batch', 'batch-group'],
              'metadata': <String, String>{'host': 'rank.test'},
            },
            if (samples > 1)
              <String, Object>{
                'id': 'new-connection',
                'upload': 0,
                'download': 500 + (samples - 2) * 25,
                'chains': <String>['batch', 'batch-group'],
                'metadata': <String, String>{'host': 'new.test'},
              },
            <String, Object>{
              'id': 'direct-connection',
              'upload': samples * 10000,
              'download': samples * 20000,
              'chains': <String>['DIRECT'],
              'metadata': <String, String>{'host': 'direct.test'},
            },
          ],
        },
        _ => <String, Object>{'version': 'test'},
      };
      request.response.writeln(jsonEncode(body));
      await request.response.close();
    });
    final _AttachKernel kernel = _AttachKernel();
    kernel.reply.complete(ClashApiOptions(port: server.port, secret: 'test'));
    final ConnectionController connection = ConnectionController(
      platform: _Platform(),
      kernel: kernel,
      settingsStore: _Settings(),
      panelCache: _Cache(),
    );
    addTearDown(connection.dispose);
    final Completer<void> firstSample = Completer<void>();
    void firstListener() {
      if (!firstSample.isCompleted && connection.connections.isNotEmpty) {
        firstSample.complete();
      }
    }

    connection.addListener(firstListener);
    final Completer<void> sampled = Completer<void>();
    connection.addListener(() {
      final List<TrafficRankRow> hosts = connection.trafficRankHosts(
        TrafficRankDay.today,
      );
      if (!sampled.isCompleted &&
          hosts.isNotEmpty &&
          hosts.any(
            (TrafficRankRow row) => row.name == 'new.test' && row.bytes >= 525,
          )) {
        sampled.complete();
      }
    });
    await connection.adoptRunningKernel();
    await firstSample.future.timeout(const Duration(seconds: 4));
    connection.removeListener(firstListener);
    final _Client client = _Client('batch');
    client.reply.complete(client.profile);
    addTearDown(client.close);
    connection.attachApi(client, accountKey: 'batch@test');
    await connection.preloadProxies();
    await sampled.future.timeout(const Duration(seconds: 5));
    TrafficRankStore reopened = TrafficRankStore()..bindAccount('batch@test');
    final int live = connection
        .trafficRankGroups(TrafficRankDay.today)
        .single
        .bytes;
    expect(live, 725);
    expect(connection.trafficTotal.down, 825);
    expect(reopened.topGroups(TrafficRankDay.today).single.bytes, 600);
    expect(connection.trafficRankHosts(TrafficRankDay.today), hasLength(2));
    connection.didChangeAppLifecycleState(AppLifecycleState.hidden);
    reopened = TrafficRankStore()..bindAccount('batch@test');
    expect(reopened.topGroups(TrafficRankDay.today).single.bytes, live);

    final Completer<void> backgroundSample = Completer<void>();
    void backgroundListener() {
      if (!backgroundSample.isCompleted &&
          connection.trafficRankGroups(TrafficRankDay.today).single.bytes >
              live) {
        backgroundSample.complete();
      }
    }

    connection.addListener(backgroundListener);
    await backgroundSample.future.timeout(const Duration(seconds: 4));
    connection.removeListener(backgroundListener);
    final int latest = connection
        .trafficRankGroups(TrafficRankDay.today)
        .single
        .bytes;
    final int total = connection.trafficTotal.down;
    final int historyLength = connection.trafficHistory.length;
    connection.attachApi(null);
    final Completer<void> unknownSample = Completer<void>();
    void unknownListener() {
      if (!unknownSample.isCompleted &&
          connection.trafficHistory.length > historyLength) {
        unknownSample.complete();
      }
    }

    connection.addListener(unknownListener);
    connection.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await unknownSample.future.timeout(const Duration(seconds: 4));
    connection.removeListener(unknownListener);
    expect(connection.trafficTotal.down, total);
    expect(connection.traffic.down, 0);
    connection.attachApi(client, accountKey: 'batch@test');
    await connection.preloadProxies();
    await connection.shutdown();
    reopened = TrafficRankStore()..bindAccount('batch@test');
    expect(reopened.topGroups(TrafficRankDay.today).single.bytes, latest);

    final Completer<void> baseline = Completer<void>();
    void baselineListener() {
      if (!baseline.isCompleted && connection.connections.isNotEmpty) {
        baseline.complete();
      }
    }

    connection.addListener(baselineListener);
    await connection.adoptRunningKernel();
    await baseline.future.timeout(const Duration(seconds: 4));
    connection.removeListener(baselineListener);
    expect(
      connection.trafficRankGroups(TrafficRankDay.today).single.bytes,
      latest,
    );
  });

  test('切出客户端后上传下载速率和曲线仍持续采样', () async {
    final HttpOverrides? overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    int samples = 0;
    server.listen((HttpRequest request) async {
      final Object body = switch (request.uri.path) {
        '/proxies' => <String, Object>{
          'proxies': <String, Object>{
            'proxy': <String, Object>{'type': 'Shadowsocks'},
            'DIRECT': <String, Object>{'type': 'Direct'},
          },
        },
        '/configs' => <String, Object>{
          'mode': 'rule',
          'tun': <String, bool>{'enable': true},
        },
        '/connections' => <String, Object>{
          'connections': <Object>[
            <String, Object>{
              'id': 'proxy-connection',
              'upload': ++samples * 100,
              'download': samples * 200,
              'chains': <String>['proxy'],
            },
            <String, Object>{
              'id': 'direct-connection',
              'upload': samples * 10000,
              'download': samples * 20000,
              'chains': <String>['DIRECT'],
            },
          ],
        },
        _ => <String, Object>{'version': 'test'},
      };
      request.response.writeln(jsonEncode(body));
      await request.response.close();
    });
    final _AttachKernel kernel = _AttachKernel();
    kernel.reply.complete(ClashApiOptions(port: server.port, secret: 'test'));
    final ConnectionController connection = ConnectionController(
      platform: _Platform(),
      kernel: kernel,
      settingsStore: _Settings(),
      panelCache: _Cache(),
    );
    addTearDown(connection.dispose);

    Future<void> waitForSamples(int count) async {
      final int target = connection.trafficHistory.length + count;
      final Completer<void> sampled = Completer<void>();
      void listener() {
        if (!sampled.isCompleted &&
            connection.trafficHistory.length >= target) {
          sampled.complete();
        }
      }

      connection.addListener(listener);
      try {
        await sampled.future.timeout(const Duration(seconds: 4));
      } finally {
        connection.removeListener(listener);
      }
    }

    await connection.adoptRunningKernel();
    await waitForSamples(2);
    for (final AppLifecycleState state in <AppLifecycleState>[
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.resumed,
    ]) {
      final DateTime? previous = connection.traffic.at;
      connection.didChangeAppLifecycleState(state);
      await waitForSamples(3);
      expect(connection.traffic.at!.isAfter(previous!), isTrue);
      expect(connection.traffic.up, greaterThan(0));
      expect(connection.traffic.down, greaterThan(0));
      expect(connection.trafficTotal.up, samples * 100);
      expect(connection.trafficTotal.down, samples * 200);
    }
  });

  test('规则文件列表不能绕过面板缓存的账户检查', () {
    AppPaths.remoteConfigCache.writeAsStringSync(
      jsonEncode(<String, Object>{
        'account': 'old@test',
        'kernel': 'mihomo',
        'config': <String, Object>{
          'rule-providers': <String, Object>{
            'private-old': <String, Object>{
              'type': 'http',
              'path': 'rules/old.txt',
            },
          },
        },
      }),
    );
    final _Controller connection = _Controller(_Cache());
    addTearDown(connection.dispose);
    expect(connection.ruleProviderRefs(), isEmpty);
  });

  test('退出期间延迟返回的内核接管结果不能重新接管旧会话', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    server.listen((HttpRequest request) async {
      final Object body = switch (request.uri.path) {
        '/proxies' => <String, Object>{
          'proxies': <String, Object>{
            'old-private-group': <String, Object>{
              'type': 'Selector',
              'all': <String>['old-node'],
            },
          },
        },
        '/configs' => <String, Object>{
          'mode': 'rule',
          'tun': <String, bool>{'enable': false},
        },
        _ => <String, Object>{'version': 'test'},
      };
      request.response.write(jsonEncode(body));
      await request.response.close();
    });
    final _AttachKernel kernel = _AttachKernel();
    final ConnectionController connection = ConnectionController(
      platform: _Platform(),
      kernel: kernel,
      settingsStore: _Settings(),
      panelCache: _Cache(),
    );
    addTearDown(connection.dispose);
    final Future<void> pending = connection.adoptRunningKernel();
    await connection.shutdown();
    kernel.reply.complete(
      ClashApiOptions(port: server.port, secret: 'old-secret'),
    );
    await pending;
    expect(connection.controlPlaneReady, isFalse);
    expect(connection.groups, isEmpty);
    expect(connection.state, ConnectionPhase.disconnected);
  });

  test('内核升级的迟到完成不能重新启动已退出的会话', () async {
    final HttpOverrides? overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    server.listen((HttpRequest request) async {
      request.response.write(
        jsonEncode(switch (request.uri.path) {
          '/configs' => <String, Object>{
            'mode': 'rule',
            'tun': <String, bool>{'enable': true},
          },
          '/proxies' => <String, Object>{'proxies': <String, Object>{}},
          _ => <String, Object>{'version': 'test'},
        }),
      );
      await request.response.close();
    });
    final _AttachKernel kernel = _AttachKernel();
    kernel.reply.complete(ClashApiOptions(port: server.port, secret: 'test'));
    final ConnectionController connection = ConnectionController(
      platform: _Platform(),
      kernel: kernel,
      settingsStore: _Settings(),
      panelCache: _Cache(),
    );
    addTearDown(connection.dispose);
    await connection.adoptRunningKernel();
    expect(connection.state, ConnectionPhase.connected);
    final Future<String> upgrade = connection.upgradeKernel('v-test');
    await connection.shutdown();
    final int stops = kernel.stops;
    kernel.upgraded.complete('v-test');
    await upgrade;
    expect(kernel.stops, stops);
    expect(connection.state, ConnectionPhase.disconnected);

    await connection.adoptRunningKernel();
    final _Client client = _Client('first');
    client.reply.complete(client.profile);
    connection.attachApi(client, accountKey: 'first@test');
    await connection.preloadProxies();
    client.directWait = Completer<void>();
    final Future<void> settings = connection.updateSettings(
      connection.settings.copyWith(
        mixedPort: connection.settings.mixedPort + 2,
      ),
    );
    await client.directStarted.future;
    connection.attachApi(null);
    await connection.shutdown();
    client.directWait!.complete();
    await settings;
    await expectLater(
      connection.readRuntimeConfig(),
      throwsA(isA<KernelException>()),
    );
  });

  for (final bool logout in <bool>[false, true]) {
    test('转发未就绪不阻塞连接，测速${logout ? '退出时取消' : '就绪后才申请额度'}', () async {
      final HttpOverrides? overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = overrides);
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      final Completer<void> attempted = Completer<void>();
      bool forwarding = false;
      server.listen((HttpRequest request) async {
        if (request.uri.path == '/version' &&
            request.headers.value(HttpHeaders.authorizationHeader) == null) {
          request.response.statusCode = forwarding
              ? HttpStatus.unauthorized
              : HttpStatus.badGateway;
          await request.response.close();
          if (!attempted.isCompleted) attempted.complete();
          return;
        }
        request.response.write(
          jsonEncode(switch (request.uri.path) {
            '/configs' => <String, Object>{
              'mode': 'rule',
              'tun': <String, bool>{'enable': true},
            },
            '/proxies' => <String, Object>{'proxies': <String, Object>{}},
            _ => <String, Object>{'version': 'test'},
          }),
        );
        await request.response.close();
      });
      final _AttachKernel kernel = _AttachKernel();
      kernel.reply.complete(ClashApiOptions(port: server.port, secret: 'test'));
      final ConnectionController connection = ConnectionController(
        platform: _Platform(),
        kernel: kernel,
        settingsStore: _Settings(mixedPort: server.port - 1),
        panelCache: _Cache(),
      );
      addTearDown(connection.dispose);
      final Future<void> connecting = connection.adoptRunningKernel();
      await Future.any(<Future<void>>[connecting, attempted.future]);
      expect(connection.state, ConnectionPhase.connected);
      expect(attempted.isCompleted, isFalse);

      final _Client client = _Client('node-12');
      client.reply.complete(client.profile);
      connection.attachApi(client, accountKey: 'speed@test');
      await connection.preloadProxies();
      final Future<String?> speed = connection.testSpeed('node-12');
      await Future.any<Object?>(<Future<Object?>>[attempted.future, speed]);
      expect(attempted.isCompleted, isTrue);
      expect(connection.testingSpeedNodes, contains('node-12'));
      expect(connection.speedFailedNodes, isEmpty);
      expect(client.speedReservations, 0);

      if (logout) {
        connection.attachApi(null);
        await connection.shutdown();
      }
      forwarding = true;
      expect(await speed, logout ? isNull : 'test: quota denied');
      expect(client.speedReservations, logout ? 0 : 1);
      expect(connection.testingSpeedNodes, isEmpty);
      expect(connection.speedFailedNodes, isEmpty);
    });
  }

  test('旧会话公告不能覆盖新会话或退出后的页面', () async {
    final _Client first = _Client('first');
    final _Client second = _Client('second');
    final AnnouncementController controller = AnnouncementController();
    addTearDown(controller.dispose);
    controller.attachApi(first);
    final Future<void> old = controller.refresh();
    controller.attachApi(null);
    controller.attachApi(second);
    final Future<void> current = controller.refresh();
    second.announcements.complete(
      const AnnouncementBundle(
        items: <Announcement>[
          Announcement(
            id: 2,
            title: 'new',
            date: '',
            updatedAt: '',
            content: 'new',
          ),
        ],
      ),
    );
    await current;
    first.announcements.complete(
      const AnnouncementBundle(
        items: <Announcement>[
          Announcement(
            id: 1,
            title: 'old',
            date: '',
            updatedAt: '',
            content: 'old',
          ),
        ],
      ),
    );
    await old;
    expect(controller.items.single.title, 'new');
    controller.attachApi(null);
    expect(controller.items, isEmpty);
  });

  test('新账户独立拉配置，旧账户延迟配置不能写入新账户缓存', () async {
    final _Client first = _Client('first');
    final _Client second = _Client('second');
    final _Cache cache = _Cache();
    final _Controller connection = _Controller(cache);
    addTearDown(connection.dispose);
    connection.attachApi(first, accountKey: 'first@example.test');
    await Future<void>.delayed(Duration.zero);
    connection.attachApi(null);
    connection.attachApi(second, accountKey: 'second@example.test');
    await Future<void>.delayed(Duration.zero);
    final int secondCalls = second.calls;

    second.reply.complete(second.profile);
    await Future<void>.delayed(Duration.zero);
    first.reply.complete(first.profile);
    await connection.preloadProxies();

    expect(secondCalls, 1);
    expect(cache.saved, isEmpty, reason: '内核尚未载入，候选配置不能替换可用缓存');
    expect(connection.groups.single.name, 'second-group');
  });

  test('退出后到达的配置不恢复节点列表或缓存', () async {
    final _Client client = _Client('first');
    final _Cache cache = _Cache();
    final _Controller connection = _Controller(cache);
    addTearDown(connection.dispose);
    connection.attachApi(client, accountKey: 'first@example.test');
    await Future<void>.delayed(Duration.zero);
    connection.attachApi(null);
    client.reply.complete(client.profile);
    await Future<void>.delayed(Duration.zero);
    expect(connection.groups, isEmpty);
    expect(cache.saved, isEmpty);
  });
}

class _Controller extends ConnectionController {
  _Controller(_Cache cache)
    : super(
        platform: _Platform(),
        kernel: _Kernel(),
        settingsStore: _Settings(),
        panelCache: cache,
      );
  @override
  Future<void> startStandby() async {}
  @override
  Future<void> shutdown({bool clearSession = false}) async {}
}

class _Client extends PanelApiClient {
  _Client(this.label)
    : super(
        baseUrl: 'https://panel.example.test',
        configBaseUrl: 'https://panel.example.test',
        device: const DeviceInfo(
          platform: 'windows',
          deviceId: 'audit',
          deviceName: 'audit',
          deviceModel: 'audit',
          osVersion: 'test',
          appVersion: 'test',
        ),
      );
  final String label;
  int calls = 0;
  int speedReservations = 0;

  @override
  Future<SpeedTestReserveResult> reserveSpeedTest(List<String> names) async {
    speedReservations++;
    return const SpeedTestReserveResult(
      allowed: <String>[],
      denied: <SpeedTestDenied>[
        SpeedTestDenied(proxyName: 'node-12', message: 'test: quota denied'),
      ],
    );
  }

  final Completer<RemoteProfile> reply = Completer<RemoteProfile>();
  final Completer<AnnouncementBundle> announcements =
      Completer<AnnouncementBundle>();
  Completer<void>? directWait;
  final Completer<void> directStarted = Completer<void>();
  @override
  Future<void> ensureConfigDirectAddresses() async {
    if (directWait != null) {
      directStarted.complete();
      await directWait!.future;
    }
  }

  @override
  Future<AnnouncementBundle> fetchAnnouncements() => announcements.future;
  RemoteProfile get profile => RemoteProfile(
    config: <String, dynamic>{
      'proxies': <Object>[
        <String, Object>{
          'name': label,
          'type': 'ss',
          'server': 'node.example.test',
          'port': 443,
          'cipher': 'aes-128-gcm',
          'password': 'test',
        },
      ],
      'proxy-groups': <Object>[
        <String, Object>{
          'name': '$label-group',
          'type': 'select',
          'proxies': <String>[label],
        },
      ],
      'rules': <String>['MATCH,$label-group'],
    },
    revision: label,
    groupIcons: const <String, String>{},
    flagRegex: '',
    nodeLabels: const <String, String>{},
  );
  @override
  Future<RemoteProfile> fetchClashProfile({int? fallbackProxyPort}) {
    calls++;
    return reply.future;
  }

  @override
  Future<void> refreshConfigDirectAddresses() async {}
}

class _Cache extends PanelResponseCache {
  final Map<String, RemoteProfile> saved = <String, RemoteProfile>{};
  @override
  RemoteProfile? loadRemote(String accountKey) => saved[accountKey];
  @override
  void saveRemote(String accountKey, RemoteProfile remote) {
    saved[accountKey] = remote;
  }
}

class _Settings extends SettingsStore {
  _Settings({this.mixedPort = 10203});

  final int mixedPort;

  @override
  AppSettings load() =>
      const AppSettings.defaults().copyWith(mixedPort: mixedPort);
}

class _Kernel implements KernelController {
  @override
  Future<String?> validate(String configJson) async => null;
  @override
  Future<void> bindSession(String cacheKey) async {}

  @override
  Stream<KernelStatus> get statusStream => const Stream<KernelStatus>.empty();
  @override
  Stream<String> get kernelLog => const Stream<String>.empty();
  @override
  Future<void> dispose() async {}
  @override
  Future<void> clearSession() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AttachKernel extends _Kernel {
  final Completer<ClashApiOptions?> reply = Completer<ClashApiOptions?>();
  final Completer<String> upgraded = Completer<String>();
  int stops = 0;
  @override
  Future<ClashApiOptions?> attach() => reply.future;
  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<String> upgrade(String version, {int? proxyPort}) => upgraded.future;
  @override
  Future<String?> validate(String configJson) async => null;
  @override
  Future<String> readRunFile(String relativePath) async =>
      throw KernelException('test: no running kernel');
  @override
  DateTime? get startedAt => null;
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
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
