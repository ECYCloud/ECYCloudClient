import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/option_dropdown.dart';
import 'package:ecycloud_client/ui/widgets/television_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

bool _focusedInside<T extends Widget>() {
  final BuildContext? context = FocusManager.instance.primaryFocus?.context;
  return context != null && context.findAncestorWidgetOfExactType<T>() != null;
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('电视遥控器可以打开下拉菜单并选到其中一项', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.withTelevisionFocus(AppTheme.light()),
        builder: (BuildContext context, Widget? child) =>
            TelevisionNavigation(child: child!),
        home: Scaffold(
          body: Center(
            child: OptionDropdown<String>(
              value: 'a',
              options: const <String, String>{'a': '甲', 'b': '乙', 'c': '丙'},
              onChanged: (String next) => picked = next,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    FocusManager.instance.primaryFocus?.nextFocus();
    await tester.pumpAndSettle();
    expect(_focusedInside<OptionDropdown<String>>(), isTrue, reason: '先落在触发器上');

    await _key(tester, LogicalKeyboardKey.select);
    expect(find.byType(MenuItemButton), findsNWidgets(3));
    expect(
      _focusedInside<MenuItemButton>(),
      isTrue,
      reason: '菜单打开后焦点必须进入菜单，否则遥控器选不到任何一项',
    );

    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.select);
    expect(picked, isNotNull, reason: '遥控器必须能确认某一项');
  });

  testWidgets('下拉菜单关闭后焦点回到触发器', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.withTelevisionFocus(AppTheme.light()),
        builder: (BuildContext context, Widget? child) =>
            TelevisionNavigation(child: child!),
        home: Scaffold(
          body: Center(
            child: OptionDropdown<String>(
              value: 'a',
              options: const <String, String>{'a': '甲', 'b': '乙'},
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    FocusManager.instance.primaryFocus?.nextFocus();
    await tester.pumpAndSettle();
    await _key(tester, LogicalKeyboardKey.select);
    expect(_focusedInside<MenuItemButton>(), isTrue);

    await _key(tester, LogicalKeyboardKey.escape);
    expect(find.byType(MenuItemButton), findsNothing);
    expect(
      _focusedInside<OptionDropdown<String>>(),
      isTrue,
      reason: '菜单收起后焦点不能丢，否则遥控器之后按什么都没反应',
    );
  });
}
