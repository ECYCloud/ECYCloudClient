import 'dart:io';

import 'package:ecycloud_client/core/app_paths.dart';
import 'package:ecycloud_client/data/models/user_profile.dart';
import 'package:ecycloud_client/data/store/json_file_store.dart';
import 'package:ecycloud_client/data/store/panel_response_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final String accountA = 'a' * 64;
  final String accountB = 'b' * 64;

  tearDown(() async {
    AppPaths.useSession('');
    if (AppPaths.sessions.existsSync()) {
      AppPaths.sessions.deleteSync(recursive: true);
    }
  });

  test('换账号后新账号读不到旧账号的面板缓存、日志与图标', () {
    final PanelResponseCache cache = PanelResponseCache();
    AppPaths.useSession(accountA);
    cache.saveProfile('a@example.test', _profile());
    File(
      '${AppPaths.iconCache.path}/icon',
    ).writeAsStringSync('private-icon-a');
    File('${AppPaths.logs.path}/app.log').writeAsStringSync('private-log-a');
    final String logsA = AppPaths.logs.path;

    AppPaths.useSession(accountB);
    expect(cache.loadProfile('a@example.test'), isNull);
    AppPaths.useSession(accountA);
    expect(cache.loadProfile('a@example.test')?.id, 1);
    AppPaths.useSession(accountB);
    expect(AppPaths.logs.path, isNot(logsA));
    expect(AppPaths.logs.listSync(), isEmpty);
    expect(AppPaths.iconCache.listSync(), isEmpty);
    expect(AppPaths.kernelRunDir, contains(accountB));
    expect(AppPaths.kernelRunDir, isNot(contains(accountA)));
  });

  test('回收超过 30 天未用的账号目录与旧版数据，保留当前账号和 30 天内用过的账号', () async {
    final String accountC = 'c' * 64;
    AppPaths.useSession(accountA);
    File('${AppPaths.logs.path}/app.log').writeAsStringSync('stale');
    final String sessionA = AppPaths.logs.parent.path;
    AppPaths.useSession(accountC);
    File('${AppPaths.logs.path}/app.log').writeAsStringSync('recent');
    final String sessionC = AppPaths.logs.parent.path;
    AppPaths.useSession(accountB);
    File('${AppPaths.logs.path}/app.log').writeAsStringSync('current');
    final String sessionB = AppPaths.logs.parent.path;
    File('$sessionA/.last-used').setLastModifiedSync(
      DateTime.now().subtract(const Duration(days: 31)),
    );
    File('$sessionB/.last-used').setLastModifiedSync(
      DateTime.now().subtract(const Duration(days: 90)),
    );
    final Directory unmarked = Directory('${AppPaths.sessions.path}/${'d' * 64}')
      ..createSync();
    final String root = AppPaths.userData.path;
    Directory('$root/logs').createSync();
    File('$root/logs/legacy.log').writeAsStringSync('legacy');
    File('$root/remote-config-cache.json').writeAsStringSync('{}');
    File('$root/credentials.json.session-ending').writeAsStringSync('1');
    final File settings = File('$root/settings.json')..writeAsStringSync('{}');
    addTearDown(settings.deleteSync);

    await AppPaths.collectGarbage();

    expect(Directory(sessionA).existsSync(), isFalse);
    expect(unmarked.existsSync(), isFalse);
    expect(File('$sessionC/logs/app.log').readAsStringSync(), 'recent');
    expect(File('$sessionB/logs/app.log').readAsStringSync(), 'current');
    for (final String name in <String>[
      'logs',
      'remote-config-cache.json',
      'credentials.json.session-ending',
    ]) {
      expect(
        FileSystemEntity.typeSync('$root/$name'),
        FileSystemEntityType.notFound,
        reason: name,
      );
    }
    expect(settings.existsSync(), isTrue);
  });

  test('未登录时的 guest 目录永不整体回收', () async {
    AppPaths.useSession('');
    File('${AppPaths.logs.path}/boot.log').writeAsStringSync('boot');
    final String guest = AppPaths.logs.parent.path;
    File('$guest/.last-used').setLastModifiedSync(
      DateTime.now().subtract(const Duration(days: 90)),
    );
    AppPaths.useSession(accountA);
    await AppPaths.collectGarbage();
    expect(File('$guest/logs/boot.log').readAsStringSync(), 'boot');
  });

  test('面板缓存写入失败不抛出，不拦主流程', () {
    final PanelResponseCache cache = PanelResponseCache(
      profileStore: JsonFileStore(
        File('${AppPaths.userData.path}/missing-dir/profile.json'),
        'test',
      ),
      remoteStore: JsonFileStore(
        File('${AppPaths.userData.path}/missing-dir/remote.json'),
        'test',
      ),
    );
    cache.saveProfile('a@example.test', _profile());
    expect(cache.loadProfile('a@example.test'), isNull);
  });

  test('同账号再次进入复用原目录的缓存，退出后目录保留', () async {
    AppPaths.useSession(accountA);
    File('${AppPaths.iconCache.path}/icon').writeAsStringSync('cached');
    AppPaths.useSession('');
    await AppPaths.collectGarbage();
    AppPaths.useSession(accountA);
    expect(File('${AppPaths.iconCache.path}/icon').readAsStringSync(), 'cached');
  });

  test('过期目录删不掉只记日志不抛错，下次再删', () async {
    AppPaths.useSession(accountA);
    final Directory locked = Directory('${AppPaths.logs.path}/locked')
      ..createSync();
    File('${locked.path}/app.log').writeAsStringSync('old');
    final String sessionA = AppPaths.logs.parent.path;
    AppPaths.useSession('');
    File('$sessionA/.last-used').setLastModifiedSync(
      DateTime.now().subtract(const Duration(days: 31)),
    );
    if (!Platform.isWindows) {
      Process.runSync('chmod', <String>['500', locked.path]);
      await AppPaths.collectGarbage();
      expect(Directory(sessionA).existsSync(), isTrue);
      Process.runSync('chmod', <String>['700', locked.path]);
    }
    await AppPaths.collectGarbage();
    expect(Directory(sessionA).existsSync(), isFalse);
  });
}

UserProfile _profile() => UserProfile.fromJson(<String, dynamic>{
  'id': 1,
  'email': 'a@example.test',
  'user_name': 'a',
  'class': 1,
  'upload': 0,
  'download': 0,
  'transfer_enable': 100,
});
