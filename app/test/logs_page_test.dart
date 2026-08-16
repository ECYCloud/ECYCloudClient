import 'dart:io';

import 'package:ecycloud_client/core/logger.dart';
import 'package:ecycloud_client/ui/pages/logs_page.dart';
import 'package:ecycloud_client/ui/widgets/search_field.dart';
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

  testWidgets('窄屏工具条完整落在屏幕内', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: LogsPage())),
    );

    expect(find.byType(SearchField), findsOneWidget);
    expect(find.byIcon(Icons.copy_all_outlined), findsOneWidget);

    // 级别条整条都要在视口内：塞进横向滚动条时它按自然宽度排版，末尾几档会被裁在屏幕外
    final Rect bar = tester.getRect(find.byType(SegmentedButton<LogLevel?>));
    expect(bar.left, greaterThanOrEqualTo(0));
    expect(bar.right, lessThanOrEqualTo(390));
    expect(_segment('error'), findsOneWidget);
  });

  test('日志储存路径在设置页展示，不在日志页', () {
    final String logs = File('lib/ui/pages/logs_page.dart').readAsStringSync();
    final String settings = File(
      'lib/ui/pages/settings_page.dart',
    ).readAsStringSync();

    expect(logs.contains("L10n.t('储存路径')"), isFalse);
    expect(logs.contains('AppPaths.logs'), isFalse);
    expect(settings.contains("L10n.t('储存路径')"), isTrue);
    expect(settings.contains('AppPaths.logs.path'), isTrue);
    expect(settings.contains("L10n.t('打开目录')"), isTrue);
    expect(settings.contains("L10n.t('复制路径')"), isFalse);
    expect(settings.contains('openDirectory'), isTrue);
  });

  testWidgets('silent 不出现在筛选里', (WidgetTester tester) async {
    await _pumpPage(tester);

    // 它只是内核的落盘门槛，没有条目会记在这一级，选中只会得到空列表
    expect(_segment('silent'), findsNothing);
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
