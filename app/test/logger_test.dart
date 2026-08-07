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
}
