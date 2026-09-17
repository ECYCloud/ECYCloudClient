import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/logger.dart';

class AppTheme {
  AppTheme._();

  static const Color accent = Color(0xFF0071E3);
  static const Color accentDark = Color(0xFF2997FF);
  static const Color seed = accent;
  static const Color success = Color(0xFF2FBF71);
  static const Color warning = Color(0xFFE0A800);
  static const Color danger = Color(0xFFD70015);
  static const Color dangerDark = Color(0xFFFF453A);

  static const Color bandLight = Color(0xFFF5F5F7);
  static const Color bandDark = Color(0xFF161617);
  static const Color surfaceLight = Color(0xFFFFFFFF);
  static const Color surfaceDark = Color(0xFF1D1D1F);
  static const Color textLight = Color(0xFF1D1D1F);
  static const Color textDark = Color(0xFFF5F5F7);
  static const Color textSecondaryLight = Color(0xFF6E6E73);
  static const Color textSecondaryDark = Color(0xFFA1A1A6);
  static const Color segmentLight = Color(0xFFE8E8ED);
  static const Color segmentDark = Color(0xFF2C2C2E);

  static const OutlinedBorder pillShape = StadiumBorder();

  // 触控平台（Android/iOS）手指需要 48dp 触控目标，桌面用鼠标 32 即可。
  // 只放大触控盒，图标与文字的视觉尺寸不变。
  static bool get isTouch =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.fuchsia;

  // 小图标键与头像的可点盒子。配 BoxConstraints.tightFor 用时 visualDensity
  // 必须显式给 standard：VisualDensity 只把约束的 min 减 8、max 不动，本主题的
  // 全局 compact 会让紧约束退化成松约束，盒子按内容缩小并脱离右侧那一列。
  static double get minTapTarget => isTouch ? 48 : 32;

  static ButtonStyle _tonalPill(Color cta) =>
      FilledButton.styleFrom(
        backgroundColor: Colors.transparent,
        foregroundColor: cta,
        disabledBackgroundColor: Colors.transparent,
        disabledForegroundColor: cta.withValues(alpha: 0.38),
        shape: pillShape,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        textStyle: _componentText(13, weight: FontWeight.w600),
      ).copyWith(
        side: WidgetStateProperty<BorderSide>.fromMap(<
          WidgetStatesConstraint,
          BorderSide
        >{
          WidgetState.disabled: BorderSide(color: cta.withValues(alpha: 0.12)),
          WidgetState.any: BorderSide(color: cta),
        }),
      );

  static const double cardRadius = 20;
  static const double tileRadius = 9;
  static const double menuRadius = 16;
  static const double authPanelRadius = 28;
  static const double pageHintSize = 14;
  static const double pageTitleSize = 22;
  static const double pageTitleSizeNarrow = 22;
  static const double navLabelSize = 15;
  static const double authTitleSize = 24;
  static const double authTitleSizeNarrow = 22;
  static const double headerHeight = 48;
  static const double sidebarWidth = 192;
  static const double wideBreakpoint = 640;
  static const double sectionTitleSize = 18;
  static const double controlWidth = 116;
  static const double controlHeight = 36;

  static const VisualDensity controlDensity = VisualDensity.standard;
  static const VisualDensity _density = VisualDensity(
    horizontal: -2,
    vertical: -2,
  );

  static Widget withControlDensity(Widget child) {
    return Builder(
      builder: (BuildContext context) {
        return Theme(
          data: Theme.of(context).copyWith(visualDensity: controlDensity),
          child: child,
        );
      },
    );
  }

  // isDense 时描边盒只包文字；必须 false，再靠 tight 高度把描边盒收到 controlHeight。
  static InputDecoration controlDecoration({
    String? hintText,
    BoxConstraints? constraints,
  }) {
    return InputDecoration(
      hintText: hintText,
      isDense: false,
      visualDensity: controlDensity,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      constraints:
          constraints ??
          const BoxConstraints(
            minHeight: controlHeight,
            maxHeight: controlHeight,
          ),
    );
  }

  static Widget selectableRegionMenu(
    BuildContext context,
    SelectableRegionState state,
  ) {
    return _menuWithoutSelectAll(
      state.contextMenuButtonItems,
      state.contextMenuAnchors,
    );
  }

  static Widget editableTextMenu(
    BuildContext context,
    EditableTextState state,
  ) {
    return _menuWithoutSelectAll(
      state.contextMenuButtonItems,
      state.contextMenuAnchors,
    );
  }

