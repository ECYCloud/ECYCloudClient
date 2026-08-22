import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'zoom_cursors.dart';
import '../../l10n/l10n.dart';

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

  final TransformationController _transform = TransformationController();

  late int _index = widget.index;
  int _quarterTurns = 0;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).pop();

  void _step(int delta) {
    final int count = widget.images.length;
    if (count < 2) {
      return;
    }
    _transform.value = Matrix4.identity();
    setState(() => _index = (_index + delta + count) % count);
  }

  @override
  Widget build(BuildContext context) {
    final bool multi = widget.images.length > 1;

    return Scaffold(
      backgroundColor: Colors.black,
      body: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): _close,
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
                  child: MouseRegion(
                    cursor: ZoomCursors.zoomOut,
                    child: InteractiveViewer(
                      transformationController: _transform,
                      maxScale: _maxScale,
                      clipBehavior: Clip.hardEdge,
                      child: LayoutBuilder(
                        builder:
                            (BuildContext context, BoxConstraints constraints) {
                              // 按视口解码，避免原图像素进 GPU 导致缩放卡顿
                              final double dpr = MediaQuery.devicePixelRatioOf(
                                context,
                              );
                              final int cacheW =
                                  (constraints.maxWidth * dpr * 2).round();
                              final int cacheH =
                                  (constraints.maxHeight * dpr * 2).round();
                              final String url = widget.images[_index];
                              return GestureDetector(
                                onTap: _close,
                                child: RotatedBox(
                                  quarterTurns: _quarterTurns,
                                  child: Image(
                                    key: ValueKey<String>(url),
                                    image: ResizeImage(
                                      NetworkImage(url),
                                      width: cacheW,
                                      height: cacheH,
                                      policy: ResizeImagePolicy.fit,
                                    ),
                                    fit: BoxFit.contain,
                                    filterQuality: FilterQuality.low,
                                    gaplessPlayback: true,
                                    frameBuilder:
                                        (
                                          BuildContext context,
                                          Widget child,
                                          int? frame,
                                          bool sync,
                                        ) => sync || frame != null
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
                              );
                            },
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 12,
                  right: 12,
                  child: _button(
                    icon: Icons.close,
                    tooltip: L10n.t('关闭'),
                    onPressed: _close,
                  ),
                ),
                if (multi)
                  Positioned(
                    top: 12,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            child: Text(
                              '${_index + 1} / ${widget.images.length}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: _button(
                    icon: Icons.chevron_left,
                    tooltip: L10n.t('上一张'),
                    onPressed: multi ? () => _step(-1) : null,
                  ),
                ),
                Positioned(
                  bottom: 12,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: _button(
                      icon: Icons.refresh,
                      tooltip: L10n.t('旋转'),
                      onPressed: () => setState(() => _quarterTurns++),
                    ),
                  ),
                ),
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: _button(
                    icon: Icons.chevron_right,
                    tooltip: L10n.t('下一张'),
                    onPressed: multi ? () => _step(1) : null,
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
    // Material 保证叠在全屏图之上时仍能稳定接到点击（对齐网站 nav-btn 的 stopPropagation）
    return Material(
      type: MaterialType.transparency,
      child: IconButton(
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
      ),
    );
  }
}
