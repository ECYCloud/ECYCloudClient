import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:ecycloud_client/data/models/user_profile.dart';
import 'package:ecycloud_client/data/store/json_file_store.dart';
import 'package:ecycloud_client/data/store/panel_response_cache.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory('D:/tmp/ecycloud-cache-test-${DateTime.now().microsecondsSinceEpoch}')
      ..createSync(recursive: true);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
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
