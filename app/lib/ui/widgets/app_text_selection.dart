import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

// 页面、滚动区和单元格各持有选区，不能因祖先已有选区而合并。
class AppTextSelection extends StatefulWidget {
  const AppTextSelection({super.key, required this.child});

  final Widget child;

  @override
  State<AppTextSelection> createState() => _AppTextSelectionState();

  static Widget editable(Widget child) {
    return SelectionContainer.disabled(
      child: Actions(
        actions: <Type, Action<Intent>>{
          // Flutter 3.47 输入框用宽类型实现上下移动，不能经过正文选区的窄类型转发。
          ExtendSelectionVerticallyToAdjacentLineIntent:
              _VerticalEditingAction(),
        },
        child: Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.keyY, control: true):
                RedoTextIntent(SelectionChangedCause.keyboard),
          },
          child: child,
        ),
      ),
    );
  }

  static Widget regionMenu(BuildContext context, SelectableRegionState state) {
    return _menu(state.contextMenuAnchors, state.contextMenuButtonItems);
  }

  static Widget editableMenu(BuildContext context, EditableTextState state) {
    return _menu(state.contextMenuAnchors, state.contextMenuButtonItems);
  }

  static Widget _menu(
    TextSelectionToolbarAnchors anchors,
    List<ContextMenuButtonItem> items,
  ) {
    items = items
        .where((item) => item.type != ContextMenuButtonType.selectAll)
        .toList();
    if (items.isEmpty) return const SizedBox.shrink();
    return _ThemedSelectionToolbar(anchors: anchors, items: items);
  }
}

class _AppTextSelectionState extends State<AppTextSelection> {
  final FocusNode _focusNode = FocusNode(skipTraversal: true);
  final GlobalKey<SelectionAreaState> _selectionKey =
      GlobalKey<SelectionAreaState>();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChanged);
  }

  void _handleFocusChanged() {
    final FocusNode? primary = FocusManager.instance.primaryFocus;
    // 切到其他应用时焦点暂挂在根节点，保留选区供返回后继续复制。
    if (primary == null || primary == FocusManager.instance.rootScope) return;
    // hasFocus 包含子选区；只有当前直接接收输入的选区可以保留高亮。
    if (!_focusNode.hasPrimaryFocus) {
      _selectionKey.currentState?.selectableRegion.clearSelection();
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (PointerDownEvent event) {
        if (event.buttons != kSecondaryMouseButton) return;
        // 等本次事件分发完再确定右键归属，防止外层选区的 tap-down 超时先抢走输入框焦点。
        scheduleMicrotask(
          () => GestureBinding.instance.gestureArena.sweep(event.pointer),
        );
      },
      child: SelectionArea(
        key: _selectionKey,
        focusNode: _focusNode,
        onSelectionChanged: (SelectedContent? content) {
          // 按住或连击时，父选区可能先取得焦点；实际选区产生后同步归属。
          if (content != null && content.plainText.isNotEmpty) {
            _focusNode.requestFocus();
          }
        },
        contextMenuBuilder: AppTextSelection.regionMenu,
        child: widget.child,
      ),
    );
  }
}

class _VerticalEditingAction extends Action<DirectionalCaretMovementIntent> {
  @override
  Object? invoke(DirectionalCaretMovementIntent intent) =>
      callingAction?.invoke(intent);
}

class _ThemedSelectionToolbar extends StatelessWidget {
  const _ThemedSelectionToolbar({required this.anchors, required this.items});

  static const double _screenPadding = 8;

  final TextSelectionToolbarAnchors anchors;
  final List<ContextMenuButtonItem> items;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PopupMenuThemeData popup = theme.popupMenuTheme;
    final double paddingAbove =
        MediaQuery.paddingOf(context).top + _screenPadding;
    final Offset origin = Offset(_screenPadding, paddingAbove);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        _screenPadding,
        paddingAbove,
        _screenPadding,
        _screenPadding,
      ),
      child: CustomSingleChildLayout(
        delegate: DesktopTextSelectionToolbarLayoutDelegate(
          anchor: anchors.primaryAnchor - origin,
        ),
        child: Material(
          color: popup.color ?? theme.colorScheme.surface,
          elevation: popup.elevation ?? 8,
          shadowColor: theme.shadowColor,
          shape:
              popup.shape ??
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTheme.menuRadius),
              ),
          clipBehavior: Clip.antiAlias,
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final ContextMenuButtonItem item in items)
                  TextButton(
                    style: ButtonStyle(
                      visualDensity: theme.visualDensity,
                      side: const WidgetStatePropertyAll<BorderSide>(
                        BorderSide.none,
                      ),
                      alignment: Alignment.centerLeft,
                      padding: const WidgetStatePropertyAll<EdgeInsets>(
                        EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      ),
                      shape: WidgetStatePropertyAll<OutlinedBorder>(
                        RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            AppTheme.tileRadius,
                          ),
                        ),
                      ),
                      overlayColor: WidgetStatePropertyAll<Color>(
                        theme.colorScheme.primary.withValues(alpha: 0.08),
                      ),
                      foregroundColor: WidgetStatePropertyAll<Color>(
                        theme.colorScheme.onSurface,
                      ),
                      textStyle: WidgetStatePropertyAll<TextStyle>(
                        theme.textTheme.bodyMedium!,
                      ),
                    ),
                    onPressed: item.onPressed,
                    child: Text(
                      AdaptiveTextSelectionToolbar.getButtonLabel(
                        context,
                        item,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
