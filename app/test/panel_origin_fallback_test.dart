import 'dart:io';

import 'package:ecycloud_client/data/api/api_exception.dart';
import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:ecycloud_client/data/models/account.dart';
import 'package:ecycloud_client/data/models/user_profile.dart';
import 'package:ecycloud_client/data/store/credential_store.dart';
import 'package:ecycloud_client/data/store/panel_response_cache.dart';
import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/state/auth_controller.dart';
import 'package:flutter_test/flutter_test.dart';

const DeviceInfo _device = DeviceInfo(
  platform: 'windows',
  deviceId: 'fixture',
  deviceName: 'fixture',
  deviceModel: 'Windows 11',
  osVersion: '26H2',
  appVersion: '0.1.1',
);

const String _moved = 'https://127.0.0.1:1';
const ({String site, String api}) _bundled = (
  site: 'https://bundled.example.test',
  api: 'https://bundled-config.example.test',
);

// 面板地址被改写到不可达主机后，客户端只能在持久化地址与出包地址之间自救，且不能因 HTTP 错误误判
void main() {
  test('面板请求只把网络层失败报告为不可达，HTTP 错误与鉴权失败仍算可达', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    int status = HttpStatus.internalServerError;
    server.listen((HttpRequest request) async {
      request.response.statusCode = status;
      request.response.write('{}');
      await request.response.close();
    });
    final ServerSocket closed = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final String refused = 'http://127.0.0.1:${closed.port}';
    await closed.close();
    final String origin = 'http://127.0.0.1:${server.port}';
    final List<(String, bool)> events = <(String, bool)>[];
    PanelApiClient client(String site, String config) =>
        PanelApiClient(baseUrl: site, configBaseUrl: config, device: _device)
          ..token = 'fixture-token'
          ..onReach = (String origin, bool reachable) =>
              events.add((origin, reachable));

    final PanelApiClient reachable = client(origin, refused);
    addTearDown(reachable.close);
    await expectLater(
      reachable.fetchAnnouncements(),
      throwsA(isA<ApiException>()),
    );
    status = HttpStatus.unauthorized;
    await expectLater(
      reachable.fetchAnnouncements(),
      throwsA(isA<ApiException>()),
    );
    await expectLater(
      reachable.fetchConfigRevision(),
      throwsA(isA<ApiException>()),
    );
    final PanelApiClient unreachable = client(refused, origin);
    addTearDown(unreachable.close);
    await expectLater(
      unreachable.fetchAccountStatus(),
      throwsA(isA<ApiException>()),
    );
    await expectLater(
      unreachable.fetchConfigRevision(),
      throwsA(isA<ApiException>()),
    );
    expect(events, <(String, bool)>[
      (origin, true),
      (origin, true),
      (refused, false),
      (refused, false),
      (origin, true),
    ]);
  });

  test('持久化地址连续 3 次网络层失败且持续满 10 分钟才改用出包地址，出包地址可达后落盘', () async {
    DateTime now = DateTime(2026, 10, 30, 12);
    final (
      AuthController auth,
      _Credentials credentials,
      List<PanelApiClient> clients,
    ) = _auth(
      () => now,
    );
    addTearDown(auth.dispose);
    expect(await auth.fetchAuthOptions(), isNull);
    void report(String origin, bool reachable) =>
        clients.last.onReach!(origin, reachable);

    now = now.add(const Duration(minutes: 9));
    report(_moved, false);
    report(_moved, true);
    report(_moved, false);
    now = now.add(const Duration(minutes: 9));
    report(_moved, false);
    report(_moved, false);
    expect(auth.siteOrigin, _moved);
    now = now.add(const Duration(minutes: 2));
    report(_moved, false);
    expect(auth.siteOrigin, _bundled.site);
    expect(auth.apiOrigin, 'https://moved-config.example.test');
    expect(credentials.site, _moved);
    report(_bundled.site, true);
    expect(credentials.site, _bundled.site);
    expect(credentials.api, 'https://moved-config.example.test');
  });

  // 修复前：回退并落盘出包地址后，面板仍下发原来那个连不上的地址，客户端立即切回去，10 分钟后又回退，循环不止
  test('面板仍下发连不上的旧地址时先探测，失败就留在出包地址且 10 分钟内不再探', () async {
    DateTime now = DateTime(2026, 10, 30, 12);
    final _Script script = _Script(_moved, 'https://moved-config.example.test');
    final (
      AuthController auth,
      _Credentials credentials,
      List<PanelApiClient> clients,
    ) = _auth(
      () => now,
      script,
    );
    addTearDown(auth.dispose);
    expect(await auth.fetchAuthOptions(), isNotNull);
    void report(String origin, bool reachable) => clients
        .lastWhere((PanelApiClient client) => client.onReach != null)
        .onReach!(origin, reachable);
    report(_moved, false);
    now = now.add(const Duration(minutes: 10));
    report(_moved, false);
    report(_moved, false);
    report(_bundled.site, true);
    expect(auth.siteOrigin, _bundled.site);
    expect(credentials.site, _bundled.site);
    expect(script.probes, isEmpty);

    await auth.fetchAuthOptions();
    await auth.originProbes;
    expect(auth.siteOrigin, _bundled.site);
    expect(credentials.site, _bundled.site);
    now = now.add(const Duration(minutes: 9));
    await auth.fetchAuthOptions();
    await auth.originProbes;
    now = now.add(const Duration(minutes: 1));
    await auth.fetchAuthOptions();
    await auth.originProbes;
    expect(auth.siteOrigin, _bundled.site);
    expect(credentials.site, _bundled.site);
    expect(script.probes, <({String origin, bool config, bool anonymous})>[
      (origin: _moved, config: false, anonymous: true),
      (origin: _moved, config: false, anonymous: true),
    ]);
  });

  test('面板下发的新站点与配置地址探测可达就立即采用并落盘', () async {
    final _Script script =
        _Script('https://next.example.test', 'https://next-config.example.test')
          ..reachable.addAll(<String>{
            'https://next.example.test',
            'https://next-config.example.test',
          });
    final (AuthController auth, _Credentials credentials, _) = _auth(
      () => DateTime(2026, 10, 30, 12),
      script,
    );
    addTearDown(auth.dispose);
    expect(await auth.fetchAuthOptions(), isNotNull);
    await auth.originProbes;
    expect(auth.siteOrigin, 'https://next.example.test');
    expect(auth.apiOrigin, 'https://next-config.example.test');
    expect(credentials.site, 'https://next.example.test');
    expect(credentials.api, 'https://next-config.example.test');
    expect(script.probes, <({String origin, bool config, bool anonymous})>[
      (
        origin: 'https://next-config.example.test',
        config: true,
        anonymous: true,
      ),
      (origin: 'https://next.example.test', config: false, anonymous: true),
    ]);
  });

  test('出包地址同样持续不可达时换回持久化地址，不会卡在出包地址上', () async {
    DateTime now = DateTime(2026, 10, 30, 12);
    final (
      AuthController auth,
      _Credentials credentials,
      List<PanelApiClient> clients,
    ) = _auth(
      () => now,
    );
    addTearDown(auth.dispose);
    expect(await auth.fetchAuthOptions(), isNull);
    void report(String origin, bool reachable) =>
        clients.last.onReach!(origin, reachable);
    report(_moved, false);
    now = now.add(const Duration(minutes: 10));
    report(_moved, false);
    expect(auth.siteOrigin, _bundled.site);
    for (int i = 0; i < 3; i++) {
      report(_bundled.site, false);
      now = now.add(const Duration(minutes: 5));
    }
    expect(auth.siteOrigin, _moved);
    expect(credentials.site, _moved);
  });
}

