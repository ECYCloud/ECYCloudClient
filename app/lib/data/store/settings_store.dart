import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart' show ThemeMode;

import '../../core/app_paths.dart';
import '../../core/logger.dart' show LogLevel, LogLevelName;
import '../../domain/config/local_template.dart';
import 'json_file_store.dart';

enum PerAppProxyMode { off, include, exclude }

class AppSettings {
  const AppSettings({
    required this.tunEnabled,
    required this.tunStrictRoute,
    required this.systemProxyEnabled,
    required this.mixedPort,
    required this.allowLan,
    required this.ipv6Enabled,
    required this.logLevel,
    required this.autoConnect,
    required this.launchAtLogin,
    required this.closeToTray,
    required this.themeMode,
    required this.perAppMode,
    required this.perAppPackages,
    required this.systemProxyBypass,
    required this.tunExcludeAddresses,
  });

  const AppSettings.defaults()
    : tunEnabled = false,
      // 与内核保持一致的关闭默认值：strict-route 在 Windows 上是靠 WFP 粗暴拦 53
      // 端口并让「不支持的网络」不可达实现的（内核的 TUN 走 metacubex/sing-tun），
      // 会连带打断走回环与 IPv6 的本机 IPC，代价远大于它防的那点 DNS 泄露
      tunStrictRoute = false,
      systemProxyEnabled = true,
      mixedPort = 10203,
      allowLan = false,
      ipv6Enabled = true,
      logLevel = LogLevel.warn,
      autoConnect = false,
      launchAtLogin = false,
      closeToTray = true,
      themeMode = ThemeMode.system,
      perAppMode = PerAppProxyMode.off,
      perAppPackages = const <String>[],
      systemProxyBypass = const <String>[],
      tunExcludeAddresses = const <String>[];

  final bool tunEnabled;
  final bool tunStrictRoute;
  final bool systemProxyEnabled;
  final int mixedPort;
  final bool allowLan;
  final bool ipv6Enabled;
  final LogLevel logLevel;
  final bool autoConnect;
  final bool launchAtLogin;
  final bool closeToTray;
  final ThemeMode themeMode;
  final PerAppProxyMode perAppMode;
  final List<String> perAppPackages;
  final List<String> systemProxyBypass;
  final List<String> tunExcludeAddresses;

  AppSettings copyWith({
    bool? tunEnabled,
    bool? tunStrictRoute,
    bool? systemProxyEnabled,
    int? mixedPort,
    bool? allowLan,
    bool? ipv6Enabled,
    LogLevel? logLevel,
    bool? autoConnect,
    bool? launchAtLogin,
    bool? closeToTray,
    ThemeMode? themeMode,
    PerAppProxyMode? perAppMode,
    List<String>? perAppPackages,
    List<String>? systemProxyBypass,
    List<String>? tunExcludeAddresses,
  }) => AppSettings(
    tunEnabled: tunEnabled ?? this.tunEnabled,
    tunStrictRoute: tunStrictRoute ?? this.tunStrictRoute,
    systemProxyEnabled: systemProxyEnabled ?? this.systemProxyEnabled,
    mixedPort: mixedPort ?? this.mixedPort,
    allowLan: allowLan ?? this.allowLan,
    ipv6Enabled: ipv6Enabled ?? this.ipv6Enabled,
    logLevel: logLevel ?? this.logLevel,
    autoConnect: autoConnect ?? this.autoConnect,
    launchAtLogin: launchAtLogin ?? this.launchAtLogin,
    closeToTray: closeToTray ?? this.closeToTray,
    themeMode: themeMode ?? this.themeMode,
    perAppMode: perAppMode ?? this.perAppMode,
    perAppPackages: perAppPackages ?? this.perAppPackages,
    systemProxyBypass: systemProxyBypass ?? this.systemProxyBypass,
    tunExcludeAddresses: tunExcludeAddresses ?? this.tunExcludeAddresses,
  );

  bool affectsKernel(AppSettings other) =>
      tunEnabled != other.tunEnabled ||
      tunStrictRoute != other.tunStrictRoute ||
      mixedPort != other.mixedPort ||
      allowLan != other.allowLan ||
      ipv6Enabled != other.ipv6Enabled ||
      kernelLogLevel != other.kernelLogLevel ||
      perAppMode != other.perAppMode ||
      !listEquals(perAppPackages, other.perAppPackages) ||
      !listEquals(tunExcludeAddresses, other.tunExcludeAddresses);

  // 内核至少按 info 输出，[logLevel] 只作为落盘门槛：内核在 warning 级几乎只在出错时
  // 说话，日志页会退化成一堵错误噪声墙，首次连接时的规则集下载进度也只有
  // info 级才有。日志页读的是内存环形缓冲，全量显示不额外占磁盘。
  // 想让内核更啰嗦就把设置调到 debug，那时落盘门槛一并降低。
  String get kernelLogLevel =>
      (logLevel.index < LogLevel.info.index ? logLevel : LogLevel.info).label;

