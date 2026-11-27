import 'package:flutter/material.dart';

import '../theme.dart';
import 'touch_bleed.dart';
import 'user_avatar.dart';

class ShellChromeBar extends ChangeNotifier {
  String title = '';
  List<Widget> actions = const <Widget>[];

  void set({required String title, List<Widget> actions = const <Widget>[]}) {
    this.title = title;
    this.actions = actions;
    notifyListeners();
  }
}

class ShellChrome extends InheritedWidget {
  const ShellChrome({
    super.key,
    required this.active,
    required this.bar,
    required super.child,
  });

  final bool active;
  final ShellChromeBar bar;

  static ShellChrome? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellChrome>();

  @override
  bool updateShouldNotify(ShellChrome old) =>
      active != old.active || bar != old.bar;
}

// 桌面端 IndexedStack 里看不见的页面仍在树上、照样排版：只在当前页订阅，切回来时随依赖变化重建一次
class ShellListenableBuilder extends StatefulWidget {
  const ShellListenableBuilder({
    super.key,
    required this.listenable,
    required this.builder,
    this.child,
  });

  final Listenable listenable;
  final TransitionBuilder builder;
  final Widget? child;

  @override
  State<ShellListenableBuilder> createState() => _ShellListenableBuilderState();
}

class _ShellListenableBuilderState extends State<ShellListenableBuilder> {
  Listenable? _listening;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _listen();
  }

  @override
  void didUpdateWidget(ShellListenableBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    _listen();
  }

  @override
  void dispose() {
    _listening?.removeListener(_changed);
    super.dispose();
  }

  void _listen() {
    final Listenable? next = ShellChrome.maybeOf(context)?.active == false
        ? null
        : widget.listenable;
    if (identical(next, _listening)) {
      return;
    }
    _listening?.removeListener(_changed);
    _listening = next?..addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) => widget.builder(context, widget.child);
}

class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.actions,
    this.showUserAvatar = true,
    this.showBackButton = false,
  });

  final String title;
  final List<Widget>? actions;
  final bool showUserAvatar;
  final bool showBackButton;

  static const double edge = UserAvatarButton.edge;

  static const double actionGap = 8;

  static const double _actionIconSize = 20;

  static double get _actionButtonSize => AppTheme.minTapTarget;
  // 返回键按桌面端尺寸排版（TouchBleed），图标内缩也按桌面端算
  static const double _actionIconInset =
      (AppTheme.pointerTapTarget - _actionIconSize) / 2;

  // 返回键左缘按图标内缩对齐页面边距，外壳页头（AppHeader）也用这一份
  static const double backButtonInset = _actionIconInset;

  static Widget backButton(BuildContext context, VoidCallback onPressed) =>
      TouchBleed(
        child: IconButton(
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          icon: const BackButtonIcon(),
          iconSize: _actionIconSize,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.standard,
          constraints: AppTheme.iconButtonBox,
          onPressed: onPressed,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final ShellChrome? chrome = ShellChrome.maybeOf(context);
    if (chrome != null && !showUserAvatar && !showBackButton) {
      if (chrome.active) {
        final List<Widget> hoisted = actions ?? const <Widget>[];
        WidgetsBinding.instance.addPostFrameCallback((_) {
          chrome.bar.set(title: title, actions: hoisted);
        });
      }
      return const SizedBox(height: 16);
    }

    final double left = showBackButton ? edge - _actionIconInset : edge;
    final double titleSize = AppTheme.pageTitleSizeOf(context);
    final double rowHeight = titleSize * 1.2 < _actionButtonSize
        ? _actionButtonSize
        : titleSize * 1.2;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        left,
        16,
        AppTheme.pageScrollPadding.right,
        16,
      ),
      child: SizedBox(
        height: rowHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            if (showBackButton) ...<Widget>[
              backButton(context, () => Navigator.maybePop(context)),
              const SizedBox(width: actionGap),
            ],
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontSize: titleSize,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                    letterSpacing: titleSize * -0.03,
                  ),
                ),
              ),
            ),
            if (actions != null)
              Row(mainAxisSize: MainAxisSize.min, children: actions!),
            if (showUserAvatar) ...<Widget>[
              const SizedBox(width: edge),
              const UserAvatarButton(),
            ],
          ],
        ),
      ),
    );
  }
}