  static Widget _menuWithoutSelectAll(
    List<ContextMenuButtonItem> items,
    TextSelectionToolbarAnchors anchors,
  ) {
    final List<ContextMenuButtonItem> kept = <ContextMenuButtonItem>[
      for (final ContextMenuButtonItem item in items)
        if (item.type != ContextMenuButtonType.selectAll) item,
    ];
    if (kept.isEmpty) {
      return const SizedBox.shrink();
    }
    return _ThemedSelectionToolbar(anchors: anchors, items: kept);
  }

  static bool isWide(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= wideBreakpoint;

  static double pageTitleSizeOf(BuildContext context) =>
      isWide(context) ? pageTitleSize : pageTitleSizeNarrow;

  static double authTitleSizeOf(BuildContext context) =>
      isWide(context) ? authTitleSize : authTitleSizeNarrow;

  // overlay 滚动条不占布局（厚度 7 + crossAxisMargin 2）。滚动区内侧至少留这段，否则文字会被拇指盖住。
  static const double overlayScrollGutter = 16;
  static const EdgeInsets overlayScrollPadding = EdgeInsets.only(
    right: overlayScrollGutter,
  );
  static const EdgeInsets overlayScrollPaddingBottom = EdgeInsets.only(
    bottom: overlayScrollGutter,
  );
  static const EdgeInsets pageScrollPadding = EdgeInsets.fromLTRB(
    14,
    14,
    overlayScrollGutter,
    14,
  );

  static EdgeInsets overlayGutterOf(
    EdgeInsets? padding, {
    Axis axis = Axis.vertical,
  }) {
    if (axis == Axis.horizontal) {
      final EdgeInsets base = padding ?? overlayScrollPaddingBottom;
      return base.bottom >= overlayScrollGutter
          ? base
          : base.copyWith(bottom: overlayScrollGutter);
    }
    final EdgeInsets base = padding ?? overlayScrollPadding;
    return base.right >= overlayScrollGutter
        ? base
        : base.copyWith(right: overlayScrollGutter);
  }

  // 24 是 ListTile 的 trailing 内边距；图标被触摸盒（minTapTarget）居中后会内缩，
  // 行的右内边距减掉这段，才与同列的 chevron、开关落在一条边上
  static double trailingIconButtonInset(double iconSize) =>
      24 - (minTapTarget - iconSize) / 2;

  // Switch 的轨道尺寸由 Material 写死（M3 为 52×32），主题里改不动，
  // 只能整体缩放；桌面端按 0.8 收到约 42×26
  static const double switchScale = 0.8;

  // 字族一律取用户设备自己的字体，不在代码里写死任何字体名。Windows 由原生侧问
  // 系统要；其余平台留空，交给引擎的平台默认字体。缺字由系统自身的字体回退补，
  // 不手写回退链。
  static String? _fontFamily;
  static String? _monoFontFamily;

  // 只读查看页显示配置原文，要等宽才对得齐缩进；取不到就退回界面字体
  static String? get monoFontFamily => _monoFontFamily;

  // 首帧就要用到字族，必须在 runApp 之前完成；取不到就退回引擎默认字体
  static Future<void> loadSystemUiFont() async {
    if (!Platform.isWindows) {
      return;
    }
    try {
      final Map<Object?, Object?>? fonts = await const MethodChannel(
        'ecycloud/platform',
      ).invokeMethod<Map<Object?, Object?>>('ui.fonts');
      if (fonts == null) {
        return;
      }
      _fontFamily = _named(fonts['ui']);
      _monoFontFamily = _named(fonts['mono']);
    } on PlatformException catch (e) {
      Logger.instance.warn('theme', '读取系统字体失败，改用引擎默认字体: $e');
    }
  }

  static String? _named(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  // 组件主题里的 TextStyle 必须自带字族。ThemeData.fontFamily 只会应用到
  // textTheme（theme_data.dart 的 defaultTextTheme.apply），而按钮、分段控件、
  // 导航栏、Tooltip 取样式都是「主题给了就整体用主题的」（如 ButtonStyle.merge
  // 的 textStyle ?? style.textStyle，tooltip.dart 的 textStyle ?? 默认值），
  // 不与控件默认的 labelLarge / bodyMedium 逐字段合并。少写字族，这些控件里的
  // 中文就会落到引擎默认字体（Segoe UI 无中文字形，再逐字回退到别的字库），
  // 与界面其它文字明显不是一套字。
  static TextStyle _componentText(
    double size, {
    FontWeight? weight,
    Color? color,
  }) => TextStyle(
    fontFamily: _fontFamily,
    fontSize: size,
    fontWeight: weight,
    color: color,
  );

  static final ThemeData _light = _build(Brightness.light);
  static final ThemeData _dark = _build(Brightness.dark);

  static ThemeData light() => _light;

  static ThemeData dark() => _dark;

  // Material 的字阶按移动端触摸场景设定，桌面上普遍大一到两号。
  // 这里显式给全字阶定尺寸，不用 TextTheme.apply(fontSizeDelta:)：
  // ThemeData.textTheme 的各项 fontSize 实际为 null（尺寸在渲染期由字体度量补全），
  // apply 对 null 不生效，debug 下还会直接触发 fontSize != null 断言。
  //
  static TextTheme _textTheme(ColorScheme scheme) {
    TextStyle style(double size, [FontWeight weight = FontWeight.w400]) =>
        TextStyle(
          fontFamily: _fontFamily,
          fontSize: size,
          fontWeight: weight,
          color: scheme.onSurface,
        );

    return TextTheme(
      displayLarge: style(40),
      displayMedium: style(32),
      displaySmall: style(26),
      headlineLarge: style(24),
      headlineMedium: style(21),
      headlineSmall: style(18),
      titleLarge: style(17, FontWeight.w600),
      titleMedium: style(14, FontWeight.w600),
      titleSmall: style(13, FontWeight.w600),
      bodyLarge: style(13),
      bodyMedium: style(13),
      bodySmall: style(12).copyWith(color: scheme.onSurfaceVariant),
      labelLarge: style(12, FontWeight.w600),
      labelMedium: style(12, FontWeight.w500),
      labelSmall: style(10, FontWeight.w500),
    );
  }

  static ColorScheme _scheme(Brightness brightness) {
    final bool dark = brightness == Brightness.dark;
    final Color surface = dark ? surfaceDark : surfaceLight;
    final Color text = dark ? textDark : textLight;
    final Color textSecondary = dark ? textSecondaryDark : textSecondaryLight;
    final Color accentColor = dark ? accentDark : accent;
    final Color segment = dark ? segmentDark : segmentLight;
    final Color band = dark ? bandDark : bandLight;
    return ColorScheme(
      brightness: brightness,
      primary: accentColor,
      onPrimary: Colors.white,
      secondary: segment,
      onSecondary: text,
      error: dark ? dangerDark : danger,
      onError: Colors.white,
      surface: surface,
      onSurface: text,
      onSurfaceVariant: textSecondary,
      outline: dark ? const Color(0x47FFFFFF) : const Color(0x38000000),
      outlineVariant: segment,
      surfaceContainerLowest: band,
      surfaceContainerLow: surface,
      surfaceContainer: surface,
      surfaceContainerHigh: surface,
      surfaceContainerHighest: segment,
      inverseSurface: text,
      onInverseSurface: surface,
      inversePrimary: dark ? accent : accentDark,
    );
  }

  static ThemeData _build(Brightness brightness) {
    final ColorScheme scheme = _scheme(brightness);
    final Color band = scheme.surfaceContainerLowest;
    final Color cta = scheme.onSurface;
    final Color ctaText = scheme.surface;
    final Color inputBorder = scheme.outline;

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      fontFamily: _fontFamily,
      textTheme: _textTheme(scheme),
      // 全端同一密度：按平台分档会让 Android 的按钮、输入框、列表行比桌面各高一档
      visualDensity: _density,
      scaffoldBackgroundColor: band,
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surface,
        // antiAlias 会把卡片内容画进离屏层再裁圆角，文字会被抗两次锯齿。
        clipBehavior: Clip.hardEdge,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
        ),
      ),
      dividerTheme: DividerThemeData(
        space: 1,
        thickness: 1,
        color: scheme.outline.withValues(alpha: 0.5),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        border: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(999)),
          borderSide: BorderSide(color: inputBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(999)),
          borderSide: BorderSide(color: inputBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(999)),
          borderSide: BorderSide(color: scheme.primary, width: 3),
        ),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(minHeight: controlHeight),
        hintStyle: _componentText(12, color: scheme.onSurfaceVariant),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        linearMinHeight: 5,
        borderRadius: BorderRadius.circular(3),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll<double>(7),
        radius: const Radius.circular(4),
        mainAxisMargin: 4,
        crossAxisMargin: 2,
        interactive: true,
        thumbColor:
            WidgetStateProperty<Color>.fromMap(<WidgetStatesConstraint, Color>{
              WidgetState.hovered: scheme.outline.withValues(alpha: 0.6),
              WidgetState.any: scheme.outlineVariant,
            }),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: cta,
          foregroundColor: ctaText,
          disabledBackgroundColor: cta.withValues(alpha: 0.38),
          disabledForegroundColor: ctaText.withValues(alpha: 0.38),
          shape: pillShape,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
          textStyle: _componentText(13, weight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(style: _tonalPill(cta)),
      textButtonTheme: TextButtonThemeData(style: _tonalPill(cta)),
      chipTheme: ChipThemeData(
        shape: pillShape,
        backgroundColor: Colors.transparent,
        selectedColor: scheme.primary.withValues(alpha: 0.14),
        side: BorderSide(color: scheme.outline),
      ),
      // MenuItemButton 内部是 TextButton，会再套一层 textButtonTheme。
      // 文字按钮的描边不挡掉，就会画进每一项，两项交界叠成分隔线。
      menuButtonTheme: const MenuButtonThemeData(
        style: ButtonStyle(
          side: WidgetStatePropertyAll<BorderSide>(BorderSide.none),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surface,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(menuRadius),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: cta,
          foregroundColor: ctaText,
          shape: pillShape,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          textStyle: _componentText(13, weight: FontWeight.w600),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style:
            SegmentedButton.styleFrom(
              shape: pillShape,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              textStyle: _componentText(12, weight: FontWeight.w600),
              backgroundColor: Colors.transparent,
              foregroundColor: cta,
              selectedBackgroundColor: cta,
              selectedForegroundColor: ctaText,
              // 默认 outline 是半透明，选中填色到不了描边环，看起来像一圈缝。
              // 描边改成和填色同一实色，尺寸/密度都不动。
              side: BorderSide(color: cta),
            ).copyWith(
              overlayColor: const WidgetStatePropertyAll<Color>(
                Colors.transparent,
              ),
              splashFactory: NoSplash.splashFactory,
              animationDuration: Duration.zero,
            ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(iconSize: 20, shape: pillShape),
      ),
      listTileTheme: const ListTileThemeData(
        minVerticalPadding: 6,
        horizontalTitleGap: 10,
      ),
      switchTheme: SwitchThemeData(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        // M3 开关状态层半径固定 20，套在缩小后的开关上会盖住滑块。
        // hover / press 也不改轨道和滑块颜色，避免整颗变成一块纯色。
        overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        trackColor:
            WidgetStateProperty<Color>.fromMap(<WidgetStatesConstraint, Color>{
              WidgetState.disabled & WidgetState.selected: cta.withValues(
                alpha: 0.38,
              ),
              WidgetState.selected: cta,
              WidgetState.disabled: scheme.surfaceContainerHighest.withValues(
                alpha: 0.38,
              ),
              WidgetState.any: scheme.surfaceContainerHighest,
            }),
        thumbColor:
            WidgetStateProperty<Color>.fromMap(<WidgetStatesConstraint, Color>{
              WidgetState.disabled & WidgetState.selected: ctaText.withValues(
                alpha: 0.38,
              ),
              WidgetState.selected: ctaText,
              WidgetState.disabled: scheme.outline.withValues(alpha: 0.38),
              WidgetState.any: scheme.outline,
            }),
        trackOutlineColor: const WidgetStatePropertyAll<Color>(
          Colors.transparent,
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        // Tooltip 底色默认取 inverseSurface（深色主题下是浅色），
        // 文字色必须跟着取 onInverseSurface，写死白色会在深色主题下白底白字
        textStyle: _componentText(12, color: scheme.onInverseSurface),
      ),
      snackBarTheme: SnackBarThemeData(
        contentTextStyle: _componentText(13, color: scheme.onInverseSurface),
      ),
      // 桌面宽窗下 Dialog 默认无 maxWidth，会拉成整屏宽条；按 Material 3 收口
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
        ),
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 560),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        actionsPadding: const EdgeInsets.only(right: 14),
        titleTextStyle: _componentText(
          16,
          weight: FontWeight.w600,
          color: scheme.onSurface,
        ),
        toolbarTextStyle: _componentText(13, color: scheme.onSurface),
      ),
      // 与 NavigationRail 同一纪律：底栏标签也必须自带字族，不能靠默认 labelMedium
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        labelTextStyle: WidgetStateProperty.resolveWith((
          Set<WidgetState> states,
        ) {
          final bool selected = states.contains(WidgetState.selected);
          return _componentText(
            12,
            weight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
          );
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        minWidth: 68,
        labelType: NavigationRailLabelType.all,
        indicatorShape: pillShape,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        selectedIconTheme: IconThemeData(size: 19, color: scheme.primary),
        unselectedIconTheme: IconThemeData(
          size: 19,
          color: scheme.onSurfaceVariant,
        ),
        selectedLabelTextStyle: _componentText(
          12,
          weight: FontWeight.w600,
          color: scheme.primary,
        ),
        unselectedLabelTextStyle: _componentText(
          12,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  // 电视安全区：系统 insets 不足 48dp 时补到 48，已有的不叠加上去
  static const double televisionOverscan = 48;

  static EdgeInsets televisionPadding(EdgeInsets system) => EdgeInsets.fromLTRB(
    system.left < televisionOverscan ? televisionOverscan : system.left,
    system.top < televisionOverscan ? televisionOverscan : system.top,
    system.right < televisionOverscan ? televisionOverscan : system.right,
    system.bottom < televisionOverscan ? televisionOverscan : system.bottom,
  );

  static ButtonStyle _televisionFocusStyle(
    ButtonStyle? current,
    ColorScheme scheme,
  ) {
    final BorderSide focused = BorderSide(color: scheme.primary, width: 2);
    return (current ?? const ButtonStyle()).copyWith(
      side: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
        if (states.contains(WidgetState.focused)) {
          return focused;
        }
        return current?.side?.resolve(states);
      }),
      overlayColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
        if (states.contains(WidgetState.focused)) {
          return scheme.primary.withValues(alpha: 0.16);
        }
        return current?.overlayColor?.resolve(states);
      }),
    );
  }

