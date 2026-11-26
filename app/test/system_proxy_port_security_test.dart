import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ecycloud_client/data/store/panel_response_cache.dart';
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:ecycloud_client/domain/config/local_template.dart';
import 'package:ecycloud_client/domain/kernel/clash_api_client.dart';
import 'package:ecycloud_client/domain/kernel/kernel_controller.dart';
import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/platform/service/service_transport.dart';
import 'package:ecycloud_client/state/connection_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 修复前：Windows / macOS 后台服务拒绝时抛的是 ServiceException，没被接住，连接被当成失败
  test('后台服务设置系统代理失败时连接照常', () async {
    final HttpOverrides? overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    const int mixedPort = 10203;
    server.listen((HttpRequest request) async {
      request.response.write(
        jsonEncode(switch (request.uri.path) {
          '/configs' => <String, Object>{
            'mode': 'rule',
            'tun': <String, bool>{'enable': true},
            'mixed-port': mixedPort,
          },
          '/proxies' => <String, Object>{'proxies': <String, Object>{}},
          _ => <String, Object>{'version': 'test'},
        }),
      );
      await request.response.close();
    });
    final _Platform platform = _Platform()
      ..refusal = ServiceException('后台服务拒绝设置系统代理');
    final ConnectionController connection = ConnectionController(
      platform: platform,
      kernel: _Kernel(ClashApiOptions(port: server.port, secret: 'test')),
      settingsStore: _Settings(mixedPort),
      panelCache: PanelResponseCache(),
    );
    addTearDown(connection.dispose);
    await connection.adoptRunningKernel();
    await connection.updateSettings(
      connection.settings.copyWith(systemProxyEnabled: true),
    );
    expect(connection.state, ConnectionPhase.connected);
  });

  for (final bool listening in <bool>[false, true]) {
    test('混合端口${listening ? '由内核监听时照常' : '被其它程序占用时不得'}设置系统代理', () async {
      final HttpOverrides? overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = overrides);
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      const int mixedPort = 10203;
      server.listen((HttpRequest request) async {
        request.response.write(
          jsonEncode(switch (request.uri.path) {
            '/configs' => <String, Object>{
              'mode': 'rule',
              'tun': <String, bool>{'enable': true},
              'mixed-port': listening ? mixedPort : 0,
            },
            '/proxies' => <String, Object>{'proxies': <String, Object>{}},
            _ => <String, Object>{'version': 'test'},
          }),
        );
        await request.response.close();
      });
      final _Platform platform = _Platform();
      final ConnectionController connection = ConnectionController(
        platform: platform,
        kernel: _Kernel(ClashApiOptions(port: server.port, secret: 'test')),
        settingsStore: _Settings(mixedPort),
        panelCache: PanelResponseCache(),
      );
      addTearDown(connection.dispose);
      await connection.adoptRunningKernel();
      expect(connection.state, ConnectionPhase.connected);

      final Future<void> enabling = connection.updateSettings(
        connection.settings.copyWith(systemProxyEnabled: true),
      );
      if (listening) {
        await enabling;
        expect(platform.proxyPorts, <int>[mixedPort]);
      } else {
        await expectLater(enabling, throwsA(isA<ClashApiException>()));
        expect(platform.proxyPorts, isEmpty);
      }
    });
  }
}

class _Settings extends SettingsStore {
  _Settings(this.mixedPort);

  final int mixedPort;

  @override
  AppSettings load() => const AppSettings.defaults().copyWith(
    mixedPort: mixedPort,
    systemProxyEnabled: false,
  );

  @override
  void save(AppSettings settings) {}
}

class _Kernel implements KernelController {
  _Kernel(this.options);

  final ClashApiOptions options;

  @override
  Future<ClashApiOptions?> attach() async => options;
  @override
  Future<void> bindSession(String cacheKey) async {}
  @override
  Stream<KernelStatus> get statusStream => const Stream<KernelStatus>.empty();
  @override
  Stream<String> get kernelLog => const Stream<String>.empty();
  @override
  DateTime? get startedAt => null;
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<void> clearSession(String cacheKey) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Platform implements PlatformService {
  final List<int> proxyPorts = <int>[];
  Object? refusal;

  @override
  String get platformId => 'windows';
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
  bool get supportsSystemProxy => true;
  @override
  bool get supportsTray => false;
  @override
  bool get requiresTun => false;
  @override
  Stream<TrayAction> get trayActions => const Stream<TrayAction>.empty();
  @override
  Future<void> setSystemProxy({
    required int port,
    required List<String> bypass,
  }) async {
    final Object? error = refusal;
    if (error != null) throw error;
    proxyPorts.add(port);
  }

  @override
  Future<void> restoreSystemProxy() async {}
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
