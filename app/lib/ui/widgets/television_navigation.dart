import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

class TelevisionNavigation extends StatefulWidget {
  const TelevisionNavigation({super.key, required this.child});

  final Widget child;

  @override
  State<TelevisionNavigation> createState() => _TelevisionNavigationState();
}

class _TelevisionNavigationState extends State<TelevisionNavigation> {
  // Material 按钮把焦点节点放在视觉边框之内（40 高的按钮焦点盒只有 32），间距太小会把
  // 轮廓画进按钮里
  static const double _ringGap = 5;
  static const double _ringWidth = 3;
  static const double _ringMaxRadius = 16;

  final GlobalKey _layerKey = GlobalKey();

  Rect? _focused;
  bool _pending = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_scheduleSync);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_scheduleSync);
    super.dispose();
  }

  // 焦点会在 build / layout 期间变化，就地 setState 会抛「setState during build」；
  // 量取控件位置也必须等这一帧布局完成
  void _scheduleSync() {
    if (_pending) {
      return;
    }
    _pending = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      if (!mounted) {
        return;
      }
      final Rect? next = _measure();
      if (next != _focused) {
        setState(() => _focused = next);
      }
    });
  }

  Rect? _measure() {
    final RenderObject? node = FocusManager.instance.primaryFocus?.context
        ?.findRenderObject();
    final RenderObject? layer = _layerKey.currentContext?.findRenderObject();
    if (node is! RenderBox ||
        layer is! RenderBox ||
        !node.attached ||
        !node.hasSize ||
        !layer.hasSize) {
      return null;
    }

    final Rect rect = Rect.fromPoints(
      layer.globalToLocal(node.localToGlobal(Offset.zero)),
      layer.globalToLocal(
        node.localToGlobal(node.size.bottomRight(Offset.zero)),
      ),
    );
    // 页面在 SafeArea 里，整页大小要扣掉电视安全区边距
    final Rect viewport = MediaQuery.paddingOf(context)
        .deflateRect(Offset.zero & layer.size);
    // 焦点滚出可视区时不画；图片查看器那种包住整屏的 Focus 不是控件，描出来就是一圈屏幕边框；
    // 列表刚跳转时还没排版的项量出来是 NaN
    if (!rect.isFinite ||
        !rect.overlaps(viewport) ||
        (rect.width >= viewport.width && rect.height >= viewport.height)) {
      return null;
    }
    return rect;
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        ..._arrowShortcuts,
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              FocusManager.instance.primaryFocus?.context
                  ?.findAncestorStateOfType<EditableTextState>()
                  ?.requestKeyboard();
              return null;
            },
          ),
          _TelevisionMoveIntent: CallbackAction<_TelevisionMoveIntent>(
            onInvoke: (_TelevisionMoveIntent intent) {
              _moveOrScroll(intent.direction);
              return null;
            },
          ),
          // 菜单按钮（RawMenuAnchor）外层自带 Shortcuts，把方向键转成 DirectionalFocusIntent，
          // 不接住就落到全局默认的原生遍历；打开的菜单在自己的 FocusScope 里，同样只在菜单项间移动
          DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
            onInvoke: (DirectionalFocusIntent intent) {
              _moveOrScroll(intent.direction);
              return null;
            },
          ),
        },
        // 滚动会挪动已聚焦的控件，焦点本身没变，只能靠滚动通知重新量位置
        child: NotificationListener<ScrollNotification>(
          onNotification: (ScrollNotification notification) {
            _scheduleSync();
            return false;
          },
          child: Stack(
            key: _layerKey,
            fit: StackFit.passthrough,
            children: <Widget>[widget.child, ?_ring(context)],
          ),
        ),
      ),
    );
  }

  // 遥控器只有方向键，滚动全靠焦点移动带出来。整页最后一个可聚焦控件之后（连接明细、
  // 节点列表这类只有文本的区域）没有下一个落点，不补这一步列表就彻底滚不动
  void _moveOrScroll(TraversalDirection direction) {
    final FocusNode? node = FocusManager.instance.primaryFocus;
    final BuildContext? context = node?.context;
    if (node == null || context == null) {
      return;
    }
    final Axis axis = switch (direction) {
      TraversalDirection.up || TraversalDirection.down => Axis.vertical,
      TraversalDirection.left || TraversalDirection.right => Axis.horizontal,
    };
    final bool down = direction == TraversalDirection.down;
    final List<FocusNode> peers = _sameGroup(node).toList();
    // 页面里还没有控件获焦时（焦点在路由的 FocusScope 上），沿用 Flutter 取该方向第一个控件
    if (axis == Axis.horizontal || node is FocusScopeNode) {
      if (node.focusInDirection(direction)) {
        _hideKeyboardSoon();
        return;
      }
    } else {
      // 上下键不走 Flutter 遍历：它按输入框里的文字区判断同列，且只要同列有落点就不看近处的
      // 斜方向控件（齿轮按钮往下越过整张卡片），改按 Android FocusFinder 的口径在同组内选
      final FocusNode? next = _nearestAhead(node, down, peers);
      if (next != null) {
        _reveal(next, toEnd: down);
        return;
      }
    }
    if (_scrollBy(
          Scrollable.maybeOf(context, axis: axis)?.position,
          direction,
        ) ||
        _scrollBy(_unfocusableScrollable(node, axis)?.position, direction) ||
        axis == Axis.horizontal ||
        peers.isEmpty) {
      return;
    }
    _wrap(node, toTop: down);
  }

  // 输入框的焦点只占框内文字区，按整个输入框算位置才能和同列的按钮对齐；
  // 框内的后缀按钮（显示密码）仍按自身位置
  static Rect _rectOf(FocusNode node) {
    Rect rect = node.rect;
    bool text = false;
    node.context?.visitAncestorElements((Element element) {
      if (element.widget is EditableText) {
        text = true;
      } else if (element.widget is InputDecorator) {
        final RenderObject? box = element.renderObject;
        if (text && box is RenderBox && box.hasSize) {
          rect = box.localToGlobal(Offset.zero) & box.size;
        }
        return false;
      }
      return true;
    });
    return rect;
  }

  static TelevisionFocusSection? _group(FocusNode node) =>
      node.context?.findAncestorWidgetOfExactType<TelevisionFocusSection>();

  Iterable<FocusNode> _sameGroup(FocusNode node) {
    final TelevisionFocusSection? group = _group(node);
    return node.nearestScope?.traversalDescendants.where(
          (FocusNode other) => other != node && _group(other) == group,
        ) ??
        const <FocusNode>[];
  }

  // 对应 Android FocusFinder：正前方（横向重叠）的候选优先，除非斜方向的候选整体更近；
  // 其余按 13 × 纵向距离² + 横向距离² 取最小
  FocusNode? _nearestAhead(
    FocusNode node,
    bool down,
    Iterable<FocusNode> candidates,
  ) {
    final Rect origin = _rectOf(node);
    bool ahead(Rect rect) => down
        ? (origin.top < rect.top || origin.bottom <= rect.top) &&
              origin.bottom < rect.bottom
        : (origin.bottom > rect.bottom || origin.top >= rect.bottom) &&
              origin.top > rect.top;
    bool inBeam(Rect rect) =>
        rect.right > origin.left && rect.left < origin.right;
    double major(Rect rect) =>
        max(0, down ? rect.top - origin.bottom : origin.top - rect.bottom);
    double majorFar(Rect rect) =>
        max(1, down ? rect.bottom - origin.bottom : origin.top - rect.top);
    double score(Rect rect) {
      final double minor = rect.center.dx - origin.center.dx;
      return 13 * major(rect) * major(rect) + minor * minor;
    }

    bool beamBeats(Rect a, Rect b) =>
        inBeam(a) &&
        !inBeam(b) &&
        (!(down ? origin.bottom <= b.top : origin.top >= b.bottom) ||
            major(a) < majorFar(b));

    bool beats(Rect a, Rect b) =>
        beamBeats(a, b) || (!beamBeats(b, a) && score(a) < score(b));

    FocusNode? best;
    Rect? bestRect;
    for (final FocusNode other in candidates) {
      final Rect rect = _rectOf(other);
      final Rect? current = bestRect;
      if (ahead(rect) && (current == null || beats(rect, current))) {
        best = other;
        bestRect = rect;
      }
    }
    return best;
  }

  // 输入框一获焦就弹出系统键盘并接走方向键，遥控器只是路过也得先按返回收起；
  // 等焦点切换生效后收起，按确认键时由 ActivateIntent 重新打开
  static void _hideKeyboardSoon() {
    scheduleMicrotask(() {
      if (FocusManager.instance.primaryFocus?.context
              ?.findAncestorStateOfType<EditableTextState>() !=
          null) {
        SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      }
    });
  }

  void _reveal(FocusNode target, {required bool toEnd}) {
    target.requestFocus();
    _hideKeyboardSoon();
    final BuildContext? context = target.context;
    if (context != null) {
      unawaited(
        Scrollable.ensureVisible(
          context,
          alignmentPolicy: toEnd
              ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
              : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
        ),
      );
    }
  }

  // 服务条款、公告正文这类纯文本滚动区里没有可聚焦控件，焦点停在区域外（返回、确认按钮），
  // 只能直接滚同一列里焦点进不去的那片区域
  ScrollableState? _unfocusableScrollable(FocusNode node, Axis axis) {
    final FocusScopeNode? scope = node.nearestScope;
    final BuildContext? root = scope?.context;
    if (scope == null || root == null) {
      return null;
    }
    final Set<ScrollableState> reachable = <ScrollableState>{};
    for (final FocusNode other in scope.traversalDescendants) {
      final BuildContext? context = other.context;
      ScrollableState? owner = context == null
          ? null
          : Scrollable.maybeOf(context);
      while (owner != null && reachable.add(owner)) {
        owner = Scrollable.maybeOf(owner.context);
      }
    }
    final Rect origin = node.rect;
    ScrollableState? best;
    double bestArea = 0;
    void visit(Element element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        final ScrollableState state = element.state as ScrollableState;
        final RenderObject? box = element.renderObject;
        if (axisDirectionToAxis(state.axisDirection) == axis &&
            !reachable.contains(state) &&
            box is RenderBox &&
            box.hasSize) {
          final Rect rect = box.localToGlobal(Offset.zero) & box.size;
          final bool sameLine = axis == Axis.vertical
              ? rect.right > origin.left && rect.left < origin.right
              : rect.bottom > origin.top && rect.top < origin.bottom;
          final double area = rect.width * rect.height;
          if (sameLine && area > bestArea) {
            best = state;
            bestArea = area;
          }
        }
      }
      element.visitChildren(visit);
    }

    root.visitChildElements(visit);
    return best;
  }

  // 绕回按排版位置比较：列表滚过之后，固定在列表外的工具栏仍应排在列表第一项之上
  static double _scrolled(FocusNode node) {
    final BuildContext? context = node.context;
    double offset = 0;
    ScrollableState? owner = context == null
        ? null
        : Scrollable.maybeOf(context, axis: Axis.vertical);
    while (owner != null) {
      offset += owner.position.pixels - owner.position.minScrollExtent;
      owner = Scrollable.maybeOf(owner.context, axis: Axis.vertical);
    }
    return offset;
  }

  // 上下键到顶 / 到底且列表也滚到头时，绕到同一区域另一端那一行里横向最近的控件
  void _wrap(FocusNode node, {required bool toTop}) {
    final FocusScopeNode? scope = node.nearestScope;
    final BuildContext? context = node.context;
    if (scope != null && context != null) {
      _wrapIn(
        scope,
        _group(node),
        node,
        _rectOf(node).shift(Offset(0, _scrolled(node))),
        toTop,
        from: Scrollable.maybeOf(context, axis: Axis.vertical)?.position,
      );
    }
  }

  // 懒加载列表只建出可视区附近的项，绕回目标所在的列表要先跳到这一端，下一帧再按建出来的项
  // 重新挑；出发的列表也一并跳回，否则绕到顶部的固定按钮后，列表还停在底部，再往下会越过开头
  void _wrapIn(
    FocusScopeNode scope,
    TelevisionFocusSection? group,
    FocusNode node,
    Rect origin,
    bool toTop, {
    ScrollPosition? from,
  }) {
    final List<FocusNode> peers = scope.traversalDescendants
        .where((FocusNode other) => other != node && _group(other) == group)
        .toList();
    if (peers.isEmpty) {
      return;
    }
    double edgeOf(FocusNode other) =>
        (toTop ? _rectOf(other).top : _rectOf(other).bottom) + _scrolled(other);
    final double edge = peers.map(edgeOf).reduce(toTop ? min : max);
    // origin 是排版位置；另一端仍是本行（页面只剩顶栏几个按钮）时不横跳
    if (toTop ? edge >= origin.top : edge <= origin.bottom) {
      return;
    }
    final FocusNode target = peers
        .where((FocusNode other) => (edgeOf(other) - edge).abs() < 8)
        .reduce(
          (FocusNode a, FocusNode b) =>
              (_rectOf(a).center.dx - origin.center.dx).abs() <=
                  (_rectOf(b).center.dx - origin.center.dx).abs()
              ? a
              : b,
        );
    final BuildContext? context = target.context;
    bool jumped = false;
    for (final ScrollPosition? position in <ScrollPosition?>[
      from,
      if (context != null)
        Scrollable.maybeOf(context, axis: Axis.vertical)?.position,
    ]) {
      if (position == null || !position.hasPixels) {
        continue;
      }
      final double end = toTop
          ? position.minScrollExtent
          : position.maxScrollExtent;
      if (position.pixels != end) {
        position.jumpTo(end);
        jumped = true;
      }
    }
    if (jumped) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _wrapIn(scope, group, node, origin, toTop);
        }
      });
      return;
    }
    _reveal(target, toEnd: !toTop);
  }

  Widget? _ring(BuildContext context) {
    final Rect? focused = _focused;
    if (focused == null) {
      return null;
    }
    final Color color = Theme.of(context).colorScheme.primary;
    final Rect rect = focused.inflate(_ringGap);
    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: color, width: _ringWidth),
            borderRadius: BorderRadius.circular(
              min(rect.shortestSide / 2, _ringMaxRadius),
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 8),
            ],
          ),
        ),
      ),
    );
  }
}

