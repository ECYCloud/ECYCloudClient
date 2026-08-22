import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart' show ThemeMode;

import '../../core/app_paths.dart';
import '../../core/logger.dart' show LogLevel, LogLevelName;
import '../../domain/config/local_template.dart';
import '../../domain/config/network_bypass.dart';
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
    required this.routeMode,
    required this.autoConnect,
    required this.launchAtLogin,
    required this.closeToTray,
    required this.themeMode,
    required this.locale,
    required this.perAppMode,
    required this.perAppPackages,
    required this.systemProxyBypass,
    required this.tunExcludeAddresses,
  });

  const AppSettings.defaults()
    : tunEnabled = false,
      // 默认关：Windows 上 strict-route 靠 WFP 拦 53 并让不支持的网络不可达，会打断回环/IPv6 IPC
      tunStrictRoute = false,
      systemProxyEnabled = true,
      mixedPort = 10203,
      allowLan = false,
      ipv6Enabled = true,
      logLevel = LogLevel.warn,
      routeMode = 'rule',
      autoConnect = false,
      launchAtLogin = false,
      closeToTray = true,
      themeMode = ThemeMode.system,
      locale = '',
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
  final String routeMode;
  final bool autoConnect;
  final bool launchAtLogin;
  final bool closeToTray;
  final ThemeMode themeMode;
  final String locale;
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
    String? routeMode,
    bool? autoConnect,
    bool? launchAtLogin,
    bool? closeToTray,
    ThemeMode? themeMode,
    String? locale,
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
    routeMode: routeMode ?? this.routeMode,
    autoConnect: autoConnect ?? this.autoConnect,
    launchAtLogin: launchAtLogin ?? this.launchAtLogin,
    closeToTray: closeToTray ?? this.closeToTray,
    themeMode: themeMode ?? this.themeMode,
    locale: locale ?? this.locale,
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

  // 内核至少按 info 输出；logLevel 只作落盘门槛，warning 级看不到规则集下载进度
  String get kernelLogLevel =>
      (logLevel.index < LogLevel.info.index ? logLevel : LogLevel.info).label;

  /// takeover 为假时内核常驻但不接管出口：关掉 TUN，只留控制面与 mixed 口
  LocalTemplateOptions toTemplateOptions({
    required String tunInterfaceName,
    required bool takeover,
    List<String> extraTunExcludeAddresses = const <String>[],
  }) => LocalTemplateOptions(
    tunEnabled: takeover && tunEnabled,
    tunStrictRoute: tunStrictRoute,
    mixedPort: mixedPort,
    allowLan: allowLan,
    ipv6Enabled: ipv6Enabled,
    logLevel: kernelLogLevel,
    routeMode: routeMode,
    tunInterfaceName: tunInterfaceName,
    tunIncludePackages: perAppMode == PerAppProxyMode.include
        ? perAppPackages
        : const <String>[],
    tunExcludePackages: perAppMode == PerAppProxyMode.exclude
        ? perAppPackages
        : const <String>[],
    tunExcludeAddresses: appendUnique(
      tunExcludeAddresses,
      extraTunExcludeAddresses,
    ),
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
    'route_mode': routeMode,
    'auto_connect': autoConnect,
    'launch_at_login': launchAtLogin,
    'close_to_tray': closeToTray,
    'theme_mode': themeMode.name,
    'locale': locale,
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
      routeMode: _routeMode(json['route_mode'], fallback.routeMode),
      autoConnect: json['auto_connect'] as bool? ?? fallback.autoConnect,
      launchAtLogin: json['launch_at_login'] as bool? ?? fallback.launchAtLogin,
      closeToTray: json['close_to_tray'] as bool? ?? fallback.closeToTray,
      themeMode: ThemeMode.values.firstWhere(
        (ThemeMode mode) => mode.name == json['theme_mode'],
        orElse: () => fallback.themeMode,
      ),
      locale: json['locale'] as String? ?? fallback.locale,
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

  static const Set<String> _routeModes = <String>{'rule', 'global', 'direct'};

  static String _routeMode(Object? raw, String fallback) {
    if (raw is String && _routeModes.contains(raw)) {
      return raw;
    }
    return fallback;
  }
}

class SettingsStore {
  SettingsStore() : _store = JsonFileStore(AppPaths.settings, 'settings');

  static const int schema = 2;

  final JsonFileStore _store;

  bool get hasPersistedSettings => _store.read().isNotEmpty;

  AppSettings load() {
    final Map<String, dynamic> data = _store.read();
    if (data.isEmpty) {
      return const AppSettings.defaults();
    }

    final Object? version = data['schema'];
    if (version == schema) {
      return AppSettings.fromJson(data);
    }
    // schema 1 把 tun_strict_route 默认成开，迁移只丢这一键回落新默认
    if (version == 1) {
      return AppSettings.fromJson(data..remove('tun_strict_route'));
    }
    // 无 schema 的预发布文件整份丢弃
    return const AppSettings.defaults();
  }

  void save(AppSettings settings) => _store.write(settings.toJson());
}
