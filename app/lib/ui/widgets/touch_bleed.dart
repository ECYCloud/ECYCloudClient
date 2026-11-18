import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../theme.dart';

// 触控端小图标键的触控盒是 minTapTarget（48），桌面端是 32。直接按 48 排版，
// 图标两侧会多出各 8 的空白，和相邻元素的间距比桌面端宽一截。这里按桌面端尺寸
// 排版，触控盒向四周溢出，仍按 48 接收点击；溢出部分不占位，也不改变子组件大小。
// 桌面端子组件本来就是 extent 大小，原样透传。
class TouchBleed extends SingleChildRenderObjectWidget {
  const TouchBleed({
    super.key,
    this.extent = AppTheme.pointerTapTarget,
    this.clipWidth = true,
    required Widget super.child,
  });

  final double extent;
  // 宽度本就不小于 minTapTarget 的按钮（如文字按钮）横向没有触控补边，只收高度
  final bool clipWidth;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderTouchBleed(extent, clipWidth);

  @override
  void updateRenderObject(BuildContext context, RenderTouchBleed renderObject) {
    renderObject
      ..extent = extent
      ..clipWidth = clipWidth;
  }
}

class RenderTouchBleed extends RenderShiftedBox {
  RenderTouchBleed(this._extent, this._clipWidth) : super(null);

  double _extent;
  bool _clipWidth;

  set extent(double value) {
    if (value == _extent) {
      return;
    }
    _extent = value;
    markNeedsLayout();
  }

  set clipWidth(bool value) {
    if (value == _clipWidth) {
      return;
    }
    _clipWidth = value;
    markNeedsLayout();
  }

  double get _widthExtent => _clipWidth ? _extent : double.infinity;

  Size _clip(Size full, BoxConstraints constraints) => constraints.constrain(
    Size(math.min(full.width, _widthExtent), math.min(full.height, _extent)),
  );

  @override
  double computeMinIntrinsicWidth(double height) =>
      math.min(super.computeMinIntrinsicWidth(height), _widthExtent);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      math.min(super.computeMaxIntrinsicWidth(height), _widthExtent);

  @override
  double computeMinIntrinsicHeight(double width) =>
      math.min(super.computeMinIntrinsicHeight(width), _extent);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      math.min(super.computeMaxIntrinsicHeight(width), _extent);

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _clip(child!.getDryLayout(const BoxConstraints()), constraints);

  @override
  void performLayout() {
    final RenderBox child = this.child!;
    child.layout(const BoxConstraints(), parentUsesSize: true);
    final Size full = child.size;
    size = _clip(full, constraints);
    (child.parentData! as BoxParentData).offset = Offset(
      (size.width - full.width) / 2,
      (size.height - full.height) / 2,
    );
  }

  // 不按自身尺寸裁掉溢出的触控区
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (hitTestChildren(result, position: position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return false;
  }
}

// 自绘按压效果（InkWell）的小控件：按压轮廓两端都是子组件本身的大小，触控端
// 外围补成 minTapTarget 见方的点击区，与 Material 按钮的触控补边一致；
// 轮廓内的点击仍由子组件自己响应。
class TapPadding extends StatelessWidget {
  const TapPadding({super.key, required this.onTap, required this.child});

  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!AppTheme.isTouch) {
      return child;
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: AppTheme.minTapTarget,
          minHeight: AppTheme.minTapTarget,
        ),
        child: Center(widthFactor: 1, heightFactor: 1, child: child),
      ),
    );
  }
}
