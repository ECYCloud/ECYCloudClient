import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../theme.dart';
import 'app_text_field.dart';

class SearchField extends StatefulWidget {
  const SearchField({
    super.key,
    required this.onChanged,
    this.hintText,
    this.width = 220,
    this.controller,
    this.focusNode,
  });

  final ValueChanged<String> onChanged;
  final String? hintText;
  final double width;
  final TextEditingController? controller;
  final FocusNode? focusNode;

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  TextEditingController? _owned;

  TextEditingController get _controller => widget.controller ?? _owned!;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _owned = TextEditingController();
    }
  }

  @override
  void dispose() {
    _owned?.dispose();
    super.dispose();
  }

  void _clear() {
    _controller.clear();
    widget.onChanged('');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: widget.width,
      height: 30,
      child: AppTheme.withControlDensity(
        AppTextField(
          controller: _controller,
          focusNode: widget.focusNode,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 12),
          onChanged: (String value) {
            widget.onChanged(value);
            setState(() {});
          },
          decoration: InputDecoration(
            hintText: widget.hintText ?? L10n.t('搜索'),
            constraints: const BoxConstraints.tightFor(height: 30),
            prefixIcon: Icon(Icons.search, size: 15, color: scheme.outline),
            prefixIconConstraints: const BoxConstraints.tightFor(
              width: 30,
              height: 30,
            ),
            suffixIcon: _controller.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close, size: 14),
                    onPressed: _clear,
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints.tightFor(
                      width: 26,
                      height: 26,
                    ),
                  ),
            suffixIconConstraints: const BoxConstraints.tightFor(
              width: 30,
              height: 30,
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
          ),
        ),
      ),
    );
  }
}
