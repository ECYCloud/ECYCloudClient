import 'package:flutter/material.dart';

import '../theme.dart';
import 'app_text_selection.dart';

// TextField / EditableText 自带滚动条会盖住文字，且悬停是 I 形光标
class OverlayScrollView extends StatelessWidget {
  const OverlayScrollView({
    super.key,
    required this.child,
    this.controller,
    this.scrollDirection = Axis.vertical,
    this.padding,
    this.physics,
    this.shrinkWrap = false,
  });

  final Widget child;
  final ScrollController? controller;
  final Axis scrollDirection;
  final EdgeInsets? padding;
  final ScrollPhysics? physics;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    final EdgeInsets pad = AppTheme.overlayGutterOf(
      padding,
      axis: scrollDirection,
    );
    return AppTextSelection(
      child: shrinkWrap
          ? ListView(
              controller: controller,
              scrollDirection: scrollDirection,
              padding: pad,
              physics: physics,
              shrinkWrap: true,
              primary: false,
              children: <Widget>[child],
            )
          : SingleChildScrollView(
              controller: controller,
              scrollDirection: scrollDirection,
              padding: pad,
              physics: physics,
              child: child,
            ),
    );
  }
}
