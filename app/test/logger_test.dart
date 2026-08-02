import 'package:ecycloud_client/core/logger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('内核日志的级别按行内那个大写词归类', () {
    expect(
      Logger.kernelLevel(
        '+0800 2026-07-29 23:26:09 ERROR [1184533604 49ms] connection: '
        'connection upload closed: raw-read tcp 127.0.0.1:10203->127.0.0.1:60838: '
        'An existing connection was forcibly closed by the remote host.',
      ),
      LogLevel.error,
    );
    expect(
      Logger.kernelLevel('+0800 2026-07-29 23:14:31 INFO sing-box started'),
      LogLevel.info,
    );
    expect(
      Logger.kernelLevel('+0800 2026-07-29 23:14:31 WARN deprecated feature'),
      LogLevel.warn,
    );
    // 不带时间戳的排版（DisableTimestamp）与秒偏移排版（默认）都要认得出
    expect(Logger.kernelLevel('DEBUG [1 2ms] dns: exchanged'), LogLevel.debug);
    expect(Logger.kernelLevel('TRACE[0001] router: match'), LogLevel.trace);
    // FATAL / PANIC 归到 error
    expect(Logger.kernelLevel('+0800 ... FATAL start service'), LogLevel.error);
    // 正文里出现的同名词不算级别
    expect(
      Logger.kernelLevel(
        '+0800 2026-07-29 23:26:09 INFO [1 2ms] router: found ERROR in payload',
      ),
      LogLevel.info,
    );
  });
}
