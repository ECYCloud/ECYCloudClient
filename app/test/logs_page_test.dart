import 'dart:io';

import 'package:ecycloud_client/core/logger.dart';
import 'package:ecycloud_client/ui/node_labels.dart';
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

    expect(_segment('silent'), findsNothing);
  });

  testWidgets('内核日志把 node-{id} 显示成节点名', (WidgetTester tester) async {
    NodeLabels.configure(r'/[\p{L}\p{N}]+/u', <String, String>{
      'node-120': '🇭🇰 香港 01',
    });
    addTearDown(() => NodeLabels.configure(r'/[\p{L}\p{N}]+/u'));

    await _pumpPage(tester);

    Logger.instance.info(
      'mihomo',
      Logger.kernelMessage(
        'time="2026-08-20T18:38:55+08:00" level=info '
        'msg="[TCP] 198.18.0.1:23016(ECYCloud.exe) --> owo.ecycloud.com:443 '
        'match Match using 主节点[node-120]"',
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.textContaining('主节点[香港 01]'), findsOneWidget);
    expect(find.textContaining('node-120'), findsNothing);
  });
}

// 默认 800x600 测试画布比实际窗口窄，会盖掉要验的行为
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
