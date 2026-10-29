import 'package:flutter/material.dart';

import '../theme.dart';

class OptionDropdown<T> extends StatefulWidget {
  const OptionDropdown({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.width = AppTheme.controlWidth,
    this.height = AppTheme.controlHeight,
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
  State<OptionDropdown<T>> createState() => _OptionDropdownState<T>();
}

class _OptionDropdownState<T> extends State<OptionDropdown<T>> {
  // MenuAnchor 靠 childFocusNode 认这个触发器：不给它，菜单收起后焦点无处可去，
  // 遥控器之后按任何方向键都没有反应
  final FocusNode _trigger = FocusNode();

  @override
  void dispose() {
    _trigger.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle style = theme.textTheme.bodyMedium!;
    final T? value = widget.value;
    final Map<T, String> options = widget.options;
    final double width = widget.width;
    final double height = widget.height;
    final bool enabled = widget.enabled;
    final String label = value == null
        ? widget.placeholder
        : (options[value] ?? widget.placeholder);

    // 菜单自己是一个 FocusScope，方向键进不去，必须开菜单时就把焦点放进某一项
    final T? entryFocus = options.containsKey(value)
        ? value
        : (options.isEmpty ? null : options.keys.first);

    final BorderRadius menuRadius = BorderRadius.circular(AppTheme.menuRadius);
    final double menuHeight = height * options.length > widget.maxMenuHeight
        ? widget.maxMenuHeight
        : height * options.length;

    return SizedBox(
      width: width,
      child: ScrollbarTheme(
        data: AppTheme.scrollbarInsideRadius(theme, AppTheme.menuRadius),
        child: MenuAnchor(
          childFocusNode: _trigger,
          crossAxisUnconstrained: false,
          clipBehavior: Clip.antiAlias,
          style: MenuStyle(
            alignment: AlignmentDirectional.bottomStart,
            padding: const WidgetStatePropertyAll<EdgeInsets>(EdgeInsets.zero),
            visualDensity: VisualDensity.standard,
            minimumSize: WidgetStatePropertyAll<Size>(Size(width, menuHeight)),
            maximumSize: WidgetStatePropertyAll<Size>(Size(width, menuHeight)),
            shape: WidgetStatePropertyAll<OutlinedBorder>(
              RoundedRectangleBorder(borderRadius: menuRadius),
            ),
          ),
          menuChildren: <Widget>[
            for (final (int index, MapEntry<T, String> entry)
                in options.entries.indexed)
              SizedBox(
                width: width,
                height: height,
                child: MenuItemButton(
                  autofocus: entry.key == entryFocus,
                  onPressed: enabled ? () => widget.onChanged(entry.key) : null,
                  style: MenuItemButton.styleFrom(
                    minimumSize: Size(width, height),
                    fixedSize: Size(width, height),
                    maximumSize: Size(width, height),
                    padding: const EdgeInsets.fromLTRB(
                      12,
                      0,
                      AppTheme.overlayScrollGutter,
                      0,
                    ),
                    alignment: Alignment.centerLeft,
                    visualDensity: VisualDensity.standard,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(
                      borderRadius: _itemRadius(
                        menuRadius,
                        index: index,
                        length: options.length,
                      ),
                    ),
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
                    leading: widget.itemLeading?.call(entry.key),
                    trailing: widget.itemTrailing?.call(entry.key),
                    style: style,
                  ),
                ),
              ),
          ],
          builder:
              (BuildContext context, MenuController controller, Widget? child) {
                final bool open = controller.isOpen;

                return InkWell(
                  focusNode: _trigger,
                  borderRadius: BorderRadius.circular(999),
                  onTap: enabled
                      ? () {
                          if (open) {
                            controller.close();
                          } else {
                            controller.open(position: Offset(0, height + 4));
                          }
                        }
                      : null,
                  child: Container(
                    width: width,
                    height: height,
                    padding: const EdgeInsets.only(left: 12, right: 6),
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: open ? scheme.primary : scheme.outline,
                      ),
                    ),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: _OptionRow(
                            label: label,
                            leading: widget.selectedLeading,
                            trailing: widget.selectedTrailing,
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
        ),
      ),
    );
  }
}

BorderRadius _itemRadius(
  BorderRadius menuRadius, {
  required int index,
  required int length,
}) {
  if (length <= 1) {
    return menuRadius;
  }
  if (index == 0) {
    return BorderRadius.only(
      topLeft: menuRadius.topLeft,
      topRight: menuRadius.topRight,
    );
  }
  if (index == length - 1) {
    return BorderRadius.only(
      bottomLeft: menuRadius.bottomLeft,
      bottomRight: menuRadius.bottomRight,
    );
  }
  return BorderRadius.zero;
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
