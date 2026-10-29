import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/television_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

Future<void> _pump(WidgetTester tester, Widget body) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.withTelevisionFocus(AppTheme.light()),
      builder: (BuildContext context, Widget? child) =>
          TelevisionNavigation(child: child!),
      home: Scaffold(body: body),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('焦点已在最后一个控件时，方向键继续滚动所在列表', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final FocusNode top = FocusNode();
    addTearDown(top.dispose);

    await _pump(
      tester,
      ListView(
        controller: controller,
        children: <Widget>[
          FilledButton(
            focusNode: top,
            onPressed: () {},
            child: const Text('唯一可聚焦控件'),
          ),
          // 只读内容：遥控器没有下一个焦点落点，不补滚动就彻底动不了
          for (int i = 0; i < 60; i++)
            SizedBox(height: 40, child: Text('第 $i 行')),
        ],
      ),
    );

    top.requestFocus();
    await tester.pumpAndSettle();
    expect(controller.position.pixels, 0);

    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(controller.position.pixels, greaterThan(0));

    final double reached = controller.position.pixels;
    await _key(tester, LogicalKeyboardKey.arrowUp);
    expect(controller.position.pixels, lessThan(reached));
  });

  testWidgets('筛选行在列表之外时，列表自己能被聚焦并滚动', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final FocusNode filter = FocusNode();
    addTearDown(filter.dispose);

    await _pump(
      tester,
      Column(
        children: <Widget>[
          FilledButton(
            focusNode: filter,
            onPressed: () {},
            child: const Text('筛选'),
          ),
          Expanded(
            child: TelevisionScrollFocus(
              controller: controller,
              child: ListView(
                controller: controller,
                children: <Widget>[
                  for (int i = 0; i < 60; i++)
                    SizedBox(height: 40, child: Text('第 $i 行')),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    filter.requestFocus();
    await tester.pumpAndSettle();

    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<TelevisionScrollFocus>(),
      isNotNull,
      reason: '焦点必须能落到列表这片区域上',
    );

    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(controller.position.pixels, greaterThan(0), reason: '聚焦列表后下键要滚动');

    // 滚到底之后不再拦键，焦点应当能离开列表
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await _key(tester, LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      controller.position.pixels,
      lessThan(controller.position.maxScrollExtent),
    );
  });

  testWidgets('非电视设备不给列表加焦点落点', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // 不套 TelevisionNavigation，即普通桌面 / 手机
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: TelevisionScrollFocus(
            controller: controller,
            child: ListView(
              controller: controller,
              children: <Widget>[
                for (int i = 0; i < 60; i++)
                  SizedBox(height: 40, child: Text('第 $i 行')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(controller.position.pixels, 0, reason: '没有遥控器时这片区域不该成为焦点落点，也不该接管滚动');
  });
}
