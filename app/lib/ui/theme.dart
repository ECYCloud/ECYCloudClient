import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/logger.dart';

class AppTheme {
  AppTheme._();

  static const Color seed = Color(0xFF2F6BFF);
  static const Color success = Color(0xFF2FBF71);
  static const Color warning = Color(0xFFE0A800);
  static const Color danger = Color(0xFFE5484D);

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

  static ButtonStyle _tonalPill(ColorScheme scheme) =>
      FilledButton.styleFrom(
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        disabledBackgroundColor: Colors.transparent,
        disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.38),
        shape: pillShape,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        textStyle: _componentText(13, weight: FontWeight.w600),
      ).copyWith(
        side: WidgetStateProperty<BorderSide>.fromMap(
          <WidgetStatesConstraint, BorderSide>{
            WidgetState.disabled: BorderSide(
              color: scheme.onSurface.withValues(alpha: 0.12),
            ),
            WidgetState.any: BorderSide(color: scheme.outline),
          },
        ),
      );

  static const double cardRadius = 12;
  static const double tileRadius = 9;

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
      bodySmall: TextStyle(
        fontFamily: _fontFamily,
        fontSize: 12,
        color: scheme.onSurfaceVariant,
      ),
      labelLarge: style(12, FontWeight.w600),
      labelMedium: style(12, FontWeight.w500),
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
      textTheme: _textTheme(scheme),
      // 全端同一密度：按平台分档会让 Android 的按钮、输入框、列表行比桌面各高一档
      visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
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
          shape: pillShape,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
          textStyle: _componentText(13, weight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(style: _tonalPill(scheme)),
      textButtonTheme: TextButtonThemeData(style: _tonalPill(scheme)),
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
          backgroundColor: Colors.transparent,
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
            12,
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
