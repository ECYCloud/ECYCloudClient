import 'dart:io';

import 'package:ecycloud_client/core/logger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('内核进程输出按 logrus 的 level= 归类', () {
    expect(
      Logger.kernelLevel(
        'time="2026-08-06T06:55:07.197573000+08:00" level=error '
        'msg="invalid config"',
      ),
      LogLevel.error,
    );
    expect(
      Logger.kernelLevel(
        'time="2026-08-06T06:55:38.551292500+08:00" level=info '
        'msg="Start initial configuration in progress"',
      ),
      LogLevel.info,
    );
    // 内核写 warning，不是 warn
    expect(
      Logger.kernelLevel('time="..." level=warning msg="deprecated feature"'),
      LogLevel.warn,
    );
    expect(
      Logger.kernelLevel('time="..." level=debug msg="dns exchanged"'),
      LogLevel.debug,
    );
    // fatal / panic 归到 error
    expect(
      Logger.kernelLevel('time="..." level=fatal msg="start failed"'),
      LogLevel.error,
    );
  });

  test('Clash API 的 /logs 只给类型与正文，按行首那个大写词归类', () {
    expect(Logger.kernelLevel('ERROR dial tcp: i/o timeout'), LogLevel.error);
    expect(Logger.kernelLevel('WARNING deprecated feature'), LogLevel.warn);
    expect(Logger.kernelLevel('DEBUG dns exchanged'), LogLevel.debug);
    expect(
      Logger.kernelLevel('INFO inbound listening at 127.0.0.1'),
      LogLevel.info,
    );
  });

  test('正文里出现的同名词不算级别', () {
    expect(
      Logger.kernelLevel(
        'time="..." level=info msg="found level=error in body"',
      ),
      LogLevel.info,
    );
    expect(
      Logger.kernelLevel('INFO router matched ERROR keyword'),
      LogLevel.info,
    );
  });

  test('认不出级别时退回 info，不误判为错误', () {
    expect(
      Logger.kernelLevel('configuration file test is successful'),
      LogLevel.info,
    );
    expect(Logger.kernelLevel(''), LogLevel.info);
  });

  test('只删除 30 天以前的日文件，其它文件不动', () {
    final Directory dir = _tmpDir();
    File appFile(String day) =>
        File('${dir.path}${Platform.pathSeparator}app-$day.log');
    for (final String day in <String>['2026-07-16', '2026-07-17', '2026-08-15']) {
      appFile(day).writeAsStringSync('x');
    }
    File(
      '${dir.path}${Platform.pathSeparator}software_errors.log',
    ).writeAsStringSync('e');

    Logger.pruneExpired(dir, DateTime(2026, 8, 15));

    expect(appFile('2026-07-16').existsSync(), isFalse);
    expect(appFile('2026-07-17').existsSync(), isTrue);
    expect(appFile('2026-08-15').existsSync(), isTrue);
    expect(
      File(
        '${dir.path}${Platform.pathSeparator}software_errors.log',
      ).existsSync(),
      isTrue,
    );
  });

  test('日文件超过 10MB 时裁掉旧内容再追加，仍是同一个文件', () {
    final Directory dir = _tmpDir();
    final File file = File(
      '${dir.path}${Platform.pathSeparator}app-2026-08-15.log',
    );
    file.writeAsBytesSync(List<int>.filled(10 * 1024 * 1024, 0x61));

    Logger.appendCapped(file, 'TAIL\n');

    expect(file.lengthSync(), lessThanOrEqualTo(10 * 1024 * 1024));
    expect(file.readAsStringSync().endsWith('TAIL\n'), isTrue);
  });
}

Directory _tmpDir() {
  final Directory dir = Directory(r'D:\tmp\ecycloud-logger-test');
  if (dir.existsSync()) {
    dir.deleteSync(recursive: true);
  }
  dir.createSync(recursive: true);
  addTearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });
  return dir;
}
