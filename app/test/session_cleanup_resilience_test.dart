import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ecycloud_client/core/app_paths.dart';
import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:ecycloud_client/data/store/panel_response_cache.dart';
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:ecycloud_client/domain/config/local_template.dart';
import 'package:ecycloud_client/domain/kernel/kernel_controller.dart';
import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/platform/linux/linux_platform_service.dart';
import 'package:ecycloud_client/platform/unix/unix_platform_service.dart';
import 'package:ecycloud_client/state/connection_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('退出时停内核失败也不报错，状态落到已断开', () async {
    final ConnectionController connection = ConnectionController(
      platform: _Platform(),
      kernel: _Kernel()..clearError = KernelException('测试清理失败'),
      settingsStore: _Settings(),
      panelCache: PanelResponseCache(),
    );
    addTearDown(connection.dispose);
    await connection.shutdown(clearSession: true);
    expect(connection.state, ConnectionPhase.disconnected);
  });

  test('旧会话退出被新账号接替后不再清空新会话状态', () async {
    final Completer<void> clearing = Completer<void>();
    final ConnectionController connection = ConnectionController(
      platform: _Platform(),
      kernel: _Kernel()..clearWait = clearing,
      settingsStore: _Settings(),
      panelCache: PanelResponseCache(),
    );
    addTearDown(connection.dispose);
    final Future<void> retry = connection.shutdown(clearSession: true);
    final _Client client = _Client();
    addTearDown(client.close);
    connection.attachApi(client, accountKey: 'next@example.test');
    await connection.preloadProxies();
    final int groups = connection.groups.length;
    clearing.complete();
    await retry;
    expect(connection.groups, hasLength(groups));
    expect(groups, greaterThan(0));
  });

  test('停内核失败也照样还原系统代理，并如实落到失败', () async {
    final _Platform platform = _Platform(systemProxy: true);
    final ConnectionController connection = ConnectionController(
      platform: platform,
      kernel: _Kernel()..stopError = KernelException('后台服务无响应'),
      settingsStore: _Settings(),
      panelCache: PanelResponseCache(),
    );
    addTearDown(connection.dispose);
    await expectLater(connection.shutdown(), throwsA(isA<KernelException>()));
    expect(platform.restores, 1);
    expect(connection.state, ConnectionPhase.failed);
  });

  test('系统代理还原抛出非平台异常时断开仍能完成', () async {
    final ConnectionController connection = ConnectionController(
      platform: _Platform(
        systemProxy: true,
        restoreError: const FormatException('快照损坏'),
      ),
      kernel: _Kernel(),
      settingsStore: _Settings(),
      panelCache: PanelResponseCache(),
    );
    addTearDown(connection.dispose);
    await connection.shutdown();
    expect(connection.state, ConnectionPhase.disconnected);
  });

  test('断开连接不先去面板拉配置', () async {
    final HttpOverrides? overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    server.listen((HttpRequest request) async {
      final Object body = switch (request.uri.path) {
        '/proxies' => <String, Object>{
          'proxies': <String, Object>{
            'node': <String, Object>{'type': 'Shadowsocks'},
          },
        },
        '/configs' => <String, Object>{
          'mode': 'rule',
          'tun': <String, bool>{'enable': true},
        },
        '/connections' => <String, Object>{'connections': <Object>[]},
        _ => <String, Object>{'version': 'test'},
      };
      if (request.method == 'PATCH') {
        request.response.statusCode = HttpStatus.noContent;
      } else {
        request.response.writeln(jsonEncode(body));
      }
      await request.response.close();
    });
    final ConnectionController connection = ConnectionController(
      platform: _Platform(),
      kernel: _Kernel()
        ..live = ClashApiOptions(port: server.port, secret: 'test'),
      settingsStore: _Settings(),
      panelCache: PanelResponseCache(),
    );
    addTearDown(connection.dispose);
    final _Client client = _Client();
    addTearDown(client.close);
    connection.attachApi(client, accountKey: 'fixture@example.test');
    await connection.preloadProxies();
    connection.notePanelRevision('revision-2');
    await connection.adoptRunningKernel();
    expect(connection.state, ConnectionPhase.connected);
    expect(client.calls, 1);
    await connection.disconnect();
    expect(connection.state, ConnectionPhase.disconnected);
    expect(client.calls, 1);
    expect(client.revisionChecks, 0);
  });

  group('Linux 系统代理快照', () {
    late _Gsettings gsettings;
    late LinuxPlatformService service;
    setUp(() {
      gsettings = _Gsettings();
      service = LinuxPlatformService(run: gsettings.run);
    });
    tearDown(() {
      if (AppPaths.proxySnapshot.existsSync()) {
        AppPaths.proxySnapshot.deleteSync();
      }
    });

    for (final bool ours in <bool>[true, false]) {
      test('快照损坏时删除并只关掉指向本客户端的代理：$ours', () async {
        AppPaths.proxySnapshot.writeAsStringSync('{broken');
        gsettings.values['org.gnome.system.proxy.http port'] = ours
            ? '10203'
            : '8080';
        await service.restoreSystemProxy();
        expect(AppPaths.proxySnapshot.existsSync(), isFalse);
        expect(
          gsettings.writes,
          ours ? <String>["org.gnome.system.proxy mode 'none'"] : isEmpty,
        );
      });
    }

    test('残留还原很慢、连接先设好代理时，最终仍是新连接的代理', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            UnixPlatformService.channel,
            (MethodCall call) async => null,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(UnixPlatformService.channel, null),
      );
      AppPaths.proxySnapshot.writeAsStringSync(
        jsonEncode(<String, String>{
          'org.gnome.system.proxy mode': "'none'",
          'org.gnome.system.proxy.http port': '8080',
        }),
      );
      final Completer<void> slow = Completer<void>();
      gsettings.gate = slow;
      await service.initialize();
      final Future<void> connecting = service.setSystemProxy(
        port: 10203,
        bypass: const <String>[],
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      slow.complete();
      await connecting;
      await service.leftoverProxyRestore;
      expect(gsettings.values['org.gnome.system.proxy mode'], "'manual'");
      expect(gsettings.values['org.gnome.system.proxy.http port'], '10203');
    });

    test('写快照经临时文件改名，不留半截文件', () async {
      await service.setSystemProxy(port: 10203, bypass: const <String>[]);
      expect(
        jsonDecode(AppPaths.proxySnapshot.readAsStringSync()),
        isA<Map<String, dynamic>>(),
      );
      expect(File('${AppPaths.proxySnapshot.path}.tmp').existsSync(), isFalse);
      gsettings.writes.clear();
      await service.restoreSystemProxy();
      expect(AppPaths.proxySnapshot.existsSync(), isFalse);
      expect(gsettings.writes, contains("org.gnome.system.proxy mode 'none'"));
    });
  });
}

