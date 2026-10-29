import 'dart:io';

import 'package:ecycloud_client/core/app_paths.dart';
import 'package:ecycloud_client/core/logger.dart';
import 'package:flutter_test/flutter_test.dart';

// (I) 是继承标记，不随系统语言变化
List<String> _aces(String path) {
  final ProcessResult acl = Process.runSync('icacls', <String>[path]);
  return '${acl.stdout}'
      .split('\n')
      .map((String line) => line.trim())
      .where((String line) => line.contains(':('))
      .toList();
}

Future<List<String>> _warningsFrom(void Function() action) async {
  final int before = Logger.instance.entries.length;
  action();
  await Future<void>.delayed(Duration.zero);
  return Logger.instance.entries
      .skip(before)
      .where((LogEntry entry) => entry.level == LogLevel.warn)
      .map((LogEntry entry) => entry.message)
      .toList();
}

void main() {
  group(
    'Windows 应用数据目录权限加固',
    () {
      test('运行中的数据目录必须已切断 %APPDATA% 继承', () {
        final List<String> aces = _aces(AppPaths.userData.path);
        expect(aces, isNotEmpty, reason: 'icacls 没有输出任何 ACE');
        expect(
          aces.where((String ace) => ace.contains('(I)')),
          isEmpty,
          reason: '目录仍在继承 %APPDATA% 权限，凭据与面板缓存可能被本机其它账户读取：$aces',
        );
      });

      test('加固成功时目录只剩三条显式 ACE，且目录内旧文件改回继承', () async {
        final Directory dir = Directory.systemTemp.createTempSync(
          'ecycloud-harden-ok-',
        );
        addTearDown(() => dir.deleteSync(recursive: true));
        final File stale = File('${dir.path}\\credentials.json')
          ..writeAsStringSync('{"token":"x"}');
        // 先给旧文件加一条显式的宽松 ACE，/reset 必须把它清掉
        Process.runSync('icacls', <String>[
          stale.path,
          '/grant',
          '*S-1-5-11:(R)',
        ]);
        expect(
          _aces(stale.path).where((String ace) => !ace.contains('(I)')),
          isNotEmpty,
          reason: '前置条件不成立：旧文件上没有显式 ACE',
        );

        final List<String> warnings = await _warningsFrom(
          () => AppPaths.restrictWindowsDir(dir),
        );

        expect(warnings, isEmpty, reason: '加固成功不应产生告警：$warnings');
        expect(
          _aces(dir.path).where((String ace) => ace.contains('(I)')),
          isEmpty,
          reason: '目录继承没有被切断',
        );
        expect(
          _aces(stale.path).where((String ace) => !ace.contains('(I)')),
          isEmpty,
          reason: '旧文件上的显式 ACE 没有被 /reset 清掉',
        );
      });

      test('icacls 失败必须留下告警，不能静默退回裸继承', () async {
        final List<String> warnings = await _warningsFrom(
          () => AppPaths.restrictWindowsDir(
            Directory('${Directory.systemTemp.path}\\ecycloud-absent-dir'),
          ),
        );

        expect(warnings, isNotEmpty, reason: 'icacls 失败被静默吞掉了');
        expect(warnings.first, contains('应用数据目录权限未收紧'));
      });
    },
    skip: Platform.isWindows ? false : '目录 DACL 加固只在 Windows 上适用',
  );
}
