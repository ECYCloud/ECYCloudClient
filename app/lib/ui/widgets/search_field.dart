import 'package:flutter/material.dart';

/// 列表页通用搜索框。受控用法：由调用方持有关键词，本组件只负责输入与清除。
class SearchField extends StatefulWidget {
  const SearchField({
    super.key,
    required this.onChanged,
    this.hintText = '搜索',
    this.width = 220,
  });

  final ValueChanged<String> onChanged;
  final String hintText;
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

    return SizedBox(
      width: widget.width,
      height: 30,
      child: TextField(
        controller: _controller,
        style: const TextStyle(fontSize: 12),
        onChanged: (String value) {
          widget.onChanged(value);
          setState(() {});
        },
        decoration: InputDecoration(
          hintText: widget.hintText,
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
    );
  }
}
