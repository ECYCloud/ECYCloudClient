import 'dart:io';
import 'dart:ui';

import '../core/app_paths.dart';
import '../data/store/settings_store.dart';

enum AppLanguage {
  zhCN('zh_CN', '简体中文'),
  zhTW('zh_TW', '繁體中文'),
  en('en-US', 'English');

  const AppLanguage(this.code, this.label);

  final String code;
  final String label;

  String get contentLanguage => code.replaceAll('_', '-');

  Locale get flutterLocale => switch (this) {
    AppLanguage.zhCN => const Locale('zh', 'CN'),
    AppLanguage.zhTW => const Locale('zh', 'TW'),
    AppLanguage.en => const Locale('en', 'US'),
  };

  static AppLanguage? tryParse(String? raw) {
    final String code = raw?.trim() ?? '';
    if (code.isEmpty) {
      return null;
    }
    if (code == 'en') {
      return en;
    }
    for (final AppLanguage language in AppLanguage.values) {
      if (language.code == code) {
        return language;
      }
    }
    return null;
  }

  static AppLanguage fromDevice(Locale locale) {
    if (locale.languageCode == 'zh' &&
        (locale.scriptCode == 'Hant' ||
            locale.countryCode == 'TW' ||
            locale.countryCode == 'HK' ||
            locale.countryCode == 'MO')) {
      return AppLanguage.zhTW;
    }
    return locale.languageCode == 'zh' ? AppLanguage.zhCN : AppLanguage.en;
  }

  static AppLanguage resolve({required String stored, Locale? device}) {
    return tryParse(stored) ??
        fromDevice(device ?? PlatformDispatcher.instance.locale);
  }

  static AppSettings seed(SettingsStore store, AppSettings settings) {
    final AppLanguage? language = tryParse(settings.locale);
    if (language != null && settings.locale == language.code) {
      return settings;
    }
    final String? installer = language?.code ?? readInstallerLocale();
    if (installer != null) {
      final AppSettings next = settings.copyWith(locale: installer);
      store.save(next);
      return next;
    }
    if (store.hasPersistedSettings) {
      final AppSettings next = settings.copyWith(
        locale: resolve(stored: settings.locale).code,
      );
      store.save(next);
      return next;
    }
    return settings;
  }

  static String? readInstallerLocale() {
    try {
      final File file = AppPaths.installerLocale;
      if (!file.existsSync()) {
        return null;
      }
      return tryParse(file.readAsStringSync())?.code;
    } on Object {
      return null;
    }
  }
}
