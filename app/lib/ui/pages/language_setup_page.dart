import 'package:flutter/material.dart';

import '../../l10n/app_language.dart';
import '../../l10n/l10n.dart';
import '../app_scope.dart';
import '../widgets/overlay_scroll_view.dart';

class LanguageSetupPage extends StatefulWidget {
  const LanguageSetupPage({
    super.key,
    required this.initial,
    required this.onChosen,
  });

  final AppLanguage initial;
  final ValueChanged<AppLanguage> onChosen;

  @override
  State<LanguageSetupPage> createState() => _LanguageSetupPageState();
}

class _LanguageSetupPageState extends State<LanguageSetupPage> {
  late AppLanguage _selected = widget.initial;

  void _select(AppLanguage language) {
    setState(() {
      _selected = language;
      L10n.current = language;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: OverlayScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  L10n.t('选择语言'),
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  L10n.t('可在设置中随时更改'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                for (final AppLanguage language in AppLanguage.values)
                  RadioListTile<AppLanguage>(
                    value: language,
                    groupValue: _selected,
                    title: Text(language.label),
                    onChanged: (AppLanguage? value) {
                      if (value != null) {
                        _select(value);
                      }
                    },
                  ),
                const SizedBox(height: 16),
                FilledButton(
                  autofocus: AppScope.of(context).platform.isTelevision,
                  onPressed: () => widget.onChosen(_selected),
                  child: Text(L10n.t('确定')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
