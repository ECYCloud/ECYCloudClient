import 'dart:convert';
import 'dart:io';

import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('找回密码保留服务端实际重置说明与新会话', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    final String origin = 'http://127.0.0.1:${server.port}';
    final PanelApiClient api = PanelApiClient(
      baseUrl: origin,
      configBaseUrl: origin,
      device: const DeviceInfo(
        platform: 'windows',
        deviceId: 'fixture',
        deviceName: 'fixture',
        deviceModel: 'Windows 11',
        osVersion: '26H2',
        appVersion: '0.1.1',
      ),
    );
    addTearDown(api.close);
    final Future<LoginResult> pending = api.confirmPasswordReset(
      token: 'fixture-reset',
      password: 'test-password',
      repasswd: 'test-password',
    );
    final HttpRequest received = await server.first;
    expect(received.uri.path, '/api/client/v1/auth/password-reset/confirm');
    received.response.headers.contentType = ContentType.json;
    const String message =
        '重置成功，订阅链接与节点密码已重置，旧订阅链接与旧节点密码已失效。其他官方客户端需使用新密码重新登录；第三方客户端需重新导入最新订阅。';
    received.response.write(
      jsonEncode(<String, dynamic>{
        'ret': 1,
        'msg': message,
        'data': <String, dynamic>{
          'token': 'fixture-new-token',
          'expires_at': DateTime.now()
              .add(const Duration(hours: 1))
              .toIso8601String(),
          'user': <String, dynamic>{'id': 1, 'email': 'fixture@example.test'},
        },
      }),
    );
    await received.response.close();
    final LoginResult result = await pending;
    expect(result.message, message);
    expect(result.token, 'fixture-new-token');
    expect(result.profile?.email, 'fixture@example.test');
  });

  test('已登录请求以 ASCII 头同步中文设备名称和型号', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    const DeviceInfo device = DeviceInfo(
      platform: 'android',
      deviceId: 'test-device',
      deviceName: '我的荣耀 V20',
      deviceModel: 'HONOR V20',
      osVersion: 'Android 10',
      appVersion: 'Pre 1.0.3',
    );
    final String origin = 'http://127.0.0.1:${server.port}';
    final PanelApiClient api = PanelApiClient(
      baseUrl: origin,
      configBaseUrl: origin,
      device: device,
    )..token = 'test-token';
    addTearDown(api.close);
    final Future<void> request = api.logout();
    final HttpRequest received = await server.first;
    expect(received.headers.value('Authorization'), 'Bearer test-token');
    for (final MapEntry<String, String> entry in <String, String>{
      'X-Device-Name': device.deviceName,
      'X-Device-Model': device.deviceModel,
      'X-Device-OS': device.osVersion,
      'X-App-Version': device.appVersion,
    }.entries) {
      final String value = received.headers.value(entry.key)!;
      expect(value.codeUnits.every((unit) => unit < 128), isTrue);
      expect(Uri.decodeComponent(value), entry.value);
    }
    received.response.headers.contentType = ContentType.json;
    received.response.write(jsonEncode(<String, dynamic>{'ret': 1}));
    await received.response.close();
    await request;
  });
}
