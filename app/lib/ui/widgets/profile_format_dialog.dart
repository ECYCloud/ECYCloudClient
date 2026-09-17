import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../theme.dart';
import 'clipped_scroll_body.dart';

Future<void> showProfileFormatDialog(BuildContext context, String message) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(L10n.t('面板配置不规范')),
      content: ClippedScrollBody(
        filled: false,
        child: SelectableText(
          message,
          contextMenuBuilder: AppTheme.editableTextMenu,
        ),
      ),
      actions: <Widget>[
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(L10n.t('我知道了')),
        ),
      ],
    ),
  );
}
