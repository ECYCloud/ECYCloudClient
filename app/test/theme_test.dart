import 'dart:io' show Platform;

import 'package:ecycloud_client/ui/theme.dart';
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

  test('导航栏与 Tooltip 的文字样式同样带字族', () {
    final ThemeData theme = AppTheme.dark();

    expect(theme.tooltipTheme.textStyle?.fontFamily, expectedFamily);
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

  test('滚动条主题沿用公告的轴边距', () {
    final ScrollbarThemeData bar = AppTheme.light().scrollbarTheme;
    expect(bar.mainAxisMargin, 4);
    expect(bar.crossAxisMargin, 2);
    expect(AppTheme.overlayScrollPadding, const EdgeInsets.only(right: 16));
    expect(bar.interactive, isTrue);
  });
}
