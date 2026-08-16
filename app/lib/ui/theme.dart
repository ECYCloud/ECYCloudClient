import 'dart:io' show Platform;

import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  static const Color seed = Color(0xFF2F6BFF);
  static const Color success = Color(0xFF2FBF71);
  static const Color warning = Color(0xFFE0A800);
  static const Color danger = Color(0xFFE5484D);

  // 全局按钮圆角：胶囊形
  static const OutlinedBorder pillShape = StadiumBorder();

  static ButtonStyle inlineTextLink(ColorScheme scheme, {Color? color}) {
    final Color foreground = color ?? scheme.primary;
    return TextButton.styleFrom(
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      foregroundColor: foreground,
      textStyle: _componentText(13).copyWith(
        decoration: TextDecoration.underline,
        decorationColor: foreground,
      ),
    );
  }

  // 卡片与卡片内小块的圆角，成套用才不会看起来东拼西凑
  static const double cardRadius = 12;
  static const double tileRadius = 9;

  // Switch 的轨道尺寸由 Material 写死（M3 为 52×32），主题里改不动，
  // 只能整体缩放；桌面端按 0.8 收到约 42×26
  static const double switchScale = 0.8;

  // 雅黑 UI 只在 Windows 上存在。Android / 鸿蒙 / WSA / macOS / Linux 强制指定
  // 会走到残缺回退链，中文易糊、缺字或度量错乱，宽屏切换时更像「看不清」。
  static final bool _windowsUiFont = Platform.isWindows;
  static final String? _fontFamily =
      _windowsUiFont ? 'Microsoft YaHei UI' : null;
  static final List<String> _fontFamilyFallback = _windowsUiFont
      ? const <String>['Microsoft YaHei', 'Segoe UI']
      : const <String>[];

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
    fontFamilyFallback: _fontFamilyFallback,
    fontSize: size,
    fontWeight: weight,
    color: color,
  );

  // ColorScheme.fromSeed 开销不低，而 MaterialApp 会随设置变更反复重建
  static final ThemeData _light = _build(Brightness.light);
  static final ThemeData _dark = _build(Brightness.dark);

  static ThemeData light() => _light;

  static ThemeData dark() => _dark;

  // Material 的字阶按移动端触摸场景设定，桌面上普遍大一到两号。
  // 这里显式给全字阶定尺寸，不用 TextTheme.apply(fontSizeDelta:)：
  // ThemeData.textTheme 的各项 fontSize 实际为 null（尺寸在渲染期由字体度量补全），
  // apply 对 null 不生效，debug 下还会直接触发 fontSize != null 断言。
  static TextTheme _textTheme(ColorScheme scheme) {
    TextStyle style(double size, [FontWeight weight = FontWeight.w400]) =>
        TextStyle(
          fontFamily: _fontFamily,
          fontFamilyFallback: _fontFamilyFallback,
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
      bodyMedium: style(12),
      bodySmall: TextStyle(
        fontFamily: _fontFamily,
        fontFamilyFallback: _fontFamilyFallback,
        fontSize: 11,
        color: scheme.onSurfaceVariant,
      ),
      labelLarge: style(12, FontWeight.w600),
      labelMedium: style(11, FontWeight.w500),
      labelSmall: style(10, FontWeight.w500),
    );
  }

  static ThemeData _build(Brightness brightness) {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      fontFamily: _fontFamily,
      fontFamilyFallback: _fontFamilyFallback,
      textTheme: _textTheme(scheme),
      // 桌面端收紧留白；Android / iOS 保持默认触摸密度，避免平板上更挤更难辨认
      visualDensity: Platform.isAndroid || Platform.isIOS
          ? VisualDensity.standard
          : const VisualDensity(horizontal: -2, vertical: -2),
      // 底色比卡片更沉一档：卡片靠明度差浮出来，不靠描边和投影
      scaffoldBackgroundColor: brightness == Brightness.dark
          ? scheme.surfaceContainerLowest
          : scheme.surfaceContainer,
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
      dividerTheme: DividerThemeData(
        space: 1,
        thickness: 1,
        color: scheme.outlineVariant.withValues(alpha: 0.7),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        border: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(999)),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(999)),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(999)),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        hintStyle: _componentText(12, color: scheme.onSurfaceVariant),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        linearMinHeight: 5,
        borderRadius: BorderRadius.circular(3),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll<double>(7),
        radius: const Radius.circular(4),
        thumbColor:
            WidgetStateProperty<Color>.fromMap(<WidgetStatesConstraint, Color>{
              WidgetState.hovered: scheme.outline.withValues(alpha: 0.6),
              WidgetState.any: scheme.outlineVariant,
            }),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: pillShape,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
          textStyle: _componentText(13, weight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: pillShape,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          textStyle: _componentText(13, weight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: pillShape,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          textStyle: _componentText(13, weight: FontWeight.w600),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          shape: pillShape,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          textStyle: _componentText(13, weight: FontWeight.w600),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          shape: pillShape,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          textStyle: _componentText(12, weight: FontWeight.w600),
          selectedBackgroundColor: scheme.primary,
          selectedForegroundColor: scheme.onPrimary,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(iconSize: 20, shape: pillShape),
      ),
      listTileTheme: const ListTileThemeData(
        minVerticalPadding: 6,
        horizontalTitleGap: 10,
      ),
      switchTheme: const SwitchThemeData(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        // M3 开关的状态层半径固定 20，套在缩小后的开关上就是一坨比开关还大的
        // 灰色光斑；开关本身有轨道与滑块的颜色变化作反馈，不需要再叠一层
        overlayColor: WidgetStatePropertyAll<Color>(Colors.transparent),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 560),
      ),
      appBarTheme: AppBarTheme(
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
        labelTextStyle: WidgetStateProperty.resolveWith((
          Set<WidgetState> states,
        ) {
          final bool selected = states.contains(WidgetState.selected);
          return _componentText(
            11,
            weight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
          );
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: brightness == Brightness.dark
            ? scheme.surfaceContainerLowest
            : scheme.surfaceContainer,
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
          11,
          weight: FontWeight.w600,
          color: scheme.primary,
        ),
        unselectedLabelTextStyle: _componentText(
          11,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
