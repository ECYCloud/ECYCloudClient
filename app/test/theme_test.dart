import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/section_card.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

// 组件主题给的 TextStyle 会整体顶掉控件默认样式，不与 textTheme 逐字段合并，
// 因此这些样式必须自带字族；漏掉的话控件里的中文会落到引擎默认字体上。
void main() {
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
      expect(familyOf(tester, label), 'Microsoft YaHei UI', reason: label);
    }
  });

  // 内联链接的文字盒子只有十几逻辑像素高，手指按下点又偏向接触面下缘：
  // 少了最小高度、或卡片标题行把高度写死，链接的下半截就点不动
  testWidgets('卡片标题行里的内联链接有可点高度', (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SectionCard(
            icon: Icons.pie_chart_outline,
            title: '流量使用情况',
            action: Builder(
              builder: (BuildContext context) => TextButton(
                style: AppTheme.inlineTextLink(Theme.of(context).colorScheme),
                onPressed: () => taps++,
                child: const Text('流量明细 ›'),
              ),
            ),
            child: const Text('内容'),
          ),
        ),
      ),
    );

    final Rect link = tester.getRect(find.widgetWithText(TextButton, '流量明细 ›'));
    expect(link.height, greaterThanOrEqualTo(32));
    expect(
      link.height,
      greaterThan(tester.getRect(find.text('流量明细 ›')).height),
    );

    await tester.tapAt(Offset(link.center.dx, link.bottom - 1));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('触摸设备上各类按钮的下缘也能点中', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      int filled = 0;
      int text = 0;
      int icon = 0;
      int link = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Column(
              children: <Widget>[
                FilledButton(
                  onPressed: () => filled++,
                  child: const Text('连接'),
                ),
                TextButton(onPressed: () => text++, child: const Text('取消')),
                IconButton(
                  onPressed: () => icon++,
                  icon: const Icon(Icons.refresh),
                  constraints: AppTheme.iconActionBox(),
                ),
                SectionCard(
                  title: '流量使用情况',
                  action: Builder(
                    builder: (BuildContext context) => TextButton(
                      style: AppTheme.inlineTextLink(
                        Theme.of(context).colorScheme,
                      ),
                      onPressed: () => link++,
                      child: const Text('流量明细 ›'),
                    ),
                  ),
                  child: const Text('内容'),
                ),
              ],
            ),
          ),
        ),
      );

      Future<void> tapBottom(Finder finder) async {
        final Rect box = tester.getRect(finder);
        expect(box.height, greaterThanOrEqualTo(kMinInteractiveDimension));
        await tester.tapAt(Offset(box.center.dx, box.bottom - 1));
        await tester.pump();
      }

      await tapBottom(find.widgetWithText(FilledButton, '连接'));
      await tapBottom(find.widgetWithText(TextButton, '取消'));
      await tapBottom(find.widgetWithIcon(IconButton, Icons.refresh));
      await tapBottom(find.widgetWithText(TextButton, '流量明细 ›'));
      expect(filled, 1);
      expect(text, 1);
      expect(icon, 1);
      expect(link, 1);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('导航栏与 Tooltip 的文字样式同样带字族', () {
    final ThemeData theme = AppTheme.dark();

    expect(theme.tooltipTheme.textStyle?.fontFamily, 'Microsoft YaHei UI');
    expect(
      theme.navigationRailTheme.selectedLabelTextStyle?.fontFamily,
      'Microsoft YaHei UI',
    );
    expect(
      theme.navigationRailTheme.unselectedLabelTextStyle?.fontFamily,
      'Microsoft YaHei UI',
    );
  });
}