class _Gsettings {
  final Map<String, String> values = <String, String>{
    'org.gnome.system.proxy mode': "'none'",
    'org.gnome.system.proxy.http host': "'127.0.0.1'",
  };
  final List<String> writes = <String>[];

  Completer<void>? gate;

  Future<ProcessResult> run(String executable, List<String> args) async {
    final Completer<void>? pending = gate;
    if (pending != null) {
      gate = null;
      await pending.future;
    }
    final String key = '${args[1]} ${args[2]}';
    if (args[0] == 'set') {
      writes.add('$key ${args[3]}');
      values[key] = args[3];
      return ProcessResult(0, 0, '', '');
    }
    return ProcessResult(0, 0, values[key] ?? "''", '');
  }
}

class _Client extends PanelApiClient {
  _Client()
    : super(
        baseUrl: 'https://panel.example.test',
        configBaseUrl: 'https://panel.example.test',
        device: const DeviceInfo(
          platform: 'windows',
          deviceId: 'fixture',
          deviceName: 'fixture',
          deviceModel: 'fixture',
          osVersion: 'test',
          appVersion: 'test',
        ),
      );

  int calls = 0;
  int revisionChecks = 0;

  @override
  Future<RemoteProfile> fetchClashProfile({int? fallbackProxyPort}) async {
    calls++;
    return const RemoteProfile(
      config: <String, dynamic>{
        'proxies': <Object>[
          <String, Object>{
            'name': 'node',
            'type': 'ss',
            'server': 'node.example.test',
            'port': 443,
            'cipher': 'aes-128-gcm',
            'password': 'test',
          },
        ],
        'proxy-groups': <Object>[
          <String, Object>{
            'name': 'group',
            'type': 'select',
            'proxies': <String>['node'],
          },
        ],
        'rules': <String>['MATCH,group'],
      },
      revision: 'revision-1',
      groupIcons: <String, String>{},
      flagRegex: '',
      nodeLabels: <String, String>{},
    );
  }

  @override
  Future<String> fetchConfigRevision({int? fallbackProxyPort}) async {
    revisionChecks++;
    return 'revision-2';
  }

  @override
  Future<void> ensureConfigDirectAddresses() async {}

  @override
  Future<void> refreshConfigDirectAddresses() async {}
}

class _Settings extends SettingsStore {
  @override
  AppSettings load() => const AppSettings.defaults();

  @override
  void save(AppSettings settings) {}
}

class _Kernel implements KernelController {
  Object? clearError;
  Completer<void>? clearWait;
  ClashApiOptions? live;

  @override
  Future<ClashApiOptions?> attach() async => live;
  @override
  Future<String?> validate(String configJson) async => null;
  @override
  Future<void> bindSession(String cacheKey) async {}
  @override
  Future<void> persistConfig(String configJson) async {}
  Object? stopError;
  @override
  Future<void> stop() async {
    if (stopError != null) throw stopError!;
  }
  @override
  Future<void> clearSession(String cacheKey) async {
    await clearWait?.future;
    if (clearError != null) throw clearError!;
  }

  @override
  DateTime? get startedAt => null;
  @override
  Stream<KernelStatus> get statusStream => const Stream<KernelStatus>.empty();
  @override
  Stream<String> get kernelLog => const Stream<String>.empty();
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Platform implements PlatformService {
  _Platform({this.systemProxy = false, this.restoreError});

  final bool systemProxy;
  final Object? restoreError;

  @override
  bool get supportsLaunchAtLogin => false;
  @override
  String get tunInterfaceName => 'ECYCloud';
  @override
  String get platformId => 'windows';
  @override
  bool get supportsSystemProxy => systemProxy;
  @override
  bool get supportsTray => false;
  @override
  bool get requiresTun => false;
  @override
  Stream<TrayAction> get trayActions => const Stream<TrayAction>.empty();
  int restores = 0;
  @override
  Future<void> restoreSystemProxy() async {
    restores++;
    if (restoreError != null) throw restoreError!;
  }

  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
