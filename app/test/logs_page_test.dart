import 'package:ecycloud_client/core/logger.dart';
import 'package:ecycloud_client/ui/pages/logs_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 级别一律取 info 及以下：Logger 的落盘门槛默认是 warn，测试因此不碰磁盘
void main() {
  testWidgets('新日志按节流间隔自己出现在列表里', (WidgetTester tester) async {
    await _pumpPage(tester);

    Logger.instance.info('测试', '实时更新探针');
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('实时更新探针'), findsOneWidget);
  });

  testWidgets('按级别筛选只出该级别，不带出更高级别', (WidgetTester tester) async {
    await _pumpPage(tester);

    Logger.instance.info('测试', '一条 info');
    Logger.instance.debug('测试', '一条 debug');
    await tester.pump(const Duration(milliseconds: 500));

    // 列表行里的级别角标也叫 debug，只点工具条上的那个
    await tester.tap(_segment('debug'));
    await tester.pumpAndSettle();

    expect(find.text('一条 debug'), findsOneWidget);
    expect(find.text('一条 info'), findsNothing);

    await tester.tap(_segment('全部'));
    await tester.pumpAndSettle();

    expect(find.text('一条 debug'), findsOneWidget);
    expect(find.text('一条 info'), findsOneWidget);
  });
}

// 默认 800x600 的测试画布比实际窗口窄，工具条挤不开会盖掉要验的行为
Future<void> _pumpPage(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(const MaterialApp(home: Scaffold(body: LogsPage())));
}

Finder _segment(String label) => find.descendant(
  of: find.byType(SegmentedButton<LogLevel?>),
  matching: find.text(label),
);
