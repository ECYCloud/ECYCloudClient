class AppConfig {
  AppConfig._();

  static const String panelBaseUrl = String.fromEnvironment(
    'ECYCLOUD_PANEL_URL',
  );

  static const String subBaseUrl = String.fromEnvironment(
    'ECYCLOUD_SUB_URL',
  );

  static const String appVersion = String.fromEnvironment(
    'ECYCLOUD_VERSION',
    defaultValue: 'dev',
  );

  static bool get configured =>
      panelBaseUrl.isNotEmpty && subBaseUrl.isNotEmpty;

  static String get panelHost => Uri.parse(panelBaseUrl).host;

  static String get subOrigin => Uri.parse(subBaseUrl).origin;
}
