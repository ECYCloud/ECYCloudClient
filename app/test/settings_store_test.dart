import 'package:ecycloud_client/core/logger.dart' show LogLevel;
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const AppSettings defaults = AppSettings.defaults();

  test('内核日志级别不低于 info，落盘门槛才按用户设置', () {
    expect(defaults.logLevel, LogLevel.warn);
    expect(defaults.kernelLogLevel, 'info');

    expect(
      defaults.copyWith(logLevel: LogLevel.error).kernelLogLevel,
      'info',
      reason: '内核在 error 级几乎不说话，日志页会没东西可看',
    );
    expect(defaults.copyWith(logLevel: LogLevel.debug).kernelLogLevel, 'debug');
  });

  test('落盘门槛在 info 及以上各档之间调整不重启内核', () {
    final AppSettings error = defaults.copyWith(logLevel: LogLevel.error);
    expect(defaults.affectsKernel(error), isFalse);

    final AppSettings trace = defaults.copyWith(logLevel: LogLevel.trace);
    expect(defaults.affectsKernel(trace), isTrue);
  });
}
