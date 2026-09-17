import 'package:flutter/material.dart';

import '../../l10n/app_language.dart';
import '../../l10n/l10n.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/auth_store_panel.dart';
import 'login_page.dart';

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

    final double titleSize = AppTheme.authTitleSizeOf(context);
    return AuthStorePanel(
      child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  L10n.t('选择语言'),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontSize: titleSize,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                    letterSpacing: titleSize * -0.04,
                  ),
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
                RadioGroup<AppLanguage>(
                  groupValue: _selected,
                  onChanged: (AppLanguage? value) {
                    if (value != null) {
                      _select(value);
                    }
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final AppLanguage language in AppLanguage.values)
                        RadioListTile<AppLanguage>(
                          value: language,
                          title: Text(language.label),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  style: authControlStyle(theme),
                  autofocus: AppScope.of(context).platform.isTelevision,
                  onPressed: () => widget.onChosen(_selected),
                  child: Text(L10n.t('确定')),
                ),
              ],
            ),
    );
  }
}
