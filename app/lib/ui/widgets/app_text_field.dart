import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_text_selection.dart';

class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.style,
    this.textAlign = TextAlign.start,
    this.textAlignVertical,
    this.readOnly = false,
    this.autofocus = false,
    this.obscureText = false,
    this.autocorrect,
    this.enableSuggestions = true,
    this.maxLines = 1,
    this.minLines,
    this.maxLength,
    this.onChanged,
    this.onSubmitted,
    this.inputFormatters,
    this.enabled,
    this.autofillHints = const <String>[],
    this.scrollController,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final InputDecoration? decoration;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final TextStyle? style;
  final TextAlign textAlign;
  final TextAlignVertical? textAlignVertical;
  final bool readOnly;
  final bool autofocus;
  final bool obscureText;
  final bool? autocorrect;
  final bool enableSuggestions;
  final int? maxLines;
  final int? minLines;
  final int? maxLength;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final List<TextInputFormatter>? inputFormatters;
  final bool? enabled;
  final Iterable<String>? autofillHints;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    return AppTextSelection.editable(
      TextField(
        contextMenuBuilder: AppTextSelection.editableMenu,
        controller: controller,
        focusNode: focusNode,
        decoration: decoration,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        textCapitalization: textCapitalization,
        style: style,
        textAlign: textAlign,
        textAlignVertical: textAlignVertical,
        readOnly: readOnly,
        autofocus: autofocus,
        obscureText: obscureText,
        autocorrect: autocorrect,
        enableSuggestions: enableSuggestions,
        maxLines: maxLines,
        minLines: minLines,
        maxLength: maxLength,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        inputFormatters: inputFormatters,
        enabled: enabled,
        autofillHints: autofillHints,
        scrollController: scrollController,
      ),
    );
  }
}

class AppTextFormField extends StatelessWidget {
  const AppTextFormField({
    super.key,
    this.initialValue,
    this.keyboardType,
    this.textAlign = TextAlign.start,
    this.decoration = const InputDecoration(),
    this.onFieldSubmitted,
  });

  final String? initialValue;
  final TextInputType? keyboardType;
  final TextAlign textAlign;
  final InputDecoration? decoration;
  final ValueChanged<String>? onFieldSubmitted;

  @override
  Widget build(BuildContext context) {
    return AppTextSelection.editable(
      TextFormField(
        contextMenuBuilder: AppTextSelection.editableMenu,
        initialValue: initialValue,
        keyboardType: keyboardType,
        textAlign: textAlign,
        decoration: decoration,
        onFieldSubmitted: onFieldSubmitted,
      ),
    );
  }
}
