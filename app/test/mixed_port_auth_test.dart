import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:ecycloud_client/domain/config/local_template.dart';
import 'package:ecycloud_client/domain/config/profile_assembler.dart';
import 'package:ecycloud_client/domain/config/speed_probe_config.dart';
import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/state/connection_controller.dart';
import 'package:ecycloud_client/state/update_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const ClashApiOptions _clashApi = ClashApiOptions(
  port: 19090,
  secret: 'secret',
);

Map<String, dynamic> _assemble({
  required bool supportsSystemProxy,
  required bool allowLan,
}) => const ProfileAssembler()
    .assemble(
      remote: <String, dynamic>{
        'authentication': <String>['panel:password'],
        'skip-auth-prefixes': <String>['127.0.0.0/8'],
        'proxies': <Object>[
          <String, dynamic>{
            'name': 'node-1',
            'type': 'trojan',
            'server': 'a.example.com',
            'port': 443,
            'password': 'p',
          },
        ],
        'proxy-groups': <Object>[
          <String, dynamic>{
            'name': '主节点',
            'type': 'select',
            'proxies': <String>['node-1', 'DIRECT'],
          },
        ],
        'rules': <String>['MATCH,主节点'],
      },
      template: LocalTemplate(
        const AppSettings.defaults()
            .copyWith(allowLan: allowLan)
            .toTemplateOptions(
              tunInterfaceName: 'ECYCloud',
              takeover: false,
              supportsSystemProxy: supportsSystemProxy,
            ),
        _clashApi,
      ),
    )
    .config;

class _Proxy {
  _Proxy(this._server, this._respond) {
    _server.listen(_serve);
  }

  static Future<_Proxy> start(String Function(String head) respond) async =>
      _Proxy(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), respond);

  final ServerSocket _server;
  final String Function(String head) _respond;
  final List<String> heads = <String>[];

  int get port => _server.port;

  void _serve(Socket socket) {
    final StringBuffer head = StringBuffer();
    late final StreamSubscription<List<int>> subscription;
    subscription = socket.listen((List<int> chunk) {
      head.write(latin1.decode(chunk));
      final String text = head.toString();
      if (!text.contains('\r\n\r\n')) {
        return;
      }
      subscription.pause();
      heads.add(text);
      socket.add(latin1.encode(_respond(text)));
      unawaited(socket.flush().whenComplete(socket.destroy));
    }, onError: (Object _) => socket.destroy());
  }

  Future<void> close() => _server.close();
}

String _basic(String credential) =>
    'Basic ${base64.encode(utf8.encode(credential))}';

String? _proxyAuthorization(String head) {
  for (final String line in head.split('\r\n')) {
    final int colon = line.indexOf(':');
    if (colon > 0 &&
        line.substring(0, colon).toLowerCase() == 'proxy-authorization') {
      return line.substring(colon + 1).trim();
    }
  }
  return null;
}

class _Connection extends ChangeNotifier implements ConnectionController {
  _Connection(this.settings, this.mixedProxyCredential);

  @override
  final AppSettings settings;

  @override
  final String? mixedProxyCredential;

  @override
  ConnectionPhase get state => ConnectionPhase.connected;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Platform implements PlatformService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final HttpOverrides? previousHttpOverrides = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() => HttpOverrides.global = previousHttpOverrides);

  test('Android 未开局域网共享时混合端口只认 GUI 凭据，面板不能放开回环', () {
    final Map<String, dynamic> config = _assemble(
      supportsSystemProxy: false,
      allowLan: false,
    );
    expect(config['authentication'], <String>[_clashApi.mixedCredential]);
    expect(config['skip-auth-prefixes'], isEmpty);
    expect(config['bind-address'], '127.0.0.1');
    expect(
      _clashApi.mixedCredential,
      isNot(SpeedProbeConfig.credential(_clashApi.secret)),
    );
    final Map<String, dynamic> speed =
        (config['listeners'] as List<dynamic>).single as Map<String, dynamic>;
    expect(speed['users'], <Map<String, String>>[
      <String, String>{
        'username': SpeedProbeConfig.listenerName,
        'password': SpeedProbeConfig.credential(_clashApi.secret)
            .split(':')
            .last,
      },
    ]);
  });

  test('Android 开启局域网共享与桌面端的混合端口配置保持原样', () {
    final Map<String, dynamic> lan = _assemble(
      supportsSystemProxy: false,
      allowLan: true,
    );
    expect(lan['authentication'], isEmpty);
    expect(lan['bind-address'], '*');
    for (final bool allowLan in <bool>[false, true]) {
      final Map<String, dynamic> desktop = _assemble(
        supportsSystemProxy: true,
        allowLan: allowLan,
      );
      expect(desktop['authentication'], isEmpty);
      expect(desktop['skip-auth-prefixes'], <String>['127.0.0.0/8']);
    }
  });

  test('直连面板失败改经混合端口时带上 GUI 凭据', () async {
    const String credential = 'ecy-mixed:0123abcd';
    final _Proxy proxy = await _Proxy.start(
      (String head) => _proxyAuthorization(head) == _basic(credential)
          ? 'HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n'
                'connection: close\r\n\r\n'
                '{"ret":1,"data":{"revision":"r-1"}}'
          : 'HTTP/1.1 407 Proxy Authentication Required\r\n'
                'proxy-authenticate: Basic\r\ncontent-length: 0\r\n'
                'connection: close\r\n\r\n',
    );
    addTearDown(proxy.close);
    final ServerSocket closed = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final String origin = 'http://127.0.0.1:${closed.port}';
    await closed.close();
    final PanelApiClient api = PanelApiClient(
      baseUrl: origin,
      configBaseUrl: origin,
      device: const DeviceInfo(
        platform: 'android',
        deviceId: 'device',
        deviceName: 'phone',
        deviceModel: 'model',
        osVersion: '15',
        appVersion: '0.1.1',
      ),
    )..fallbackProxyPort = proxy.port;
    addTearDown(api.close);

    await expectLater(api.fetchConfigRevision(), throwsA(anything));
    api.fallbackProxyCredential = credential;
    expect(await api.fetchConfigRevision(), 'r-1');
    expect(proxy.heads, hasLength(2));
    expect(_proxyAuthorization(proxy.heads.first), isNull);
    expect(_proxyAuthorization(proxy.heads.last), _basic(credential));
  });

  test('更新检查经混合端口出网时带上 GUI 凭据', () async {
    const String credential = 'ecy-mixed:0123abcd';
    final _Proxy proxy = await _Proxy.start(
      (_) => 'HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\n\r\n',
    );
    addTearDown(proxy.close);
    final UpdateController controller = UpdateController(
      connection: _Connection(
        const AppSettings.defaults().copyWith(mixedPort: proxy.port),
        credential,
      ),
      platform: _Platform(),
    );
    expect(await controller.githubReachable(), isFalse);
    expect(proxy.heads, isNotEmpty);
    expect(proxy.heads.first, startsWith('CONNECT api.github.com:443'));
    expect(_proxyAuthorization(proxy.heads.first), _basic(credential));
  });
}
