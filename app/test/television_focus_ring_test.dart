import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/television_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Finder _ring() => find.byWidgetPredicate((Widget widget) {
  if (widget is! DecoratedBox) {
    return false;
  }
  final Decoration decoration = widget.decoration;
  return decoration is BoxDecoration &&
      decoration.border != null &&
      decoration.boxShadow != null;
}, description: '电视焦点轮廓');

Future<void> _pump(WidgetTester tester, Widget control) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.withTelevisionFocus(AppTheme.light()),
      builder: (BuildContext context, Widget? child) =>
          TelevisionNavigation(child: child!),
      home: Scaffold(body: Center(child: control)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  final Map<String, Widget Function(FocusNode)> controls =
      <String, Widget Function(FocusNode)>{
        'ListTile': (FocusNode node) =>
            ListTile(focusNode: node, onTap: () {}, title: const Text('行')),
        'InkWell': (FocusNode node) => InkWell(
          focusNode: node,
          onTap: () {},
          child: const SizedBox(width: 160, height: 48),
        ),
        'Switch': (FocusNode node) =>
            Switch(focusNode: node, value: false, onChanged: (_) {}),
        'Checkbox': (FocusNode node) =>
            Checkbox(focusNode: node, value: false, onChanged: (_) {}),
        'FilledButton': (FocusNode node) => FilledButton(
          focusNode: node,
          onPressed: () {},
          child: const Text('按钮'),
        ),
        'TextButton': (FocusNode node) => TextButton(
          focusNode: node,
          onPressed: () {},
          child: const Text('链接'),
        ),
        'IconButton': (FocusNode node) => IconButton(
          focusNode: node,
          onPressed: () {},
          icon: const Icon(Icons.refresh),
        ),
      };

  for (final MapEntry<String, Widget Function(FocusNode)> entry
      in controls.entries) {
    testWidgets('电视焦点轮廓覆盖 ${entry.key}', (WidgetTester tester) async {
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      await _pump(tester, entry.value(node));

      expect(_ring(), findsNothing, reason: '未聚焦时不该有轮廓');

      node.requestFocus();
      await tester.pumpAndSettle();
      expect(_ring(), findsOneWidget, reason: '${entry.key} 聚焦后必须有轮廓');

      node.unfocus();
      await tester.pumpAndSettle();
      expect(_ring(), findsNothing, reason: '失焦后轮廓必须撤掉');
    });
  }

  testWidgets('轮廓贴着被聚焦控件而不是整屏', (WidgetTester tester) async {
    final FocusNode node = FocusNode();
    addTearDown(node.dispose);
    await _pump(
      tester,
      FilledButton(focusNode: node, onPressed: () {}, child: const Text('连接')),
    );
    node.requestFocus();
    await tester.pumpAndSettle();

    final Rect button = tester.getRect(find.byType(FilledButton));
    final Rect ring = tester.getRect(_ring());
    expect(ring.contains(button.topLeft + const Offset(2, 2)), isTrue);
    expect(ring.contains(button.bottomRight - const Offset(2, 2)), isTrue);
    expect(ring.width, lessThan(button.width + 40));
    expect(ring.height, lessThan(button.height + 40));
  });

  testWidgets('非电视设备不挂电视焦点层', (WidgetTester tester) async {
    final FocusNode node = FocusNode();
    addTearDown(node.dispose);
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: FilledButton(
              focusNode: node,
              onPressed: () {},
              child: const Text('连接'),
            ),
          ),
        ),
      ),
    );
    node.requestFocus();
    await tester.pumpAndSettle();
    expect(_ring(), findsNothing);
  });
}
