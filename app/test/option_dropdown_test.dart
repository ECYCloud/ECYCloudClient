import 'package:ecycloud_client/ui/widgets/option_dropdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('菜单展开在胶囊下方，不遮住收起态', (WidgetTester tester) async {
    String? picked;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: OptionDropdown<String>(
              value: 'system',
              options: const <String, String>{
                'system': '跟随系统',
                'light': '浅色',
                'dark': '深色',
              },
              onChanged: (String next) => picked = next,
            ),
          ),
        ),
      ),
    );

    final Rect anchor = tester.getRect(find.text('跟随系统'));
    expect(
      tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns,
      0,
    );

    await tester.tap(find.text('跟随系统'));
    await tester.pumpAndSettle();

    // 展开时箭头必须翻成向上
    expect(
      tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns,
      0.5,
    );

    // 展开后收起态文本仍在原位，菜单项整体落在它下面
    expect(tester.getRect(find.text('跟随系统').first), anchor);
    for (final String label in <String>['浅色', '深色']) {
      expect(tester.getRect(find.text(label)).top, greaterThan(anchor.bottom));
    }

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();

    expect(picked, 'dark');
    expect(find.text('浅色'), findsNothing);
  });
}
