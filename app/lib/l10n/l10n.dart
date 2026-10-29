import 'app_language.dart';
import 'translations.dart';

class L10n {
  L10n._();

  static AppLanguage current = AppLanguage.zhCN;

  static String message(String source) {
    final String translated = t(source);
    if (translated != source || current == AppLanguage.zhCN) return translated;
    final RegExp token = RegExp(r'\{\d+\}');
    final entries =
        kTranslations[current]!.entries
            .where((entry) => token.hasMatch(entry.key))
            .toList()
          ..sort(
            (a, b) => b.key
                .replaceAll(token, '')
                .length
                .compareTo(a.key.replaceAll(token, '').length),
          );
    for (final entry in entries) {
      final List<String> slots = token
          .allMatches(entry.key)
          .map((match) => match[0]!)
          .toList();
      final String pattern = entry.key.splitMapJoin(
        token,
        onMatch: (_) => r'([\s\S]+?)',
        onNonMatch: RegExp.escape,
      );
      final RegExpMatch? match = RegExp('^$pattern\$').firstMatch(source);
      if (match == null) continue;
      final Map<String, String> values = <String, String>{
        for (int i = 0; i < slots.length; i++) slots[i]: match[i + 1]!,
      };
      return entry.value.replaceAllMapped(token, (match) => values[match[0]]!);
    }
    return source;
  }

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
