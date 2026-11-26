import 'package:ecycloud_client/core/logger.dart' show LogLevel;
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const AppSettings defaults = AppSettings.defaults();

  test('内核日志级别恒为 info：低于 info 看不到规则集进度，debug 不下发给内核', () {
    expect(defaults.logLevel, LogLevel.warn);
    expect(defaults.kernelLogLevel, 'info');

    expect(
      defaults.copyWith(logLevel: LogLevel.error).kernelLogLevel,
      'info',
      reason: '内核在 error 级几乎不说话，日志页会没东西可看',
    );
    expect(
      defaults.copyWith(logLevel: LogLevel.debug).kernelLogLevel,
      'info',
      reason: 'debug 会让内核挂上不鉴权的 /debug/pprof，一律不下发给内核（AUD-21）',
    );
  });

  test('落盘门槛在各档之间调整都不重启内核（内核级别恒为 info）', () {
    final AppSettings error = defaults.copyWith(logLevel: LogLevel.error);
    expect(defaults.affectsKernel(error), isFalse);

    final AppSettings debug = defaults.copyWith(logLevel: LogLevel.debug);
    expect(
      defaults.affectsKernel(debug),
      isFalse,
      reason: 'debug 只提高界面侧落盘门槛，内核级别仍是 info，不需要重启',
    );
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

  test('使用地区缺省为中国，非法值回落到中国，切换要重启内核', () {
    expect(defaults.region, AppSettings.regionChina);
    final AppSettings overseas = defaults.copyWith(
      region: AppSettings.regionOverseas,
    );
    expect(defaults.affectsKernel(overseas), isTrue);
    expect(
      AppSettings.fromJson(overseas.toJson()).region,
      AppSettings.regionOverseas,
    );
    expect(
      AppSettings.fromJson(defaults.toJson()..['region'] = 'mars').region,
      AppSettings.regionChina,
    );
    expect(
      overseas
          .toTemplateOptions(
            tunInterfaceName: 'ECYCloud',
            takeover: true,
            supportsSystemProxy: true,
          )
          .proxyChina,
      isTrue,
    );
  });

  test('接管系统 DNS 的平台标记原样传进模板参数', () {
    const AppSettings settings = AppSettings.defaults();
    for (final bool value in <bool>[true, false]) {
      expect(
        settings
            .toTemplateOptions(
              tunInterfaceName: '',
              tunSetsSystemDns: value,
              takeover: true,
              supportsSystemProxy: true,
            )
            .tunSetsSystemDns,
        value,
      );
    }
  });

  test('语言变更不重启内核，缺省为空表示尚未选定', () {
    expect(defaults.locale, isEmpty);
    expect(defaults.affectsKernel(defaults.copyWith(locale: 'en-US')), isFalse);
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
