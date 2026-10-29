import 'package:flutter/material.dart';

import '../../core/app_config.dart';
import '../theme.dart';
import 'overlay_scroll_view.dart';
import 'app_scaffold.dart';

class AuthStorePanel extends StatelessWidget {
  const AuthStorePanel({
    super.key,
    required this.title,
    this.subtitle,
    required this.child,
    this.onBack,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final VoidCallback? onBack;

  static const double maxWidth = 400;
  static const double splitBreakpoint = 880;
  static const BorderRadius radius = BorderRadius.all(Radius.circular(12));

  static ThemeData themeOf(ThemeData base) {
    final ColorScheme scheme = base.colorScheme;
    final TextStyle? label = base.textTheme.labelLarge?.copyWith(
      fontSize: 14,
      fontWeight: FontWeight.w600,
    );
    OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
      borderRadius: const BorderRadius.all(Radius.circular(999)),
      borderSide: BorderSide(color: color, width: width),
    );
    const ButtonStyle block = ButtonStyle(
      minimumSize: WidgetStatePropertyAll<Size>(Size(64, 48)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      shape: WidgetStatePropertyAll<OutlinedBorder>(StadiumBorder()),
    );

    return base.copyWith(
      visualDensity: VisualDensity.standard,
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        fillColor: scheme.surfaceContainerLowest,
        floatingLabelBehavior: FloatingLabelBehavior.never,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        border: border(Colors.transparent, 1),
        enabledBorder: border(Colors.transparent, 1),
        focusedBorder: border(scheme.primary, 1.5),
        errorBorder: border(scheme.error, 1),
        focusedErrorBorder: border(scheme.error, 1.5),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: block
            .copyWith(textStyle: WidgetStatePropertyAll<TextStyle?>(label))
            .merge(base.filledButtonTheme.style),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: block
            .copyWith(
              textStyle: WidgetStatePropertyAll<TextStyle?>(label),
              side: WidgetStatePropertyAll<BorderSide>(
                BorderSide(color: scheme.outline),
              ),
            )
            .merge(base.outlinedButtonTheme.style),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 40)),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.zero,
          ),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(StadiumBorder()),
          side: const WidgetStatePropertyAll<BorderSide>(BorderSide.none),
          overlayColor: WidgetStateProperty<Color>.fromMap(
            <WidgetStatesConstraint, Color>{
              WidgetState.focused: scheme.primary.withValues(alpha: 0.12),
              WidgetState.any: Colors.transparent,
            },
          ),
          foregroundColor: WidgetStateProperty<Color>.fromMap(
            <WidgetStatesConstraint, Color>{
              WidgetState.disabled: scheme.primary.withValues(alpha: 0.38),
              WidgetState.any: scheme.primary,
            },
          ),
          textStyle: WidgetStatePropertyAll<TextStyle?>(
            label?.copyWith(fontWeight: FontWeight.w500),
          ),
        ).merge(base.textButtonTheme.style),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double width = MediaQuery.sizeOf(context).width;
    final bool split = width >= splitBreakpoint;
    final Widget form = Theme(
      data: themeOf(theme),
      child: split ? _splitForm(context) : _stackedForm(context),
    );

    return AppScaffold(
      backgroundColor: theme.colorScheme.surface,
      body: split
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(
                  width: (width * 0.42).clamp(380, 560),
                  child: const _AuthBrand(),
                ),
                Expanded(child: form),
              ],
            )
          : form,
    );
  }

  Widget _back(BuildContext context) {
    return IconButton(
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      icon: const BackButtonIcon(),
      onPressed: onBack,
    );
  }

  Widget _content(BuildContext context, {required bool split}) {
    final ThemeData theme = Theme.of(context);
    final double titleSize = split ? 30 : 28;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: maxWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (!split) ...<Widget>[
            const Center(child: _AuthMark()),
            const SizedBox(height: 28),
          ],
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontSize: titleSize,
              fontWeight: FontWeight.w700,
              height: 1.15,
              letterSpacing: titleSize * -0.03,
            ),
          ),
          if (subtitle != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 14,
                height: 1.5,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 32),
          child,
        ],
      ),
    );
  }

  Widget _splitForm(BuildContext context) {
    const EdgeInsets padding = EdgeInsets.symmetric(
      horizontal: 48,
      vertical: 72,
    );

    return SafeArea(
      left: false,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                return OverlayScrollView(
                  padding: padding,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: (constraints.maxHeight - padding.vertical)
                          .clamp(0, double.infinity),
                    ),
                    child: Align(child: _content(context, split: true)),
                  ),
                );
              },
            ),
          ),
          if (onBack != null)
            Positioned(left: 16, top: 16, child: _back(context)),
        ],
      ),
    );
  }

  Widget _stackedForm(BuildContext context) {
    const EdgeInsets padding = EdgeInsets.fromLTRB(24, 24, 24, 40);

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (onBack != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: _back(context),
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                return OverlayScrollView(
                  padding: padding,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: (constraints.maxHeight - padding.vertical)
                          .clamp(0, double.infinity),
                    ),
                    child: Align(child: _content(context, split: false)),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthMark extends StatelessWidget {
  const _AuthMark();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Image(
          image: AssetImage('assets/app_icon.png'),
          width: 28,
          height: 28,
          filterQuality: FilterQuality.medium,
          excludeFromSemantics: true,
        ),
        const SizedBox(width: 10),
        Text(
          'ECY Cloud',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _AuthBrand extends StatelessWidget {
  const _AuthBrand();

  static const Color _top = Color(0xFF0B1020);
  static const Color _bottom = Color(0xFF0A2A66);

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[_top, _bottom],
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Positioned(
            right: -160,
            top: -160,
            width: 480,
            height: 480,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: <Color>[
                    AppTheme.accentDark.withValues(alpha: 0.45),
                    AppTheme.accentDark.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            right: false,
            child: Padding(
              padding: const EdgeInsets.all(48),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  const Image(
                    image: AssetImage('assets/app_icon.png'),
                    width: 64,
                    height: 64,
                    filterQuality: FilterQuality.medium,
                    excludeFromSemantics: true,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'ECY Cloud',
                    textAlign: TextAlign.center,
                    style: text.headlineSmall?.copyWith(
                      fontSize: 44,
                      fontWeight: FontWeight.w700,
                      height: 1.05,
                      letterSpacing: 44 * -0.03,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    AppConfig.siteHost,
                    textAlign: TextAlign.center,
                    style: text.bodyLarge?.copyWith(
                      fontSize: 15,
                      color: Colors.white.withValues(alpha: 0.64),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}