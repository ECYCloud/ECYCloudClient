import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import '../theme.dart';

/// 列表页通用搜索框。受控用法：由调用方持有关键词，本组件只负责输入与清除。
class SearchField extends StatefulWidget {
  const SearchField({
    super.key,
    required this.onChanged,
    this.hintText,
    this.width = 220,
  });

  final ValueChanged<String> onChanged;
  final String? hintText;
  final double width;

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
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

    final double fieldHeight = AppTheme.touchDevice
        ? kMinInteractiveDimension
        : 30;
    return SizedBox(
      width: widget.width,
      height: fieldHeight,
      child: TextField(
        controller: _controller,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 12),
        onChanged: (String value) {
          widget.onChanged(value);
          setState(() {});
        },
        decoration: InputDecoration(
          hintText: widget.hintText ?? L10n.t('搜索'),
          prefixIcon: Icon(Icons.search, size: 15, color: scheme.outline),
          prefixIconConstraints: BoxConstraints.tightFor(
            width: fieldHeight,
            height: fieldHeight,
          ),
          suffixIcon: _controller.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 14),
                  onPressed: _clear,
                  padding: EdgeInsets.zero,
                  visualDensity: AppTheme.iconActionDensity,
                  constraints: AppTheme.iconActionBox(compact: 26),
                ),
          suffixIconConstraints: BoxConstraints.tightFor(
            width: fieldHeight,
            height: fieldHeight,
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 6),
        ),
      ),
    );
  }
}