(AuthController, _Credentials, List<PanelApiClient>) _auth(
  DateTime Function() clock, [
  _Script? script,
]) {
  final _Credentials credentials = _Credentials();
  final List<PanelApiClient> clients = <PanelApiClient>[];
  final AuthController auth = AuthController(
    _Platform(),
    credentials,
    clearLocalSession: (_) async {},
    cache: _Cache(),
    createClient: (String site, String api, DeviceInfo device) {
      final PanelApiClient client = script == null
          ? PanelApiClient(baseUrl: site, configBaseUrl: api, device: device)
          : _ScriptedClient(site, api, device, script);
      clients.add(client);
      return client;
    },
    bundledOrigins: _bundled,
    clock: clock,
  );
  return (auth, credentials, clients);
}

// 面板下发的地址与探测结果都由脚本给出，记录每次探测的目标、是否带令牌、是否接了回退上报
class _Script {
  _Script(this.site, this.api);

  String site;
  String api;
  final Set<String> reachable = <String>{};
  final List<({String origin, bool config, bool anonymous})> probes =
      <({String origin, bool config, bool anonymous})>[];
}

class _ScriptedClient extends PanelApiClient {
  _ScriptedClient(String site, String api, DeviceInfo device, this.script)
    : super(baseUrl: site, configBaseUrl: api, device: device);

  final _Script script;

  @override
  Future<AuthOptions> fetchAuthOptions() async => AuthOptions.fromJson(
    <String, dynamic>{'site_origin': script.site, 'api_origin': script.api},
  );

  @override
  Future<bool> probe({required bool config}) async {
    final String origin = config ? configBaseUrl : baseUrl;
    script.probes.add((
      origin: origin,
      config: config,
      anonymous: token == null && onReach == null,
    ));
    return script.reachable.contains(origin);
  }
}

class _Credentials extends CredentialStore {
  String? site = _moved;
  String? api = 'https://moved-config.example.test';

  @override
  Credentials? load() => null;
  @override
  RememberedLogin? loadRemembered() => null;
  @override
  String deviceId() => 'fixture';
  @override
  String? loadSiteOrigin() => site;
  @override
  void saveSiteOrigin(String origin) => site = origin;
  @override
  String? loadApiOrigin() => api;
  @override
  void saveApiOrigin(String origin) => api = origin;
}

class _Cache extends PanelResponseCache {
  @override
  void saveProfile(String accountKey, UserProfile profile) {}
  @override
  UserProfile? loadProfile(String accountKey) => null;
}

class _Platform implements PlatformService {
  @override
  String get platformId => 'windows';
  @override
  Future<String> deviceName() async => 'fixture';
  @override
  Future<({String model, String os})> deviceProfile() async =>
      (model: 'fixture', os: 'test');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
