import 'package:flutter/material.dart';

class MultilineContentField extends StatelessWidget {
  const MultilineContentField({
    super.key,
    required this.controller,
    this.labelText,
    this.hintText,
    this.minLines = 4,
    this.maxLines = 8,
  });

  final TextEditingController controller;
  final String? labelText;
  final String? hintText;
  final int minLines;
  final int maxLines;

  static const BorderRadius _radius = BorderRadius.all(Radius.circular(16));

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return TextField(
      controller: controller,
      minLines: minLines,
      maxLines: maxLines,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      decoration: InputDecoration(
        labelText: labelText,
        hintText: hintText,
        alignLabelWithHint: true,
        border: const OutlineInputBorder(borderRadius: _radius),
        enabledBorder: OutlineInputBorder(
          borderRadius: _radius,
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: _radius,
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
      ),
    );
  }
}
