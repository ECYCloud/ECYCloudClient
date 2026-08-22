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

    final AppSettings debug = defaults.copyWith(logLevel: LogLevel.debug);
    expect(defaults.affectsKernel(debug), isTrue);
  });

  test('系统代理绕过变更不重启内核，TUN 排除网段要重启', () {
    expect(
      defaults.affectsKernel(
        defaults.copyWith(systemProxyBypass: <String>['example.com']),
      ),
      isFalse,
    );
    expect(
      defaults.affectsKernel(
        defaults.copyWith(tunExcludeAddresses: <String>['192.168.56.0/24']),
      ),
      isTrue,
    );
  });

  test('语言变更不重启内核，缺省为空表示尚未选定', () {
    expect(defaults.locale, isEmpty);
    expect(
      defaults.affectsKernel(defaults.copyWith(locale: 'en')),
      isFalse,
    );
    expect(
      AppSettings.fromJson(defaults.toJson()..['locale'] = 'zh_TW').locale,
      'zh_TW',
    );
  });

  test('分流模式缺省为规则，非法值回落到规则，切换不重启内核', () {
    expect(defaults.routeMode, 'rule');
    expect(
      AppSettings.fromJson(defaults.toJson()..['route_mode'] = 'global')
          .routeMode,
      'global',
    );
    expect(
      AppSettings.fromJson(defaults.toJson()..['route_mode'] = 'script')
          .routeMode,
      'rule',
    );
    expect(
      defaults.affectsKernel(defaults.copyWith(routeMode: 'global')),
      isFalse,
    );
  });
}
