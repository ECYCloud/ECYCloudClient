import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:ecycloud_client/data/api/api_exception.dart';
import 'package:ecycloud_client/data/models/user_profile.dart';
import 'package:ecycloud_client/data/store/json_file_store.dart';
import 'package:ecycloud_client/data/store/panel_response_cache.dart';

final Uint8List _sealKey = Uint8List.fromList(List<int>.filled(32, 7));

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ecycloud-cache-test-');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('离线授权绑定令牌、设备和两个面板来源，并严格检查期限', () {
    final PanelApiClient client = PanelApiClient(
      baseUrl: 'https://panel.example.test',
      configBaseUrl: 'https://sub.example.test',
      device: const DeviceInfo(
        platform: 'windows',
        deviceId: 'device-1',
        deviceName: '',
        deviceModel: '',
        osVersion: '',
        appVersion: '',
      ),
    )..token = 'token-1';
    addTearDown(client.close);
    final DateTime issued = DateTime(2026, 10, 3, 8);
    final RemoteProfile remote = RemoteProfile(
      config: const <String, dynamic>{},
      revision: 'r1',
      groupIcons: const <String, String>{},
      nodeLabels: const <String, String>{},
      groupLabels: const <String, String>{'主节点': 'Main nodes'},
      flagRegex: '',
      offlineIssuedAt: issued,
      offlineUntil: issued.add(const Duration(hours: 1)),
      cacheBinding: client.cacheBinding,
    );
    final PanelResponseCache cache = PanelResponseCache(
      profileStore: JsonFileStore(File('${tempDir.path}/profile.json'), 't'),
      remoteStore: JsonFileStore(File('${tempDir.path}/remote.json'), 't'),
    );
    cache.saveRemote('a@example.test', remote, client.cacheKey);
    final RemoteProfile restored = cache.loadRemote(
      'a@example.test',
      client.cacheKey,
    )!;
    expect(restored.groupLabels, <String, String>{'主节点': 'Main nodes'});
    expect(restored.usableOffline(client, now: issued), isTrue);
    expect(
      restored.usableOffline(
        client,
        now: issued.subtract(const Duration(seconds: 1)),
      ),
      isFalse,
    );
    expect(
      restored.usableOffline(client, now: issued.add(const Duration(hours: 1))),
      isFalse,
    );
    client.token = 'token-2';
    expect(restored.usableOffline(client, now: issued), isFalse);
    final PanelApiClient other = PanelApiClient(
      baseUrl: 'https://other.example.test',
      configBaseUrl: 'https://sub.example.test',
      device: client.device,
    )..token = 'token-1';
    addTearDown(other.close);
    expect(restored.usableOffline(other, now: issued), isFalse);
  });

  test('损坏的离线授权缓存应被忽略，不中断启动', () {
    final JsonFileStore remoteStore = JsonFileStore(
      File('${tempDir.path}/remote.json'),
      't',
    );
    final PanelResponseCache cache = PanelResponseCache(
      profileStore: JsonFileStore(File('${tempDir.path}/profile.json'), 't'),
      remoteStore: remoteStore,
    );
    for (final MapEntry<String, Object> invalid in <MapEntry<String, Object>>[
      const MapEntry<String, Object>('offline_issued_at', 9223372036854775807),
      const MapEntry<String, Object>('offline_until', 9223372036854775807),
      const MapEntry<String, Object>('cache_binding', <String>[]),
    ]) {
      remoteStore.write(<String, dynamic>{
        'account': 'a@example.test',
        'kernel': 'mihomo',
        'config': <String, dynamic>{},
        invalid.key: invalid.value,
      });
      expect(
        cache.loadRemote('a@example.test', _sealKey),
        isNull,
        reason: invalid.key,
      );
    }
  });

  test('业务拒绝不能被当作临时网络故障', () {
    expect(ApiException('timeout', transportFailure: true).transient, isTrue);
    expect(ApiException('DNS', connectFailed: true).transient, isTrue);
    for (final int code in <int>[401, 403, 404, 422]) {
      expect(ApiException('rejected', statusCode: code).transient, isFalse);
    }
    expect(ApiException('invalid config').transient, isFalse);
    expect(ApiException('temporary', statusCode: 503).transient, isTrue);
  });

  test('账号资料缓存按邮箱隔离并可回读', () {
    final PanelResponseCache cache = PanelResponseCache(
      profileStore: JsonFileStore(File('${tempDir.path}/profile.json'), 't'),
      remoteStore: JsonFileStore(File('${tempDir.path}/remote.json'), 't'),
    );
    final UserProfile profile = UserProfile.fromJson(<String, dynamic>{
      'id': 7,
      'email': 'a@example.com',
      'user_name': 'A',
      'class': 1,
      'upload': 1,
      'download': 2,
      'transfer_enable': 100,
      'config_revision': 'r1',
    });

    cache.saveProfile('A@example.com', profile);
    expect(cache.loadProfile('a@example.com')?.id, 7);
    expect(cache.loadProfile('other@example.com'), isNull);
  });

  test('面板配置缓存可回读且账号不匹配时拒绝', () {
    final PanelResponseCache cache = PanelResponseCache(
      profileStore: JsonFileStore(File('${tempDir.path}/profile.json'), 't'),
      remoteStore: JsonFileStore(File('${tempDir.path}/remote.json'), 't'),
    );
    cache.saveRemote(
      'user@example.com',
      const RemoteProfile(
        config: <String, dynamic>{
          'proxies': <Map<String, dynamic>>[
            <String, dynamic>{'name': 'node-1', 'type': 'ss'},
          ],
        },
        revision: 'rev-9',
        groupIcons: <String, String>{'proxy': 'https://x/i.png'},
        nodeLabels: <String, String>{'node-1': '香港'},
        flagRegex: r'^(.*)$',
      ),
      _sealKey,
    );

    final RemoteProfile? loaded = cache.loadRemote(
      'user@example.com',
      _sealKey,
    );
    expect(loaded?.revision, 'rev-9');
    expect(loaded?.nodeLabels['node-1'], '香港');
    expect(loaded?.updateInterval, isNull);
    expect(cache.loadRemote('other@example.com', _sealKey), isNull);
  });

  test('面板配置缓存只以令牌派生的密钥加密落盘，拷到别处或换了登录都解不开', () {
    final File file = File('${tempDir.path}/remote.json');
    final PanelResponseCache cache = PanelResponseCache(
      profileStore: JsonFileStore(File('${tempDir.path}/profile.json'), 't'),
      remoteStore: JsonFileStore(file, 't'),
    );
    PanelApiClient client(String token, String deviceId) => PanelApiClient(
      baseUrl: 'https://panel.example.test',
      configBaseUrl: 'https://sub.example.test',
      device: DeviceInfo(
        platform: 'windows',
        deviceId: deviceId,
        deviceName: '',
        deviceModel: '',
        osVersion: '',
        appVersion: '',
      ),
    )..token = token;
    final PanelApiClient owner = client('token-1', 'device-1');
    final PanelApiClient relogin = client('token-2', 'device-1');
    final PanelApiClient otherDevice = client('token-1', 'device-2');
    final PanelApiClient signedOut = client('', 'device-1');
    for (final PanelApiClient api in <PanelApiClient>[
      owner,
      relogin,
      otherDevice,
      signedOut,
    ]) {
      addTearDown(api.close);
    }
    const RemoteProfile remote = RemoteProfile(
      config: <String, dynamic>{
        'proxies': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'node-1',
            'type': 'vless',
            'server': 'node.example.test',
            'uuid': 'device-node-credential',
          },
        ],
      },
      revision: 'rev-1',
      groupIcons: <String, String>{},
      nodeLabels: <String, String>{'node-1': '香港'},
      flagRegex: '',
    );

    expect(signedOut.cacheKey, isNull);
    cache.saveRemote('a@example.test', remote, signedOut.cacheKey);
    expect(file.existsSync(), isFalse);

    cache.saveRemote('a@example.test', remote, owner.cacheKey);
    final String raw = file.readAsStringSync();
    for (final String plain in <String>[
      'device-node-credential',
      'node.example.test',
      'rev-1',
      '香港',
      'proxies',
    ]) {
      expect(raw.contains(plain), isFalse, reason: plain);
    }
    expect(
      (cache.loadRemote('a@example.test', owner.cacheKey)!.config['proxies']
              as List<Object?>)
          .single,
      containsPair('uuid', 'device-node-credential'),
    );
    expect(cache.loadRemote('a@example.test', relogin.cacheKey), isNull);
    expect(cache.loadRemote('a@example.test', otherDevice.cacheKey), isNull);
    expect(cache.loadRemote('a@example.test', null), isNull);
    expect(cache.loadRemote('b@example.test', owner.cacheKey), isNull);

    final Map<String, dynamic> moved = jsonDecode(raw) as Map<String, dynamic>
      ..['account'] = 'b@example.test';
    file.writeAsStringSync(jsonEncode(moved));
    expect(cache.loadRemote('b@example.test', owner.cacheKey), isNull);
  });

  test('旧版本的明文面板配置缓存读到即删除，不再回用', () {
    final File file = File('${tempDir.path}/remote.json');
    final PanelResponseCache cache = PanelResponseCache(
      profileStore: JsonFileStore(File('${tempDir.path}/profile.json'), 't'),
      remoteStore: JsonFileStore(file, 't'),
    );
    file.writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'account': 'a@example.test',
        'kernel': 'mihomo',
        'revision': 'legacy',
        'config': <String, dynamic>{
          'proxies': <Map<String, dynamic>>[
            <String, dynamic>{'name': 'node-1', 'uuid': 'legacy-credential'},
          ],
        },
      }),
    );
    expect(cache.loadRemote('a@example.test', _sealKey), isNull);
    expect(file.existsSync(), isFalse);
  });

  test('profile-update-interval 只接受正整数小时，非法值视为未下发', () {
    expect(RemoteProfile.parseUpdateInterval('12'), const Duration(hours: 12));
    expect(
      RemoteProfile.parseUpdateInterval(' 24 '),
      const Duration(hours: 24),
    );
    for (final String? raw in <String?>[
      null,
      '',
      '0',
      '-1',
      '1.5',
      'abc',
      '8761',
      '9223372036854775807',
    ]) {
      expect(RemoteProfile.parseUpdateInterval(raw), isNull, reason: raw);
    }
  });

  test('/config/clash 响应头的更新间隔随配置落盘并可回读', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    server.listen((HttpRequest request) async {
      request.response.headers
        ..contentType = ContentType.json
        ..set('profile-update-interval', '12');
      request.response.write(
        jsonEncode(<String, Object>{
          'ret': 1,
          'data': <String, Object>{
            'config': <String, Object>{
              'proxy-groups': <Object>[],
              'rules': <String>[],
            },
            'revision': 'r1',
          },
        }),
      );
      await request.response.close();
    });
    final String origin = 'http://127.0.0.1:${server.port}';
    final PanelApiClient api = PanelApiClient(
      baseUrl: origin,
      configBaseUrl: origin,
      device: const DeviceInfo(
        platform: 'windows',
        deviceId: 'fixture',
        deviceName: '',
        deviceModel: '',
        osVersion: '',
        appVersion: '',
      ),
    );
    addTearDown(api.close);
    final RemoteProfile remote = await api.fetchClashProfile();
    expect(remote.updateInterval, const Duration(hours: 12));
    final PanelResponseCache cache = PanelResponseCache(
      profileStore: JsonFileStore(File('${tempDir.path}/profile.json'), 't'),
      remoteStore: JsonFileStore(File('${tempDir.path}/remote.json'), 't'),
    );
    cache.saveRemote('a@example.test', remote, _sealKey);
    expect(
      cache.loadRemote('a@example.test', _sealKey)?.updateInterval,
      const Duration(hours: 12),
    );
  });
}
