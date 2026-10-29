import 'dart:io';

import 'package:ecycloud_client/core/logger.dart';
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/state/announcement_controller.dart';
import 'package:ecycloud_client/state/auth_controller.dart';
import 'package:ecycloud_client/state/connection_controller.dart';
import 'package:ecycloud_client/state/update_controller.dart';
import 'package:ecycloud_client/ui/app_scope.dart';
import 'package:ecycloud_client/ui/node_labels.dart';
import 'package:ecycloud_client/ui/pages/logs_page.dart';
import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/search_field.dart';
import 'package:ecycloud_client/ui/widgets/tag_chip.dart';
import 'package:ecycloud_client/ui/widgets/app_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 级别一律取 info 及以下：Logger 的落盘门槛默认是 warn，测试因此不碰磁盘
void main() {
  testWidgets('内核连接日志按源地址标出入站类型', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _scoped(
        const MaterialApp(home: AppScaffold(body: LogsPage())),
        _Connection(
          connections: <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'c1',
              'metadata': <String, dynamic>{
                'sourceIP': '198.18.0.1',
                'sourcePort': '61593',
                'type': 'Tun',
              },
            },
          ],
        ),
      ),
    );

    Logger.instance.info(
      '内核',
      '[TCP] 198.18.0.1:61593 --> example.com:443 match Match using DIRECT',
    );
    Logger.instance.info(
      '内核',
      '[TCP] 198.18.0.1:61594 --> example.org:443 match Match using DIRECT',
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.descendant(of: find.byType(TagChip), matching: find.text('Tun')),
      findsOneWidget,
    );
  });

  testWidgets('搜索覆盖入站类型标签', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _scoped(
        const MaterialApp(home: AppScaffold(body: LogsPage())),
        _Connection(
          connections: <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'c2',
              'metadata': <String, dynamic>{
                'sourceIP': '198.18.0.9',
                'sourcePort': '50001',
                'type': 'Inner',
              },
            },
          ],
        ),
      ),
    );

    Logger.instance.info('内核', '[TCP] 198.18.0.9:50001 --> a.example:443');
    Logger.instance.info('内核', '[TCP] 198.18.0.9:50002 --> b.example:443');
    await tester.pump(const Duration(milliseconds: 500));

    await tester.enterText(find.byType(TextField), 'inner');
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.textContaining('a.example'), findsOneWidget);
    expect(find.textContaining('b.example'), findsNothing);
  });

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
      _scoped(const MaterialApp(home: AppScaffold(body: LogsPage()))),
    );

    expect(find.byType(SearchField), findsOneWidget);

    final Rect bar = tester.getRect(find.byType(SegmentedButton<LogLevel?>));
    expect(bar.left, greaterThanOrEqualTo(0));
    expect(bar.right, lessThanOrEqualTo(390));
    expect(_segment('error'), findsOneWidget);
  });

  for (final double width in <double>[390, 1400]) {
    for (final bool dark in <bool>[false, true]) {
      testWidgets('日志滚动后筛选与搜索固定：$width，深色 $dark', (tester) async {
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final String probe = '固定工具条探针 $width/$dark';
        for (int i = 0; i < 80; i++) {
          Logger.instance.info('测试', '$probe $i');
        }
        await tester.pumpWidget(
          _scoped(
            MaterialApp(
              theme: dark ? AppTheme.dark() : AppTheme.light(),
              home: const AppScaffold(body: LogsPage()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final DecoratedSliver container = tester.widget<DecoratedSliver>(
          find.byType(DecoratedSliver),
        );
        final BoxDecoration card = container.decoration as BoxDecoration;
        final ThemeData theme = dark ? AppTheme.dark() : AppTheme.light();
        expect(card.color, theme.cardTheme.color);
        expect(card.color, isNot(theme.scaffoldBackgroundColor));
        expect(card.borderRadius, BorderRadius.circular(AppTheme.cardRadius));
        final Finder filter = find.byType(SegmentedButton<LogLevel?>);
        final Finder search = find.byType(SearchField);
        final Rect filterBefore = tester.getRect(filter);
        final Rect searchBefore = tester.getRect(search);
        final Rect cardBounds = tester.getRect(
          find
              .ancestor(
                of: find.text('$probe 79'),
                matching: find.byType(Padding),
              )
              .first,
        );
        expect(cardBounds.right, searchBefore.right);
        final ScrollableState scroll = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
        await tester.pumpAndSettle();
        expect(scroll.position.pixels, greaterThan(0));
        expect(tester.getRect(filter), filterBefore);
        expect(tester.getRect(search), searchBefore);
        await tester.enterText(find.byType(TextField), '$probe 79');
        await tester.pumpAndSettle();
        expect(
          find.byWidgetPredicate(
            (widget) => widget is Text && widget.data == '$probe 79',
          ),
          findsOneWidget,
        );
        await tester.tap(_segment('debug'));
        await tester.pumpAndSettle();
        expect(find.text('没有符合条件的日志'), findsOneWidget);
        expect(find.byType(DecoratedSliver), findsOneWidget);
        expect(tester.getRect(filter).top, filterBefore.top);
        expect(tester.getRect(search).top, searchBefore.top);
        expect(tester.takeException(), isNull);
      });
    }
    testWidgets('日志列表在外侧保留滚动条空间：宽度 $width', (WidgetTester tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Logger.instance.info('测试', '日志留白探针');
      await tester.pumpWidget(
        _scoped(
          MaterialApp(
            theme: AppTheme.light(),
            home: const AppScaffold(body: LogsPage()),
          ),
        ),
      );

      final Rect page = tester.getRect(find.byType(LogsPage));
      final Rect row = tester.getRect(
        find
            .ancestor(of: find.text('日志留白探针'), matching: find.byType(Row))
            .first,
      );
      expect(
        page.right - row.right,
        greaterThanOrEqualTo(AppTheme.overlayScrollGutter),
      );
      expect(
        tester.getRect(find.text('日志留白探针').first).right,
        lessThanOrEqualTo(row.right),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('滚动条贴页面右缘，与整页滚动区等高', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (int i = 0; i < 80; i++) {
      Logger.instance.info('测试', '滚动条探针 $i');
    }
    await tester.pumpWidget(
      _scoped(
        MaterialApp(
          theme: AppTheme.light().copyWith(platform: TargetPlatform.windows),
          home: const AppScaffold(body: LogsPage()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(Scrollbar), findsOneWidget);
    expect(find.byType(DecoratedSliver), findsOneWidget);

    final Rect page = tester.getRect(find.byType(LogsPage));
    final Rect bar = tester.getRect(find.byType(Scrollbar));
    final Rect scroller = tester.getRect(find.byType(CustomScrollView));
    expect(bar.right, page.right);
    expect(bar.top, scroller.top);
    expect(bar.bottom, scroller.bottom);
    expect(scroller.top, page.top);
    expect(scroller.bottom, page.bottom);
  });

  testWidgets('每行不再各起一个 SelectionArea', (WidgetTester tester) async {
    await _pumpPage(tester);
    for (int i = 0; i < 40; i++) {
      Logger.instance.info('测试', '选区探针 $i');
    }
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(SelectionArea), findsOneWidget);
  });

  test('日志列表滚动口径与连接页相同', () {
    final String logs = File('lib/ui/pages/logs_page.dart').readAsStringSync();
    final String connections = File('lib/ui/pages/connections_page.dart')
        .readAsStringSync();
    expect(logs.contains('CustomScrollView'), isTrue);
    expect(logs.contains('SliverPadding'), isTrue);
    expect(logs.contains('overlayScrollGutter'), isTrue);
    expect(logs.contains('Scrollbar('), isFalse);
    expect(connections.contains('CustomScrollView'), isTrue);
    expect(connections.contains('overlayScrollGutter'), isTrue);
    expect(logs.contains('GappedSliverList('), isTrue);
    expect(connections.contains('GappedSliverList('), isTrue);
    expect(logs.contains('SliverList.separated'), isFalse);
    expect(connections.contains('SliverList.separated'), isFalse);
  });

  test('日志储存路径在设置页展示，不在日志页', () {
    final String logs = File('lib/ui/pages/logs_page.dart').readAsStringSync();
    final String settings = File('lib/ui/pages/settings_page.dart')
        .readAsStringSync();

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

  testWidgets('日志类型、时间、来源与正文同一字号', (WidgetTester tester) async {
    await _pumpPage(tester);

    Logger.instance.info('mihomo', '正文对齐探针');
    await tester.pump(const Duration(milliseconds: 500));

    final DateTime at = Logger.instance.entries.last.time;
    final Finder row = find
        .ancestor(of: find.text('正文对齐探针'), matching: find.byType(Row))
        .first;
    final double messageSize = _fontSize(tester, find.text('正文对齐探针'));
    expect(
      _fontSize(tester, find.descendant(of: row, matching: find.text('info'))),
      messageSize,
    );
    expect(
      _fontSize(
        tester,
        find.descendant(of: row, matching: find.text(_time(at))),
      ),
      messageSize,
    );
    expect(
      _fontSize(
        tester,
        find.descendant(of: row, matching: find.text('mihomo')),
      ),
      messageSize,
    );
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

  await tester.pumpWidget(
    _scoped(const MaterialApp(home: AppScaffold(body: LogsPage()))),
  );
}

Finder _segment(String label) => find.descendant(
  of: find.byType(SegmentedButton<LogLevel?>),
  matching: find.text(label),
);

double _fontSize(WidgetTester tester, Finder text) =>
    tester.widget<Text>(text).style!.fontSize!;

String _time(DateTime value) =>
    '${_two(value.hour)}:${_two(value.minute)}:${_two(value.second)}';

String _two(int value) => value.toString().padLeft(2, '0');

Widget _scoped(Widget app, [ConnectionController? connection]) => AppScope(
  auth: _Auth(),
  connection: connection ?? _Connection(),
  announcements: AnnouncementController(),
  update: _Update(),
  platform: _Platform(),
  settingsStore: _Settings(),
  child: app,
);

class _Connection extends ChangeNotifier implements ConnectionController {
  _Connection({this.connections = const <Map<String, dynamic>>[]});

  @override
  final List<Map<String, dynamic>> connections;
  @override
  List<Map<String, dynamic>> get closedConnections =>
      const <Map<String, dynamic>>[];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Auth extends ChangeNotifier implements AuthController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Update implements UpdateController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Platform implements PlatformService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings implements SettingsStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
