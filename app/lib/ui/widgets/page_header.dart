import 'package:flutter/material.dart';

import '../theme.dart';
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
  static double get _actionIconInset =>
      (_actionButtonSize - _actionIconSize) / 2;

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
      padding: EdgeInsets.fromLTRB(left, 16, AppTheme.pageScrollPadding.right, 16),
      child: SizedBox(
        height: rowHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            if (showBackButton) ...<Widget>[
              IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: const BackButtonIcon(),
                iconSize: _actionIconSize,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.standard,
                constraints: BoxConstraints.tightFor(
                  width: _actionButtonSize,
                  height: _actionButtonSize,
                ),
                onPressed: () {
                  Navigator.maybePop(context);
                },
              ),
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
