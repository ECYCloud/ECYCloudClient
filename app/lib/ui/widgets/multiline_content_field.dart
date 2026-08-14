import 'package:flutter/material.dart';

/// 多行内容框：圆角矩形外壳 + 独立滚动轨道（与全局胶囊形单行 InputDecoration 区分）。
/// 工单内容、配置策略 Host/规则等共用。
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
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    const BorderRadius radius = BorderRadius.all(Radius.circular(16));
    final String? label = widget.labelText;
    final String? hint = widget.hintText;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: radius,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: ScrollConfiguration(
                  behavior: const _NoScrollbarBehavior(),
                  child: TextField(
                    controller: widget.controller,
                    scrollController: _scroll,
                    minLines: widget.minLines,
                    maxLines: widget.maxLines,
                    decoration: InputDecoration(
                      labelText: label,
                      hintText: hint,
                      alignLabelWithHint: label != null,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      contentPadding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                    ),
                  ),
                ),
              ),
              MouseRegion(
                cursor: SystemMouseCursors.basic,
                child: _ScrollRail(controller: _scroll),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoScrollbarBehavior extends MaterialScrollBehavior {
  const _NoScrollbarBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

/// 独立滚动轨道：占位+拖拽，不参与 TextField 的文本命中测试。
class _ScrollRail extends StatelessWidget {
  const _ScrollRail({required this.controller});

  static const double _width = 14;

  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, _) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (TapDownDetails details) =>
              _jumpTo(details.localPosition.dy),
          onVerticalDragUpdate: (DragUpdateDetails details) {
            if (!controller.hasClients) {
              return;
            }
            final ScrollPosition pos = controller.position;
            if (pos.maxScrollExtent <= 0 || pos.viewportDimension <= 0) {
              return;
            }
            final double view = pos.viewportDimension;
            final double thumbH = _thumbHeight(pos);
            final double travel = (view - thumbH).clamp(1.0, view);
            final double delta =
                details.delta.dy / travel * pos.maxScrollExtent;
            controller.jumpTo(
              (pos.pixels + delta).clamp(0.0, pos.maxScrollExtent),
            );
          },
          child: SizedBox(
            width: _width,
            child: CustomPaint(
              painter: _RailPainter(
                controller: controller,
                trackColor: scheme.outlineVariant.withValues(alpha: 0.35),
                thumbColor: scheme.outline.withValues(alpha: 0.55),
              ),
            ),
          ),
        );
      },
    );
  }

  void _jumpTo(double localDy) {
    if (!controller.hasClients) {
      return;
    }
    final ScrollPosition pos = controller.position;
    if (pos.maxScrollExtent <= 0 || pos.viewportDimension <= 0) {
      return;
    }
    final double view = pos.viewportDimension;
    final double thumbH = _thumbHeight(pos);
    final double travel = (view - thumbH).clamp(1.0, view);
    final double ratio = ((localDy - thumbH / 2) / travel).clamp(0.0, 1.0);
    controller.jumpTo(ratio * pos.maxScrollExtent);
  }

  static double _thumbHeight(ScrollPosition pos) {
    final double view = pos.viewportDimension;
    final double extent = view + pos.maxScrollExtent;
    if (extent <= 0) {
      return view;
    }
    return (view / extent * view).clamp(24.0, view);
  }
}

class _RailPainter extends CustomPainter {
  _RailPainter({
    required this.controller,
    required this.trackColor,
    required this.thumbColor,
  });

  final ScrollController controller;
  final Color trackColor;
  final Color thumbColor;

  @override
  void paint(Canvas canvas, Size size) {
    final RRect track = RRect.fromRectAndRadius(
      Rect.fromLTWH(4, 4, size.width - 8, size.height - 8),
      const Radius.circular(4),
    );
    canvas.drawRRect(track, Paint()..color = trackColor);

    if (!controller.hasClients) {
      return;
    }
    final ScrollPosition pos = controller.position;
    if (!pos.hasContentDimensions || pos.maxScrollExtent <= 0) {
      return;
    }
    final double view = pos.viewportDimension;
    if (view <= 0 || size.height <= 0) {
      return;
    }
    final double thumbH = _ScrollRail._thumbHeight(pos);
    final double travel = (size.height - 8 - thumbH).clamp(0.0, size.height);
    final double top =
        4 +
        (pos.maxScrollExtent <= 0
            ? 0.0
            : (pos.pixels / pos.maxScrollExtent) * travel);
    final RRect thumb = RRect.fromRectAndRadius(
      Rect.fromLTWH(4, top, size.width - 8, thumbH),
      const Radius.circular(4),
    );
    canvas.drawRRect(thumb, Paint()..color = thumbColor);
  }

  @override
  bool shouldRepaint(covariant _RailPainter oldDelegate) => true;
}
