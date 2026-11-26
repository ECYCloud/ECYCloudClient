// 用 /bin/sh 写的假 gsettings 代替系统命令，Windows 上跑不了
@TestOn('!windows')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ecycloud_client/core/app_paths.dart';
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:ecycloud_client/platform/linux/linux_platform_service.dart';

const String _fakeGsettings = r'''#!/bin/sh
file="$GSETTINGS_STATE/$2 $3"
case "$1" in
  get)
    [ -f "$file" ] || exit 1
    cat "$file"
    ;;
  set)
    printf '%s' "$4" > "$file"
    echo "$2 $3 $4" >> "$GSETTINGS_STATE/log"
    ;;
esac
''';

const Map<String, String> _original = <String, String>{
  'org.gnome.system.proxy mode': "'none'",
  'org.gnome.system.proxy ignore-hosts': "['localhost', '127.0.0.0/8']",
  'org.gnome.system.proxy.http host': "''",
  'org.gnome.system.proxy.http port': '0',
  'org.gnome.system.proxy.https host': "''",
  'org.gnome.system.proxy.https port': '0',
  'org.gnome.system.proxy.socks host': "''",
  'org.gnome.system.proxy.socks port': '0',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late Directory state;
  late Map<String, String> env;
  late List<Process> guards;
  late LinuxPlatformService service;

  LinuxPlatformService create() => LinuxPlatformService(
    run: (String executable, List<String> arguments) =>
        Process.run(executable, arguments, environment: env),
    start:
        (
          String executable,
          List<String> arguments, {
          ProcessStartMode mode = ProcessStartMode.normal,
        }) async {
          final Process process = await Process.start(
            executable,
            arguments,
            mode: mode,
            environment: env,
          );
          guards.add(process);
          return process;
        },
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ecy-proxy-guard-');
    state = Directory('${dir.path}/state')..createSync();
    final File gsettings = File('${dir.path}/bin/gsettings')
      ..createSync(recursive: true)
      ..writeAsStringSync(_fakeGsettings);
    Process.runSync('chmod', <String>['755', gsettings.path]);
    _original.forEach(
      (String key, String value) =>
          File('${state.path}/$key').writeAsStringSync(value),
    );
    env = <String, String>{
      'PATH': '${gsettings.parent.path}:${Platform.environment['PATH']}',
      'GSETTINGS_STATE': state.path,
    };
    guards = <Process>[];
    service = create();
    if (AppPaths.proxySnapshot.existsSync()) {
      AppPaths.proxySnapshot.deleteSync();
    }
  });

  tearDown(() async {
    for (final Process guard in guards) {
      guard.kill(ProcessSignal.sigkill);
    }
    if (AppPaths.proxySnapshot.existsSync()) {
      AppPaths.proxySnapshot.deleteSync();
    }
    dir.deleteSync(recursive: true);
  });

  String read(String key) => File('${state.path}/$key').readAsStringSync();

  Future<void> exited(Process guard) async {
    final Stopwatch watch = Stopwatch()..start();
    while (Process.runSync('kill', <String>['-0', '${guard.pid}']).exitCode ==
        0) {
      if (watch.elapsed > const Duration(seconds: 10)) {
        fail('守护进程 ${guard.pid} 未退出');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test('界面没还原就退出（强杀时 stdin 随进程关闭）：守护按快照还原并删掉快照', () async {
    await service.setSystemProxy(port: 7890, bypass: const <String>[]);
    await service.setSystemProxy(port: 7891, bypass: const <String>[]);
    expect(guards, hasLength(2));
    await exited(guards.first);
    expect(read('org.gnome.system.proxy mode'), "'manual'");
    expect(read('org.gnome.system.proxy.http port'), '7891');

    await guards.last.stdin.close();
    await exited(guards.last);

    _original.forEach(
      (String key, String value) => expect(read(key), value, reason: key),
    );
    expect(AppPaths.proxySnapshot.existsSync(), isFalse);
  });

  test('正常还原后守护直接退出，不再改动系统代理', () async {
    await service.setSystemProxy(port: 7890, bypass: const <String>[]);
    await service.restoreSystemProxy();
    final String log = File('${state.path}/log').readAsStringSync();

    await exited(guards.single);

    expect(File('${state.path}/log').readAsStringSync(), log);
    expect(read('org.gnome.system.proxy mode'), "'none'");
  });

  test('系统代理已被别的程序改掉时守护什么都不做', () async {
    await service.setSystemProxy(port: 7890, bypass: const <String>[]);
    File('${state.path}/org.gnome.system.proxy.http port')
        .writeAsStringSync('8080');
    final String log = File('${state.path}/log').readAsStringSync();

    await guards.single.stdin.close();
    await exited(guards.single);

    expect(File('${state.path}/log').readAsStringSync(), log);
    expect(read('org.gnome.system.proxy.http port'), '8080');
    expect(read('org.gnome.system.proxy mode'), "'manual'");
    expect(AppPaths.proxySnapshot.existsSync(), isTrue);
  });

  test('重开后自检：代理仍是本客户端按设置端口写的，按快照还原', () async {
    await service.setSystemProxy(
      port: SettingsStore().load().mixedPort,
      bypass: const <String>[],
    );
    guards.single.kill(ProcessSignal.sigkill);
    await exited(guards.single);

    expect(await create().restoreLeftoverProxy(), isTrue);

    _original.forEach(
      (String key, String value) => expect(read(key), value, reason: key),
    );
    expect(AppPaths.proxySnapshot.existsSync(), isFalse);
  });

  test('重开后自检：代理已被别的程序改掉时只删快照，不覆盖', () async {
    await service.setSystemProxy(port: 7890, bypass: const <String>[]);
    File('${state.path}/org.gnome.system.proxy.http port')
        .writeAsStringSync('8080');
    await guards.single.stdin.close();
    await exited(guards.single);
    final String log = File('${state.path}/log').readAsStringSync();

    expect(await create().restoreLeftoverProxy(), isFalse);

    expect(File('${state.path}/log').readAsStringSync(), log);
    expect(read('org.gnome.system.proxy.http port'), '8080');
    expect(read('org.gnome.system.proxy mode'), "'manual'");
    expect(AppPaths.proxySnapshot.existsSync(), isFalse);
  });
}
