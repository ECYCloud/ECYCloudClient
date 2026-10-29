import 'dart:async';

import 'package:ecycloud_client/data/api/api_exception.dart';
import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:ecycloud_client/data/models/user_profile.dart';
import 'package:ecycloud_client/domain/kernel/kernel_controller.dart';
import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:ecycloud_client/state/connection_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 开机自启时界面比网络早就绪，第一次取资料必然是 DNS 解析失败（connectFailed）
  test('开机自启：连不上面板时自动连接继续等待并重试', () async {
    final _Client client = _Client();
    final _Controller connection = _Controller();
    addTearDown(connection.dispose);
    connection.attachApi(client, accountKey: 'boot@example.test');

    await connection.autoConnect();
    expect(client.profileCalls, 1);
    expect(
      connection.state,
      ConnectionPhase.connecting,
      reason: '网络还没起来，不该判成连接失败',
    );

    await Future<void>.delayed(const Duration(milliseconds: 1400));
    expect(client.profileCalls, 2, reason: '必须自己重试，否则开机后永远连不上');
    expect(connection.state, ConnectionPhase.connecting);
  });

  test('手点连接仍然一次失败就报错，不静默等待', () async {
    final _Client client = _Client();
    final _Controller connection = _Controller();
    addTearDown(connection.dispose);
    connection.attachApi(client, accountKey: 'boot@example.test');

    await connection.connect();
    expect(client.profileCalls, 1);
    expect(connection.state, ConnectionPhase.failed);

    await Future<void>.delayed(const Duration(milliseconds: 1400));
    expect(client.profileCalls, 1, reason: '手动连接不该背着用户重试');
  });

  test('非网络原因的失败不重试', () async {
    final _Client client = _Client()..reachable = true;
    final _Controller connection = _Controller();
    addTearDown(connection.dispose);
    connection.attachApi(client, accountKey: 'boot@example.test');

    await connection.autoConnect();
    expect(client.profileCalls, 1);
    expect(connection.state, ConnectionPhase.failed);

    await Future<void>.delayed(const Duration(milliseconds: 1400));
    expect(client.profileCalls, 1, reason: '限流/鉴权类错误等下去也不会变好');
  });

  testWidgets('启动断网超过全部退避轮次仍等待恢复，间隔保持 30 秒', (tester) async {
    final _Client client = _Client();
    addTearDown(client.close);
    final _Controller connection = _Controller();
    addTearDown(connection.dispose);
    connection.attachApi(client, accountKey: 'boot@example.test');

    await connection.autoConnect();
    for (final int seconds in <int>[1, 2, 4, 8, 16, 30, 30]) {
      await tester.pump(Duration(seconds: seconds));
      expect(connection.state, ConnectionPhase.connecting);
    }
    expect(client.profileCalls, 8);
    await tester.pump(const Duration(seconds: 29));
    expect(client.profileCalls, 8);

    client.reachable = true;
    await tester.pump(const Duration(seconds: 1));
    expect(client.profileCalls, 9);
    expect(connection.state, ConnectionPhase.failed);
    expect(connection.error, '请求过于频繁，请稍后再试');
    await tester.pump(const Duration(seconds: 30));
    expect(client.profileCalls, 9);
  });

  testWidgets('资料可达但配置下载断网时，自动连接继续重试', (tester) async {
    final _Client client = _Client()..profileReady = true;
    addTearDown(client.close);
    final _Controller connection = _Controller();
    addTearDown(connection.dispose);
    connection.attachApi(client, accountKey: 'boot@example.test');
    await tester.pump();
    final int calls = client.configCalls;

    await connection.autoConnect();
    expect(connection.state, ConnectionPhase.connecting);
    expect(client.configCalls, calls + 1);
    await tester.pump(const Duration(seconds: 1));
    expect(client.profileCalls, 2);
    expect(client.configCalls, calls + 2);
    expect(connection.state, ConnectionPhase.connecting);
    await connection.shutdown();
  });

  testWidgets('等待网络期间退出会取消自动连接', (tester) async {
    final _Client client = _Client();
    addTearDown(client.close);
    final _Controller connection = _Controller();
    addTearDown(connection.dispose);
    connection.attachApi(client, accountKey: 'boot@example.test');

    await connection.autoConnect();
    await connection.shutdown();
    await tester.pump(const Duration(seconds: 90));
    expect(client.profileCalls, 1);
    expect(connection.state, ConnectionPhase.disconnected);
  });
}

class _Controller extends ConnectionController {
  _Controller()
    : super(
        platform: _Platform(),
        kernel: _Kernel(),
        settingsStore: _Settings(),
      );

  @override
  Future<void> startStandby() async {}
}

class _Client extends PanelApiClient {
  _Client()
    : super(
        baseUrl: 'https://panel.example.test',
        configBaseUrl: 'https://panel.example.test',
        device: const DeviceInfo(
          platform: 'macos',
          deviceId: 'audit',
          deviceName: 'audit',
          deviceModel: 'audit',
          osVersion: 'test',
          appVersion: 'test',
        ),
      );

  int profileCalls = 0;
  int configCalls = 0;
  bool reachable = false;
  bool profileReady = false;

  @override
  Future<UserProfile> fetchProfile() async {
    profileCalls++;
    if (profileReady) {
      return UserProfile.fromJson(<String, dynamic>{'id': 1});
    }
    if (reachable) {
      throw ApiException('请求过于频繁，请稍后再试', statusCode: 429);
    }
    throw ApiException(
      "无法连接面板，请检查网络或面板地址：Failed host lookup: 'panel.example.test'",
      connectFailed: true,
    );
  }

  @override
  Future<RemoteProfile> fetchClashProfile({int? fallbackProxyPort}) async {
    configCalls++;
    throw ApiException('无法连接面板', connectFailed: true);
  }

  @override
  Future<void> refreshConfigDirectAddresses() async {}

  @override
  Future<void> ensureConfigDirectAddresses() async {}
}

class _Settings extends SettingsStore {
  @override
  AppSettings load() => const AppSettings.defaults();
}

class _Kernel implements KernelController {
  @override
  Future<void> bindSession(String cacheKey) async {}

  @override
  Stream<KernelStatus> get statusStream => const Stream<KernelStatus>.empty();
  @override
  Stream<String> get kernelLog => const Stream<String>.empty();
  @override
  Future<void> dispose() async {}
  @override
  Future<void> stop() async {}
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
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
