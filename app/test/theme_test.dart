import 'package:ecycloud_client/ui/theme.dart';
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
