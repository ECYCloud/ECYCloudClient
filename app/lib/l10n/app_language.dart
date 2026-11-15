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

  // 每次运行安装器都会选一次语言并重写 installer-locale；比上次保存的设置新，说明这次安装晚于用户最后一次改设置
  static AppSettings seed(
    SettingsStore store,
    AppSettings settings, {
    String? Function(DateTime? after) installerLocale = readInstallerLocale,
  }) {
    final String? next =
        installerLocale(store.savedAt) ??
        tryParse(settings.locale)?.code ??
        (store.hasPersistedSettings
            ? resolve(stored: settings.locale).code
            : null);
    if (next == null || next == settings.locale) {
      return settings;
    }
    final AppSettings seeded = settings.copyWith(locale: next);
    store.save(seeded);
    return seeded;
  }

  static String? readInstallerLocale(DateTime? after) {
    try {
      final File file = AppPaths.installerLocale;
      if (!file.existsSync() ||
          (after != null && !file.lastModifiedSync().isAfter(after))) {
        return null;
      }
      return tryParse(file.readAsStringSync())?.code;
    } on Object {
      return null;
    }
  }
}
