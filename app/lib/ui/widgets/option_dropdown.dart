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
  });

  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;
  final double width;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle style =
        theme.textTheme.bodyMedium ?? const TextStyle(fontSize: 13);

    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      style: MenuStyle(
        padding: const WidgetStatePropertyAll<EdgeInsets>(
          EdgeInsets.symmetric(vertical: 4),
        ),
        minimumSize: WidgetStatePropertyAll<Size>(Size(width, 0)),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.tileRadius),
          ),
        ),
      ),
      menuChildren: <Widget>[
        for (final MapEntry<T, String> entry in options.entries)
          MenuItemButton(
            onPressed: () => onChanged(entry.key),
            style: MenuItemButton.styleFrom(
              minimumSize: Size(width, 32),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              textStyle: style,
              foregroundColor: entry.key == value
                  ? scheme.primary
                  : scheme.onSurface,
              backgroundColor: entry.key == value
                  ? scheme.primary.withValues(alpha: 0.08)
                  : null,
            ),
            child: Text(entry.value),
          ),
      ],
      builder:
          (BuildContext context, MenuController controller, Widget? child) {
            final bool open = controller.isOpen;

            return InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => open ? controller.close() : controller.open(),
              child: Container(
                width: width,
                height: 30,
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
                      child: Text(
                        options[value] ?? '',
                        style: style,
                        overflow: TextOverflow.ellipsis,
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
