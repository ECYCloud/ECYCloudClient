class AppConfig {
  AppConfig._();

  static const String subBaseUrl = String.fromEnvironment(
    'ECYCLOUD_SUB_URL',
  );

  static const String siteBaseUrl = String.fromEnvironment(
    'ECYCLOUD_SITE_URL',
  );

  static const String appVersion = String.fromEnvironment(
    'ECYCLOUD_VERSION',
    defaultValue: 'dev',
  );

  static bool get configured =>
      subBaseUrl.isNotEmpty && siteBaseUrl.isNotEmpty;

  static String get subOrigin => Uri.parse(subBaseUrl).origin;

  static String get siteOrigin => Uri.parse(siteBaseUrl).origin;

  static String get siteHost => Uri.parse(siteBaseUrl).host;
}