  /// [takeover] 为假即内核常驻但不接管出口：TUN 关掉，只留控制面与 mixed 口。
  LocalTemplateOptions toTemplateOptions({
    required String tunInterfaceName,
    required bool takeover,
  }) => LocalTemplateOptions(
    tunEnabled: takeover && tunEnabled,
    tunStrictRoute: tunStrictRoute,
    mixedPort: mixedPort,
    allowLan: allowLan,
    ipv6Enabled: ipv6Enabled,
    logLevel: kernelLogLevel,
    tunInterfaceName: tunInterfaceName,
    tunIncludePackages: perAppMode == PerAppProxyMode.include
        ? perAppPackages
        : const <String>[],
    tunExcludePackages: perAppMode == PerAppProxyMode.exclude
        ? perAppPackages
        : const <String>[],
    tunExcludeAddresses: tunExcludeAddresses,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema': SettingsStore.schema,
    'tun_enabled': tunEnabled,
    'tun_strict_route': tunStrictRoute,
    'system_proxy_enabled': systemProxyEnabled,
    'mixed_port': mixedPort,
    'allow_lan': allowLan,
    'ipv6_enabled': ipv6Enabled,
    'log_level': logLevel.label,
    'auto_connect': autoConnect,
    'launch_at_login': launchAtLogin,
    'close_to_tray': closeToTray,
    'theme_mode': themeMode.name,
    'per_app_mode': perAppMode.name,
    'per_app_packages': perAppPackages,
    'system_proxy_bypass': systemProxyBypass,
    'tun_exclude_addresses': tunExcludeAddresses,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    const AppSettings fallback = AppSettings.defaults();
    return AppSettings(
      tunEnabled: json['tun_enabled'] as bool? ?? fallback.tunEnabled,
      tunStrictRoute:
          json['tun_strict_route'] as bool? ?? fallback.tunStrictRoute,
      systemProxyEnabled:
          json['system_proxy_enabled'] as bool? ?? fallback.systemProxyEnabled,
      mixedPort: (json['mixed_port'] as num?)?.toInt() ?? fallback.mixedPort,
      allowLan: json['allow_lan'] as bool? ?? fallback.allowLan,
      ipv6Enabled: json['ipv6_enabled'] as bool? ?? fallback.ipv6Enabled,
      logLevel: LogLevel.values.firstWhere(
        (LogLevel level) => level.label == json['log_level'],
        orElse: () => fallback.logLevel,
      ),
      autoConnect: json['auto_connect'] as bool? ?? fallback.autoConnect,
      launchAtLogin: json['launch_at_login'] as bool? ?? fallback.launchAtLogin,
      closeToTray: json['close_to_tray'] as bool? ?? fallback.closeToTray,
      themeMode: ThemeMode.values.firstWhere(
        (ThemeMode mode) => mode.name == json['theme_mode'],
        orElse: () => fallback.themeMode,
      ),
      perAppMode: PerAppProxyMode.values.firstWhere(
        (PerAppProxyMode mode) => mode.name == json['per_app_mode'],
        orElse: () => fallback.perAppMode,
      ),
      perAppPackages:
          (json['per_app_packages'] as List<dynamic>?)?.cast<String>() ??
          fallback.perAppPackages,
      systemProxyBypass:
          (json['system_proxy_bypass'] as List<dynamic>?)?.cast<String>() ??
          fallback.systemProxyBypass,
      tunExcludeAddresses:
          (json['tun_exclude_addresses'] as List<dynamic>?)?.cast<String>() ??
          fallback.tunExcludeAddresses,
    );
  }
}

class SettingsStore {
  SettingsStore() : _store = JsonFileStore(AppPaths.settings, 'settings');

  static const int schema = 2;

  final JsonFileStore _store;

  AppSettings load() {
    final Map<String, dynamic> data = _store.read();
    if (data.isEmpty) {
      return const AppSettings.defaults();
    }

    final Object? version = data['schema'];
    if (version == schema) {
      return AppSettings.fromJson(data);
    }
    // schema 1 把 tun_strict_route 默认成了开，这个默认值本身定错了，
    // 迁移时只丢这一个键让它回落到新默认值，其余设置照旧保留
    if (version == 1) {
      return AppSettings.fromJson(data..remove('tun_strict_route'));
    }
    // 无 schema 的文件出自尚未定型的预发布版本，整份丢弃
    return const AppSettings.defaults();
  }

  void save(AppSettings settings) => _store.write(settings.toJson());
}
