import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<void> showImageViewer(
  BuildContext context, {
  required List<String> images,
  required int index,
}) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder:
          (
            BuildContext context,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
          ) => _ImageViewerPage(images: images, index: index),
      transitionsBuilder:
          (
            BuildContext context,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
            Widget child,
          ) => FadeTransition(opacity: animation, child: child),
    ),
  );
}

class _ImageViewerPage extends StatefulWidget {
  const _ImageViewerPage({required this.images, required this.index});

  final List<String> images;
  final int index;

  @override
  State<_ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<_ImageViewerPage> {
  static const double _maxScale = 5;
  static const double _doubleTapScale = 2;

  final TransformationController _transform = TransformationController();

  late int _index = widget.index;
  int _quarterTurns = 0;
  Offset _doubleTapAt = Offset.zero;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  bool get _zoomed => _transform.value.getMaxScaleOnAxis() > 1;

  void _step(int delta) {
    final int count = widget.images.length;
    if (count < 2) {
      return;
    }
    _transform.value = Matrix4.identity();
    setState(() => _index = (_index + delta + count) % count);
  }

  void _toggleZoom() {
    if (_zoomed) {
      _transform.value = Matrix4.identity();
      return;
    }
    _transform.value =
        Matrix4.diagonal3Values(_doubleTapScale, _doubleTapScale, 1)
          ..setTranslationRaw(
            _doubleTapAt.dx * (1 - _doubleTapScale),
            _doubleTapAt.dy * (1 - _doubleTapScale),
            0,
          );
  }

  void _tap() {
    if (_zoomed) {
      _transform.value = Matrix4.identity();
      setState(() => _quarterTurns = 0);
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final bool multi = widget.images.length > 1;

    return Scaffold(
      backgroundColor: Colors.black,
      body: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).pop(),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _step(-1),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _step(1),
        },
        // CallbackShortcuts 只在焦点落在子树内时响应，去掉 autofocus 键盘操作即失效
        child: Focus(
          autofocus: true,
          child: SafeArea(
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _tap,
                    onDoubleTapDown: (TapDownDetails details) =>
                        _doubleTapAt = details.localPosition,
                    onDoubleTap: _toggleZoom,
                    child: InteractiveViewer(
                      transformationController: _transform,
                      maxScale: _maxScale,
                      child: RotatedBox(
                        quarterTurns: _quarterTurns,
                        child: Image.network(
                          widget.images[_index],
                          fit: BoxFit.contain,
                          loadingBuilder:
                              (
                                BuildContext context,
                                Widget child,
                                ImageChunkEvent? progress,
                              ) => progress == null
                              ? child
                              : const Center(
                                  child: SizedBox(
                                    width: 28,
                                    height: 28,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white70,
                                    ),
                                  ),
                                ),
                          errorBuilder:
                              (
                                BuildContext context,
                                Object error,
                                StackTrace? stack,
                              ) => const Center(
                                child: Icon(
                                  Icons.broken_image_outlined,
                                  size: 40,
                                  color: Colors.white54,
                                ),
                              ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 12,
                  right: 12,
                  child: _button(
                    icon: Icons.close,
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      _button(
                        icon: Icons.chevron_left,
                        tooltip: '上一张',
                        onPressed: multi ? () => _step(-1) : null,
                      ),
                      _button(
                        icon: Icons.rotate_right,
                        tooltip: '旋转',
                        onPressed: () => setState(() => _quarterTurns++),
                      ),
                      _button(
                        icon: Icons.chevron_right,
                        tooltip: '下一张',
                        onPressed: multi ? () => _step(1) : null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _button({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon),
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white24,
        iconSize: 22,
        fixedSize: const Size.square(44),
      ),
    );
  }
}
