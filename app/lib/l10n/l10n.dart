import 'app_language.dart';
import 'translations.dart';

class L10n {
  L10n._();

  static AppLanguage current = AppLanguage.zhCN;

  static String t(String zh, [List<Object>? args]) {
    String text = current == AppLanguage.zhCN
        ? zh
        : (kTranslations[current]?[zh] ?? zh);
    if (args == null || args.isEmpty) {
      return text;
    }
    for (int i = 0; i < args.length; i++) {
      text = text.replaceAll('{$i}', '${args[i]}');
    }
    return text;
  }
}
