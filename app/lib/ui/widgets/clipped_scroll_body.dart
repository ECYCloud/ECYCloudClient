import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import 'overlay_scroll_view.dart';

class ClippedScrollBody extends StatelessWidget {
  const ClippedScrollBody({super.key, required this.child});

  static const double maxHeight = 360;
  static const EdgeInsets padding = EdgeInsets.fromLTRB(
    10,
    8,
    AppTheme.overlayScrollGutter,
    8,
  );

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: maxHeight),
      // 内层滚到顶/底后 Scrollable 不再认领滚轮，事件会落到外层商店 ListView。
      child: NotificationListener<OverscrollNotification>(
        onNotification: (OverscrollNotification notification) => true,
        child: Listener(
          onPointerSignal: (PointerSignalEvent event) {
            if (event is PointerScrollEvent) {
              GestureBinding.instance.pointerSignalResolver.register(
                event,
                (PointerSignalEvent _) {},
              );
            }
          },
          child: OverlayScrollView(padding: padding, child: child),
        ),
      ),
    );
  }
}
