import 'package:flutter/material.dart';

import 'app_text_selection.dart';

class AppAlertDialog extends StatelessWidget {
  const AppAlertDialog({
    super.key,
    this.icon,
    this.title,
    this.content,
    this.actions,
    this.scrollable = true,
  });

  final Widget? icon;
  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    return AppTextSelection(
      child: AlertDialog(
        icon: icon,
        title: title,
        content: content == null
            ? null
            : DefaultTextStyle.merge(
                textAlign: TextAlign.justify,
                child: content!,
              ),
        actions: actions,
        scrollable: scrollable,
      ),
    );
  }
}
