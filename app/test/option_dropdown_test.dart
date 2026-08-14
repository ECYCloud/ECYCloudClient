import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/option_dropdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child, {Alignment alignment = Alignment.center}) {
  return MaterialApp(
    theme: AppTheme.light().copyWith(platform: TargetPlatform.windows),
    home: Scaffold(
      body: Align(alignment: alignment, child: child),
    ),
  );
}

void main() {
  testWidgets('菜单展开在胶囊下方，不遮住收起态', (WidgetTester tester) async {
    String? picked;

    await tester.pumpWidget(
      _wrap(
        OptionDropdown<String>(
          value: 'system',
          options: const <String, String>{
            'system': '跟随系统',
            'light': '浅色',
            'dark': '深色',
          },
          onChanged: (String next) => picked = next,
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

    expect(
      tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns,
      0.5,
    );

    expect(tester.getRect(find.text('跟随系统').first), anchor);
    for (final String label in <String>['浅色', '深色']) {
      expect(tester.getRect(find.text(label)).top, greaterThan(anchor.bottom));
    }

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();

    expect(picked, 'dark');
    expect(find.text('浅色'), findsNothing);
  });

  testWidgets('靠右放置时菜单与触发框左右对齐且同宽', (WidgetTester tester) async {
    const double width = 120;
    const Key dropdownKey = Key('per-page');

    await tester.pumpWidget(
      _wrap(
        OptionDropdown<int>(
          key: dropdownKey,
          width: width,
          value: 10,
          options: const <int, String>{
            10: '每页 10 项',
            25: '每页 25 项',
            50: '每页 50 项',
            100: '每页 100 项',
          },
          onChanged: (_) {},
        ),
        alignment: Alignment.centerRight,
      ),
    );

    final Rect trigger = tester.getRect(find.byKey(dropdownKey));
    expect(trigger.width, width);

    await tester.tap(find.byKey(dropdownKey));
    await tester.pumpAndSettle();

    final Rect menuPanel = tester.getRect(
      find
          .ancestor(
            of: find.widgetWithText(MenuItemButton, '每页 25 项'),
            matching: find.byType(Material),
          )
          .first,
    );

    expect(
      menuPanel.left,
      closeTo(trigger.left, 0.5),
      reason: '菜单面板左缘应与触发框对齐',
    );
    expect(
      menuPanel.width,
      closeTo(trigger.width, 0.5),
      reason: '菜单面板应与触发框同宽',
    );
    expect(menuPanel.top, greaterThan(trigger.bottom));
  });

  testWidgets('ListToolbar 同款靠右+内边距时仍左右对齐', (WidgetTester tester) async {
    const double width = 120;
    const Key dropdownKey = Key('per-page-toolbar');
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(900, 640));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light().copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
            child: Align(
              alignment: Alignment.centerRight,
              child: OptionDropdown<int>(
                key: dropdownKey,
                width: width,
                value: 10,
                options: const <int, String>{
                  10: '每页 10 项',
                  25: '每页 25 项',
                  50: '每页 50 项',
                  100: '每页 100 项',
                },
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    final Rect trigger = tester.getRect(find.byKey(dropdownKey));
    expect(trigger.right, closeTo(900 - 14, 0.5));

    await tester.tap(find.byKey(dropdownKey));
    await tester.pumpAndSettle();

    final Rect menuPanel = tester.getRect(
      find
          .ancestor(
            of: find.widgetWithText(MenuItemButton, '每页 100 项'),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(menuPanel.left, closeTo(trigger.left, 0.5));
    expect(menuPanel.width, closeTo(trigger.width, 0.5));
  });
}
