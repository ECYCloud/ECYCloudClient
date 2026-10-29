import 'dart:io' show Platform;
import 'dart:math' show min, sqrt;
import 'dart:ui' as ui;

import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/option_dropdown.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// 组件主题给的 TextStyle 会整体顶掉控件默认样式，不与 textTheme 逐字段合并，
// 因此这些样式必须自带字族；漏掉的话控件里的中文会落到引擎默认字体上。
void main() {
  // 字族来自系统而不是代码，断言里不写死字体名：假装系统报这个名字，再看它有没有
  // 被送到每一处组件样式上。非 Windows 本就不指定字族，期望值即为 null。
  const String systemFont = '测试界面字体';
  const String systemMonoFont = '测试等宽字体';
  final String? expectedFamily = Platform.isWindows ? systemFont : null;
  final String? expectedMono = Platform.isWindows ? systemMonoFont : null;

  // 主题只构建一次，注入必须赶在任何 AppTheme 调用之前
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('ecycloud/platform'),
          (MethodCall call) async => call.method == 'ui.fonts'
              ? <Object?, Object?>{'ui': systemFont, 'mono': systemMonoFont}
              : null,
        );
    await AppTheme.loadSystemUiFont();
  });

  String? familyOf(WidgetTester tester, String text) => tester
      .renderObject<RenderParagraph>(find.text(text))
      .text
      .style
      ?.fontFamily;

  testWidgets('按钮与分段控件的文字用界面字体', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              SegmentedButton<int>(
                segments: const <ButtonSegment<int>>[
                  ButtonSegment<int>(value: 0, label: Text('直连')),
                  ButtonSegment<int>(value: 1, label: Text('规则')),
                ],
                selected: const <int>{0},
                showSelectedIcon: false,
                onSelectionChanged: (_) {},
              ),
              FilledButton(onPressed: () {}, child: const Text('立即连接')),
              TextButton(onPressed: () {}, child: const Text('取消')),
            ],
          ),
        ),
      ),
    );

    for (final String label in <String>['直连', '立即连接', '取消']) {
      expect(familyOf(tester, label), expectedFamily, reason: label);
    }
  });

  testWidgets('普通按钮等高，相同文案的填充和描边按钮等宽', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              FilledButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text('连接'),
              ),
              FilledButton(
                key: const Key('filled'),
                onPressed: () {},
                child: const Text('确定'),
              ),
              TextButton(
                key: const Key('text'),
                onPressed: () {},
                child: const Text('确定'),
              ),
              OutlinedButton(
                key: const Key('outlined'),
                onPressed: () {},
                child: const Text('确定'),
              ),
              RepaintBoundary(
                key: const Key('segments-paint'),
                child: SegmentedButton<int>(
                  segments: const <ButtonSegment<int>>[
                    ButtonSegment<int>(value: 0, label: Text('今日')),
                    ButtonSegment<int>(value: 1, label: Text('昨日')),
                  ],
                  selected: const <int>{0},
                  showSelectedIcon: false,
                  onSelectionChanged: (_) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    for (final String label in <String>['连接']) {
      final Finder button = find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate(
          (Widget widget) => widget is ButtonStyleButton,
        ),
      );
      final Finder material = find.descendant(
        of: button,
        matching: find.byType(Material),
      );
      expect(tester.getSize(material).height, 32, reason: label);
    }
    final List<Size> sizes = <Size>[
      for (final String key in <String>['filled', 'text', 'outlined'])
        tester.getSize(
          find.descendant(
            of: find.byKey(Key(key)),
            matching: find.byType(Material),
          ),
        ),
    ];
    expect(
      sizes.every(
        (Size size) => size.height == 32 && size.width == sizes.first.width,
      ),
      isTrue,
    );
    final RenderRepaintBoundary boundary = tester
        .renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('segments-paint')),
        );
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1);
      try {
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final int color = AppTheme.dark().colorScheme.onSurface.toARGB32();
        final List<int> rows = <int>[];
        for (int y = 0; y < image.height; y++) {
          final int offset = (y * image.width + image.width ~/ 4) * 4;
          if (data.getUint8(offset) == (color >> 16 & 255) &&
              data.getUint8(offset + 1) == (color >> 8 & 255) &&
              data.getUint8(offset + 2) == (color & 255) &&
              data.getUint8(offset + 3) == 255) {
            rows.add(y);
          }
        }
        expect(
          rows.last - rows.first + 1,
          32,
          reason: '测量分段按钮实际绘制的外框和填充，不把透明触控留白算进去',
        );
      } finally {
        image.dispose();
      }
    });
  });

  test('分段按钮未选中跟主题 CTA，不用强调色', () {
    void expectCta(ThemeData theme) {
      final ButtonStyle? style = theme.segmentedButtonTheme.style;
      expect(
        style?.foregroundColor?.resolve(const <WidgetState>{}),
        theme.colorScheme.onSurface,
      );
      expect(
        style?.foregroundColor?.resolve(const <WidgetState>{
          WidgetState.selected,
        }),
        theme.colorScheme.surface,
      );
      expect(
        style?.backgroundColor?.resolve(const <WidgetState>{
          WidgetState.selected,
        }),
        theme.colorScheme.onSurface,
      );
      expect(
        style?.backgroundColor?.resolve(const <WidgetState>{
          WidgetState.hovered,
        }),
        Colors.transparent,
      );
      expect(
        style?.foregroundColor?.resolve(const <WidgetState>{
          WidgetState.hovered,
        }),
        theme.colorScheme.onSurface,
      );
      expect(
        style?.overlayColor?.resolve(const <WidgetState>{WidgetState.hovered}),
        theme.textButtonTheme.style?.overlayColor?.resolve(const <WidgetState>{
          WidgetState.hovered,
        }),
      );
    }

    expectCta(AppTheme.light());
    expectCta(AppTheme.dark());
  });

  testWidgets('分段按钮悬停保持原文字色', (WidgetTester tester) async {
    final ThemeData theme = AppTheme.dark();
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: SegmentedButton<int>(
            segments: const <ButtonSegment<int>>[
              ButtonSegment<int>(value: 0, label: Text('套餐')),
              ButtonSegment<int>(value: 1, label: Text('流量包')),
            ],
            selected: const <int>{1},
            showSelectedIcon: false,
            onSelectionChanged: (_) {},
          ),
        ),
      ),
    );

    Material materialOf(String label) {
      final Finder button = find.ancestor(
        of: find.text(label),
        matching: find.byType(TextButton),
      );
      return tester.widget<Material>(
        find.descendant(of: button, matching: find.byType(Material)),
      );
    }

    expect(materialOf('套餐').color, Colors.transparent);
    expect(materialOf('流量包').color, theme.colorScheme.onSurface);

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      pointer: 1,
    );
    addTearDown(mouse.removePointer);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(find.text('套餐')));
    await tester.pump();

    expect(materialOf('套餐').color, Colors.transparent);
    expect(materialOf('套餐').textStyle?.color, theme.colorScheme.onSurface);
    expect(materialOf('流量包').color, theme.colorScheme.onSurface);
  });

  test('文字不带描边，卡片不二次抗锯齿', () {
    final ThemeData theme = AppTheme.light();
    expect(theme.textTheme.bodyLarge?.fontSize, 13);
    expect(theme.textTheme.bodyMedium?.fontSize, 13);
    expect(theme.textTheme.bodySmall?.fontSize, 12);
    expect(theme.textTheme.bodyLarge?.fontWeight, FontWeight.w400);
    expect(theme.textTheme.titleSmall?.fontWeight, FontWeight.w600);
    expect(theme.textTheme.bodyLarge?.shadows ?? const <Shadow>[], isEmpty);
    expect(theme.textTheme.bodySmall?.shadows ?? const <Shadow>[], isEmpty);
    expect(
      theme.inputDecorationTheme.hintStyle?.shadows ?? const <Shadow>[],
      isEmpty,
    );
    expect(theme.cardTheme.clipBehavior, Clip.hardEdge);
  });

  test('导航栏与 Tooltip 的文字样式同样带字族', () {
    final ThemeData theme = AppTheme.dark();

    expect(theme.tooltipTheme.textStyle?.fontFamily, expectedFamily);
    expect(
      theme.navigationBarTheme.labelTextStyle?.resolve(const <WidgetState>{
        WidgetState.selected,
      })?.fontFamily,
      expectedFamily,
    );
    expect(
      theme.navigationBarTheme.labelTextStyle
          ?.resolve(const <WidgetState>{})
          ?.fontFamily,
      expectedFamily,
    );
    expect(
      theme.navigationRailTheme.selectedLabelTextStyle?.fontFamily,
      expectedFamily,
    );
    expect(
      theme.navigationRailTheme.unselectedLabelTextStyle?.fontFamily,
      expectedFamily,
    );
  });

  test('等宽字体同样来自系统，代码里不写死字体名', () {
    expect(AppTheme.monoFontFamily, expectedMono);
  });

  test('电视安全区只补不足 48 的边，已有的不叠加', () {
    expect(
      AppTheme.televisionPadding(EdgeInsets.zero),
      const EdgeInsets.all(48),
    );
    expect(
      AppTheme.televisionPadding(const EdgeInsets.fromLTRB(10, 60, 0, 48)),
      const EdgeInsets.fromLTRB(48, 60, 48, 48),
    );
  });

  test('电视焦点主题不改密度与触控盒', () {
    final ThemeData base = AppTheme.light();
    final ThemeData tv = AppTheme.withTelevisionFocus(base);
    expect(tv.visualDensity, base.visualDensity);
    expect(tv.focusColor, isNot(base.focusColor));
  });

  testWidgets('单行输入框与下拉框同高，端口框与下拉框同宽', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  width: 320,
                  child: TextField(
                    key: const Key('plain-field'),
                    decoration: AppTheme.controlDecoration(hintText: '规则集 URL'),
                  ),
                ),
                const SizedBox(height: 8),
                OptionDropdown<String>(
                  key: const Key('plain-drop'),
                  value: 'DIRECT',
                  options: const <String, String>{'DIRECT': 'DIRECT'},
                  onChanged: (_) {},
                  width: 320,
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: AppTheme.controlWidth,
                  height: AppTheme.controlHeight,
                  child: TextField(
                    key: const Key('port-field'),
                    decoration: AppTheme.controlDecoration(
                      constraints: const BoxConstraints.tightFor(
                        width: AppTheme.controlWidth,
                        height: AppTheme.controlHeight,
                      ),
                    ),
                  ),
                ),
                OptionDropdown<String>(
                  key: const Key('port-drop'),
                  value: '浅色',
                  options: const <String, String>{'浅色': '浅色'},
                  onChanged: (_) {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Size borderOf(Key key) {
      return tester.getSize(
        find.descendant(
          of: find.byKey(key),
          matching: find.byWidgetPredicate(
            (Widget w) => w.runtimeType.toString() == '_BorderContainer',
          ),
        ),
      );
    }

    final Size urlField = borderOf(const Key('plain-field'));
    final Size urlDrop = tester.getSize(find.byKey(const Key('plain-drop')));
    expect(urlField.height, urlDrop.height);
    expect(urlField.height, AppTheme.controlHeight);

    final Size portField = borderOf(const Key('port-field'));
    final Size portDrop = tester.getSize(find.byKey(const Key('port-drop')));
    expect(portField.height, portDrop.height);
    expect(portField.width, portDrop.width);
    expect(portField.width, AppTheme.controlWidth);
  });

  test('输入框焦点描边与下拉框同宽', () {
    final ThemeData theme = AppTheme.light();
    final OutlineInputBorder focused =
        theme.inputDecorationTheme.focusedBorder! as OutlineInputBorder;
    final OutlineInputBorder enabled =
        theme.inputDecorationTheme.enabledBorder! as OutlineInputBorder;
    expect(focused.borderSide.width, enabled.borderSide.width);
    expect(focused.borderSide.width, 1);
  });

  test('滚动条主题沿用公告的轴边距', () {
    final ScrollbarThemeData bar = AppTheme.light().scrollbarTheme;
    expect(bar.mainAxisMargin, 4);
    expect(bar.crossAxisMargin, 2);
    expect(AppTheme.overlayScrollPadding, const EdgeInsets.only(right: 16));
    expect(bar.interactive, isTrue);
  });

  test('圆角容器里的滚动条：拇指贴右缘，两端让开圆角弧', () {
    final ThemeData theme = AppTheme.light();
    final ScrollbarThemeData base = theme.scrollbarTheme;
    const double radius = AppTheme.menuRadius;
    final ScrollbarThemeData bar = AppTheme.scrollbarInsideRadius(
      theme,
      radius,
    );

    expect(bar.crossAxisMargin, 0, reason: '拇指贴容器右缘，右侧不留缝');
    expect(bar.thickness, base.thickness);
    expect(bar.interactive, base.interactive);

    final double thickness = base.thickness!.resolve(<WidgetState>{})!;
    final double cap = min(base.radius!.x, thickness / 2);
    expect(bar.mainAxisMargin, radius - cap);

    final double dx = radius - bar.crossAxisMargin! - cap;
    final double dy = radius - bar.mainAxisMargin! - cap;
    expect(sqrt(dx * dx + dy * dy), lessThanOrEqualTo(radius - cap));
  });
}
