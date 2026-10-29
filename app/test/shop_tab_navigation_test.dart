import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ecycloud_client/ui/shell_navigator.dart';

class _ShopTabProbe {
  bool mounted = true;

  void select(String tab) {
    if (!mounted) {
      return;
    }
  }
}

void main() {
  tearDown(() {
    ShellNavigator.takePendingShopTab();
  });

  testWidgets('商店页 dispose 后用新的 tear-off 解绑，再次跳转仍能落到流量包', (
    WidgetTester tester,
  ) async {
    void goTo(int index) {}
    ShellNavigator.bindHost(goTo);
    addTearDown(() => ShellNavigator.unbindHost(goTo));

    final _ShopTabProbe page = _ShopTabProbe();
    ShellNavigator.bindShopTab(page.select);
    addTearDown(() => ShellNavigator.unbindShopTab(page.select));
    page.mounted = false;
    ShellNavigator.unbindShopTab(page.select);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => ShellNavigator.openShopTraffic(context),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));

    expect(ShellNavigator.takePendingShopTab(), 'traffic_package');
  });

  test('实例方法 tear-off 不能用 identical 解绑', () {
    final _ShopTabProbe page = _ShopTabProbe();
    expect(identical(page.select, page.select), isFalse);
    expect(page.select == page.select, isTrue);
  });
}
