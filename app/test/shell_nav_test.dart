import 'dart:io';

import 'package:ecycloud_client/ui/widgets/simple_data_table.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

Rect _glyphs(WidgetTester tester, String text) {
  final RenderParagraph para = tester.renderObject<RenderParagraph>(
    find.text(text),
  );
  final List<TextBox> boxes = para.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: text.length),
  );
  final Rect local = boxes
      .map((TextBox box) => box.toRect())
      .reduce((Rect a, Rect b) => a.expandToInclude(b));
  return local.shift(para.localToGlobal(Offset.zero));
}

void main() {
  test('窄屏底栏只钉前四项，其余进更多', () {
    final String src = File('lib/ui/shell.dart').readAsStringSync();
    expect(src, contains('static const int _mobilePinnedCount = 4;'));
    expect(src, contains("L10n.t('更多')"));
    expect(src, contains('Icons.more_horiz'));
    expect(src, contains('_moreOpen'));
    expect(src, contains('Alignment.bottomRight'));
    expect(src, contains('IntrinsicWidth'));
    expect(src, contains('AppTheme.cardRadius'));
  });

  test('页顶描述走 bodyMedium，不改主题其它字号', () {
    expect(
      File('lib/ui/pages/usage_ips_page.dart').readAsStringSync(),
      contains('textTheme.bodyMedium'),
    );
    expect(
      File('lib/ui/pages/login_logs_page.dart').readAsStringSync(),
      contains('textTheme.bodyMedium'),
    );
    expect(
      File('lib/ui/pages/operation_logs_page.dart').readAsStringSync(),
      contains('textTheme.bodyMedium'),
    );
    expect(
      File('lib/ui/pages/invite_page.dart').readAsStringSync(),
      contains("L10n.t('邀请他人注册时，请将以下链接发送给被邀请者')"),
    );
    expect(
      File('lib/ui/theme.dart').readAsStringSync(),
      contains('bodyLarge: style(13)'),
    );
  });

  test('解锁表不再居中，邀请标签带冒号，工单查看左对齐，流量说明内嵌跳转', () {
    expect(
      File('lib/ui/pages/unlock_page.dart').readAsStringSync(),
      isNot(contains('stickyHeader')),
    );
    expect(
      File('lib/ui/pages/unlock_page.dart').readAsStringSync(),
      contains('ListView('),
    );
    expect(
      File('lib/ui/pages/invite_page.dart').readAsStringSync(),
      contains(r"'$label：'"),
    );
    expect(
      File('lib/ui/pages/tickets_page.dart').readAsStringSync(),
      contains('Alignment.centerLeft'),
    );
    expect(
      File('lib/ui/widgets/simple_data_table.dart').readAsStringSync(),
      contains('Alignment.centerRight'),
    );
    final String traffic =
        File('lib/ui/pages/traffic_log_page.dart').readAsStringSync();
    expect(traffic, contains('如果您手动测试了一些节点'));
    expect(traffic, contains("L10n.t('如需关闭自动测试可在本客户端的 ')"));
    expect(traffic, contains("L10n.t(' 关闭 自动选择 和 故障转移 策略组。')"));
    expect(traffic, contains('WidgetSpan'));
    expect(traffic, contains(r"'${L10n.t('分组策略')} ›'"));
    expect(
      File('lib/main.dart').readAsStringSync(),
      contains('caption:'),
    );
    final String channel =
        File('windows/runner/platform_channel.cpp').readAsStringSync();
    expect(channel, contains('DWMWA_CAPTION_COLOR'));
    // 切主题不再重算窗口框，否则标题栏会闪
    expect(channel, isNot(contains('SWP_FRAMECHANGED')));
    expect(
      File('windows/runner/win32_window.cpp').readAsStringSync(),
      contains('标题栏明暗由 Flutter'),
    );
  });

  test('桌面窗口尺寸会落盘，不再写死 1000x720', () {
    expect(
      File('windows/runner/main.cpp').readAsStringSync(),
      contains('Win32Window::RestoredSize()'),
    );
    expect(
      File('windows/runner/win32_window.cpp').readAsStringSync(),
      contains('window-size'),
    );
    expect(
      File('windows/runner/win32_window.cpp').readAsStringSync(),
      contains('RestoredMaximized'),
    );
    expect(
      File('macos/Runner/MainFlutterWindow.swift').readAsStringSync(),
      contains('persistContentSize'),
    );
    expect(
      File('linux/runner/my_application.cc').readAsStringSync(),
      contains('load_window_size'),
    );
  });

  testWidgets('更多面板贴在右下，不拉满整行', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              Align(
                alignment: Alignment.bottomRight,
                child: Material(
                  child: IntrinsicWidth(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        ListTile(title: Text('解锁')),
                        ListTile(title: Text('设置')),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final Rect panel = tester.getRect(find.byType(Material).last);
    expect(panel.left, greaterThan(200));
    expect(panel.right, closeTo(400, 0.5));
  });

  testWidgets('宽表解锁状态与表头左对齐', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SimpleDataTable(
            minWidth: 600,
            emptyText: 'empty',
            columns: const <String>['节点', 'Netflix'],
            rows: const <List<Widget>>[
              <Widget>[
                TableText('Node A', bold: true),
                TableText('Yes (DE)'),
              ],
              <Widget>[
                TableText('Node B', bold: true),
                TableText('No'),
              ],
            ],
          ),
        ),
      ),
    );

    expect(
      _glyphs(tester, 'Yes (DE)').left,
      closeTo(_glyphs(tester, 'No').left, 0.5),
    );
    expect(
      _glyphs(tester, 'Yes (DE)').left,
      closeTo(_glyphs(tester, 'Netflix').left, 1),
    );
  });

  testWidgets('窄屏卡片取值左对齐', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SimpleDataTable(
            minWidth: 1280,
            emptyText: 'empty',
            columns: const <String>['节点', 'Netflix', '更新时间'],
            rows: const <List<Widget>>[
              <Widget>[
                TableText('DE 德国 II', bold: true),
                TableText('Yes (DE)'),
                TableText('2026-08-24 19:01:01', muted: true),
              ],
            ],
          ),
        ),
      ),
    );

    expect(
      _glyphs(tester, 'Yes (DE)').left,
      closeTo(_glyphs(tester, 'DE 德国 II').left, 1),
    );
    expect(
      _glyphs(tester, '2026-08-24 19:01:01').left,
      closeTo(_glyphs(tester, 'DE 德国 II').left, 1),
    );
  });

  testWidgets('窄屏操作按钮翻到卡片最右边', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SimpleDataTable(
            minWidth: 1280,
            emptyText: 'empty',
            columns: const <String>['操作', '标题'],
            rows: <List<Widget>>[
              <Widget>[
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    onPressed: () {},
                    child: const Text('查看'),
                  ),
                ),
                const TableText('测试 (#2454)'),
              ],
            ],
          ),
        ),
      ),
    );

    final Rect button = tester.getRect(find.widgetWithText(FilledButton, '查看'));
    final Rect card = tester.getRect(find.byType(Card));
    expect(card.right - button.right, lessThan(20));
    expect(
      button.left,
      greaterThan(_glyphs(tester, '测试 (#2454)').right),
    );
  });
}
