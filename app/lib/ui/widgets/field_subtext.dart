import 'package:flutter/material.dart';

/// InputDecorator 把 helper / error 缩进到输入内容的起点（contentPadding.start 加
/// 边框 gapPadding），与输入框左边框对不齐；要贴边框只能作为输入框的兄弟节点给出。
class FieldSubtext extends StatelessWidget {
  const FieldSubtext(this.text, {super.key, this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: isError
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

extension ValidatedTextField on TextField {
  Widget validated(String? Function() validate) => FormField<String>(
    validator: (_) => validate(),
    builder: (FormFieldState<String> field) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        this,
        if (field.hasError) FieldSubtext(field.errorText!, isError: true),
      ],
    ),
  );
}
