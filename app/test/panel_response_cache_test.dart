import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:ecycloud_client/data/api/api_exception.dart';
import 'package:ecycloud_client/data/models/user_profile.dart';
import 'package:ecycloud_client/data/store/json_file_store.dart';
import 'package:ecycloud_client/data/store/panel_response_cache.dart';

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
    cache.saveRemote('a@example.test', remote);
    final RemoteProfile restored = cache.loadRemote('a@example.test')!;
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
    cache.clear();
    expect(cache.loadRemote('a@example.test'), isNull);
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
      expect(cache.loadRemote('a@example.test'), isNull, reason: invalid.key);
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
    );

    final RemoteProfile? loaded = cache.loadRemote('user@example.com');
    expect(loaded?.revision, 'rev-9');
    expect(loaded?.nodeLabels['node-1'], '香港');
    expect(cache.loadRemote('other@example.com'), isNull);
  });
}
