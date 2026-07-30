class AppConfig {
  AppConfig._();

  static const String panelBaseUrl = String.fromEnvironment(
    'ECYCLOUD_PANEL_URL',
  );

  static const String appVersion = String.fromEnvironment(
    'ECYCLOUD_VERSION',
    defaultValue: 'dev',
  );

  static bool get configured => panelBaseUrl.isNotEmpty;

  static String get panelHost => Uri.parse(panelBaseUrl).host;
}