  static ThemeData withTelevisionFocus(ThemeData base) {
    final ColorScheme scheme = base.colorScheme;
    return base.copyWith(
      focusColor: scheme.primary.withValues(alpha: 0.28),
      filledButtonTheme: FilledButtonThemeData(
        style: _televisionFocusStyle(base.filledButtonTheme.style, scheme),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: _televisionFocusStyle(base.outlinedButtonTheme.style, scheme),
      ),
      textButtonTheme: TextButtonThemeData(
        style: _televisionFocusStyle(base.textButtonTheme.style, scheme),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: _televisionFocusStyle(base.elevatedButtonTheme.style, scheme),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: _televisionFocusStyle(base.iconButtonTheme.style, scheme),
      ),
      listTileTheme: base.listTileTheme.copyWith(
        selectedColor: scheme.primary,
        selectedTileColor: scheme.primary.withValues(alpha: 0.14),
      ),
    );
  }
}

class _ThemedSelectionToolbar extends StatelessWidget {
  const _ThemedSelectionToolbar({required this.anchors, required this.items});

  static const double _screenPadding = 8;

  final TextSelectionToolbarAnchors anchors;
  final List<ContextMenuButtonItem> items;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PopupMenuThemeData popup = theme.popupMenuTheme;
    final double paddingAbove =
        MediaQuery.paddingOf(context).top + _screenPadding;
    final Offset origin = Offset(_screenPadding, paddingAbove);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        _screenPadding,
        paddingAbove,
        _screenPadding,
        _screenPadding,
      ),
      child: CustomSingleChildLayout(
        delegate: DesktopTextSelectionToolbarLayoutDelegate(
          anchor: anchors.primaryAnchor - origin,
        ),
        child: Material(
          color: popup.color ?? theme.colorScheme.surface,
          elevation: popup.elevation ?? 8,
          shadowColor: theme.shadowColor,
          shape:
              popup.shape ??
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTheme.menuRadius),
              ),
          clipBehavior: Clip.antiAlias,
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final ContextMenuButtonItem item in items)
                  TextButton(
                    style: ButtonStyle(
                      visualDensity: AppTheme._density,
                      side: const WidgetStatePropertyAll<BorderSide>(
                        BorderSide.none,
                      ),
                      alignment: Alignment.centerLeft,
                      padding: const WidgetStatePropertyAll<EdgeInsets>(
                        EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      ),
                      shape: WidgetStatePropertyAll<OutlinedBorder>(
                        RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            AppTheme.tileRadius,
                          ),
                        ),
                      ),
                      overlayColor: WidgetStatePropertyAll<Color>(
                        theme.colorScheme.primary.withValues(alpha: 0.08),
                      ),
                      foregroundColor: WidgetStatePropertyAll<Color>(
                        theme.colorScheme.onSurface,
                      ),
                      textStyle: WidgetStatePropertyAll<TextStyle>(
                        theme.textTheme.bodyMedium!,
                      ),
                    ),
                    onPressed: item.onPressed,
                    child: Text(
                      AdaptiveTextSelectionToolbar.getButtonLabel(
                        context,
                        item,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
