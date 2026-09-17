import 'package:flutter/material.dart';

import '../theme.dart';
import 'overlay_scroll_view.dart';

class AuthStorePanel extends StatelessWidget {
  const AuthStorePanel({super.key, required this.child, this.onBack});

  final Widget child;
  final VoidCallback? onBack;

  static const double maxWidth = 440;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final EdgeInsets padding = AppTheme.overlayGutterOf(
      const EdgeInsets.all(24),
    );

    return Scaffold(
      body: Stack(
        children: <Widget>[
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              return OverlayScrollView(
                padding: padding,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: (constraints.maxHeight - padding.vertical).clamp(
                      0,
                      double.infinity,
                    ),
                  ),
                  child: Align(
                    alignment: Alignment.center,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: maxWidth),
                      child: Material(
                        color: theme.colorScheme.surface,
                        borderRadius: BorderRadius.circular(
                          AppTheme.authPanelRadius,
                        ),
                        clipBehavior: Clip.hardEdge,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(32, 36, 32, 36),
                          child: child,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          if (onBack != null)
            Align(
              alignment: Alignment.topLeft,
              child: SafeArea(
                child: IconButton(
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  icon: const BackButtonIcon(),
                  onPressed: onBack,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
