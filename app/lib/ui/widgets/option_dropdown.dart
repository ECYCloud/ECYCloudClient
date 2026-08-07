import 'package:flutter/material.dart';

import '../theme.dart';

/// 设置项里的下拉选择。
///
/// 不用 [DropdownButton]：它按 Material 2 的规则把菜单对齐到选中项，菜单会盖住按钮本身；
/// 而且选中态与弹出项分别由 `selectedItemBuilder` 与 `items` 渲染，两处样式容易写歪。
/// 这里用 [MenuAnchor]，菜单落在胶囊下方，收起态与选项共用同一份文本样式。
class OptionDropdown<T> extends StatelessWidget {
  const OptionDropdown({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.width = 116,
    this.height = 30,
    this.enabled = true,
    this.placeholder = '',
    this.maxMenuHeight = 320,
    this.itemLeading,
    this.itemTrailing,
    this.selectedLeading,
    this.selectedTrailing,
  });

  final T? value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;
  final double width;
  final double height;
  final bool enabled;
  final String placeholder;
  final double maxMenuHeight;
  final Widget? Function(T value)? itemLeading;
  final Widget? Function(T value)? itemTrailing;
  final Widget? selectedLeading;
  final Widget? selectedTrailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle style = theme.textTheme.bodyMedium!;
    final String label = value == null
        ? placeholder
        : (options[value as T] ?? placeholder);

    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      style: MenuStyle(
        padding: const WidgetStatePropertyAll<EdgeInsets>(
          EdgeInsets.symmetric(vertical: 4),
        ),
        minimumSize: WidgetStatePropertyAll<Size>(Size(width, 0)),
        maximumSize: WidgetStatePropertyAll<Size>(Size(width, maxMenuHeight)),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.tileRadius),
          ),
        ),
      ),
      menuChildren: <Widget>[
        for (final MapEntry<T, String> entry in options.entries)
          MenuItemButton(
            onPressed: enabled ? () => onChanged(entry.key) : null,
            style: MenuItemButton.styleFrom(
              minimumSize: Size(width, height),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              textStyle: style,
              foregroundColor: entry.key == value
                  ? scheme.primary
                  : scheme.onSurface,
              backgroundColor: entry.key == value
                  ? scheme.primary.withValues(alpha: 0.08)
                  : null,
            ),
            child: _OptionRow(
              label: entry.value,
              leading: itemLeading?.call(entry.key),
              trailing: itemTrailing?.call(entry.key),
              style: style,
            ),
          ),
      ],
      builder:
          (BuildContext context, MenuController controller, Widget? child) {
            final bool open = controller.isOpen;

            return InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: enabled
                  ? () => open ? controller.close() : controller.open()
                  : null,
              child: Container(
                width: width,
                height: height,
                padding: const EdgeInsets.only(left: 12, right: 6),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: open ? scheme.primary : scheme.outlineVariant,
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: _OptionRow(
                        label: label,
                        leading: selectedLeading,
                        trailing: selectedTrailing,
                        style: style.copyWith(
                          color: value == null
                              ? scheme.onSurfaceVariant
                              : null,
                        ),
                      ),
                    ),
                    AnimatedRotation(
                      turns: open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: Icon(
                        Icons.expand_more,
                        size: 16,
                        color: open ? scheme.primary : scheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.label,
    required this.style,
    this.leading,
    this.trailing,
  });

  final String label;
  final TextStyle style;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      if (leading != null) ...<Widget>[leading!, const SizedBox(width: 6)],
      Expanded(
        child: Text(label, style: style, overflow: TextOverflow.ellipsis),
      ),
      if (trailing != null) ...<Widget>[const SizedBox(width: 8), trailing!],
    ],
  );
}