// 输入框自带的 DirectionalFocusAction 会截住 DirectionalFocusIntent 直接走原生遍历，
// 方向键因此改发专用意图，交到 TelevisionNavigation 手里
class _TelevisionMoveIntent extends Intent {
  const _TelevisionMoveIntent(this.direction);

  final TraversalDirection direction;
}

const Map<ShortcutActivator, Intent> _arrowShortcuts =
    <ShortcutActivator, Intent>{
      SingleActivator(LogicalKeyboardKey.arrowUp): _TelevisionMoveIntent(
        TraversalDirection.up,
      ),
      SingleActivator(LogicalKeyboardKey.arrowDown): _TelevisionMoveIntent(
        TraversalDirection.down,
      ),
      SingleActivator(LogicalKeyboardKey.arrowLeft): _TelevisionMoveIntent(
        TraversalDirection.left,
      ),
      SingleActivator(LogicalKeyboardKey.arrowRight): _TelevisionMoveIntent(
        TraversalDirection.right,
      ),
    };

/// 电视方向键斜跳不出入这片区域（如侧边栏），上下到头时在区域内绕回
class TelevisionFocusSection extends StatelessWidget {
  const TelevisionFocusSection({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// RadioGroup 自带方向键在组内循环改选，电视上焦点因此困在单选列表里、到不了确认按钮。
/// 包在它的子树外层，把方向键交回 TelevisionNavigation 移动焦点，选中改由确认键完成。
class TelevisionArrowKeys extends StatelessWidget {
  const TelevisionArrowKeys({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (context.findAncestorWidgetOfExactType<TelevisionNavigation>() == null) {
      return child;
    }
    return Shortcuts(shortcuts: _arrowShortcuts, child: child);
  }
}

/// 筛选行在列表之外时，焦点永远进不了列表，遥控器因此滚不动它。让这片区域
/// 自己成为一个焦点落点：聚焦期间上下键滚动，滚到尽头就不再拦键，焦点照常移出去。
class TelevisionScrollFocus extends StatelessWidget {
  const TelevisionScrollFocus({
    super.key,
    required this.controller,
    required this.child,
  });

  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // TelevisionNavigation 只挂在电视上，有它才说明当前是遥控器操作
    if (context.findAncestorWidgetOfExactType<TelevisionNavigation>() == null) {
      return child;
    }
    return Focus(
      onKeyEvent: (FocusNode node, KeyEvent event) {
        if (event is KeyUpEvent || !controller.hasClients) {
          return KeyEventResult.ignored;
        }
        final TraversalDirection? direction = switch (event.logicalKey) {
          LogicalKeyboardKey.arrowDown => TraversalDirection.down,
          LogicalKeyboardKey.arrowUp => TraversalDirection.up,
          _ => null,
        };
        if (direction == null) {
          return KeyEventResult.ignored;
        }
        return _scrollBy(controller.position, direction)
            ? KeyEventResult.handled
            : KeyEventResult.ignored;
      },
      child: child,
    );
  }
}

const double _scrollStepPixels = 160;

bool _scrollBy(ScrollPosition? position, TraversalDirection direction) {
  if (position == null) {
    return false;
  }
  final double delta = switch (direction) {
    TraversalDirection.down || TraversalDirection.right => _scrollStepPixels,
    TraversalDirection.up || TraversalDirection.left => -_scrollStepPixels,
  };
  final double target = (position.pixels + delta).clamp(
    position.minScrollExtent,
    position.maxScrollExtent,
  );
  if (target == position.pixels) {
    return false;
  }
  position.animateTo(
    target,
    duration: const Duration(milliseconds: 160),
    curve: Curves.easeOut,
  );
  return true;
}
