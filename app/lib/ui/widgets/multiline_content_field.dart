import 'package:flutter/material.dart';

import '../theme.dart';
import 'app_text_field.dart';

class MultilineContentField extends StatefulWidget {
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

  @override
  State<MultilineContentField> createState() => _MultilineContentFieldState();
}

class _MultilineContentFieldState extends State<MultilineContentField> {
  static const double _cornerRadius = 16;
  static const BorderRadius _radius = BorderRadius.all(
    Radius.circular(_cornerRadius),
  );
  // 1 像素描边外加 1 像素间隙，拇指才不会压住右侧描边
  static const double _borderInset = 2;
  static const EdgeInsets _contentPadding = EdgeInsets.fromLTRB(
    12,
    8,
    AppTheme.overlayScrollGutter,
    8,
  );

  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    final Widget field = Stack(
      children: <Widget>[
        ScrollConfiguration(
          // EditableText 多行时会自己 copyWith(scrollbars: true) 把滚动条要回去，
          // 只有让 behavior 不画才拦得住；它画在文字右缘，还罩在输入框的 I 形光标里。
          behavior: const _NoEditableScrollbar(),
          child: AppTextField(
            controller: widget.controller,
            scrollController: _scroll,
            minLines: widget.minLines,
            maxLines: widget.maxLines,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
              labelText: widget.labelText,
              hintText: widget.hintText,
              alignLabelWithHint: true,
              contentPadding: _contentPadding,
              border: const OutlineInputBorder(borderRadius: _radius),
              enabledBorder: OutlineInputBorder(
                borderRadius: _radius,
                borderSide: BorderSide(color: scheme.outlineVariant),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: _radius,
                borderSide: BorderSide(color: scheme.primary),
              ),
            ),
          ),
        ),
        // 输入框整块套着 I 形光标的 MouseRegion，滚动条落在它上面。这条盖在前面把
        // 指针改回箭头，translucent 让点击仍能落到下面的输入框。
        const Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: AppTheme.overlayScrollGutter,
          child: MouseRegion(
            cursor: SystemMouseCursors.basic,
            hitTestBehavior: HitTestBehavior.translucent,
          ),
        ),
      ],
    );

    final ScrollbarThemeData bar = AppTheme.scrollbarInsideRadius(
      theme,
      _cornerRadius,
      inset: _borderInset,
    );
    // ScrollbarPainter 按文字视口高度排轨道，拇指却画在整个外框上；视口比外框矮了上下内边距，
    // 两端让位改由 padding 给并在底端扣掉这段，拇指到顶、到底离描边才相等
    final double viewportShortfall =
        _contentPadding.vertical + theme.visualDensity.baseSizeAdjustment.dy;
    final MediaQueryData media = MediaQuery.of(context);
    return ScrollbarTheme(
      data: bar.copyWith(mainAxisMargin: 0),
      child: MediaQuery(
        data: media.copyWith(
          padding: EdgeInsets.only(
            top: bar.mainAxisMargin!,
            bottom: bar.mainAxisMargin! - viewportShortfall,
          ),
        ),
        child: ScrollConfiguration.of(context).buildScrollbar(
          context,
          MediaQuery(data: media, child: field),
          ScrollableDetails.vertical(controller: _scroll),
        ),
      ),
    );
  }
}

class _NoEditableScrollbar extends MaterialScrollBehavior {
  const _NoEditableScrollbar();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}
