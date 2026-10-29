import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'app_alert_dialog.dart';

Future<void> showProfileFormatDialog(BuildContext context, String message) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => AppAlertDialog(
      title: Text(L10n.t('面板配置不规范')),
      content: Text(message),
      actions: <Widget>[
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(L10n.t('我知道了')),
        ),
      ],
    ),
  );
}
