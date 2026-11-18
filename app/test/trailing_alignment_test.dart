import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/option_dropdown.dart';
import 'package:ecycloud_client/ui/widgets/refresh_button.dart';
import 'package:ecycloud_client/ui/widgets/switch_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('卡片内各行右侧控件共用一条右边缘', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Card(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const ListTile(
                  title: Text('二级页入口'),
                  trailing: Icon(Icons.chevron_right),
                ),
                SwitchTile(title: '开关', value: true, onChanged: (_) {}),
                SwitchTile(
                  title: '带设置',
                  value: true,
                  onChanged: (_) {},
                  onSettings: () {},
                ),
                ListTile(
                  title: const Text('下拉选择'),
                  trailing: OptionDropdown<int>(
                    value: 1,
                    options: const <int, String>{1: '选项'},
                    onChanged: (_) {},
                  ),
                ),
                RefreshButton.tile(title: '检查更新', onRefresh: () async {}),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    0,
                    AppTheme.trailingIconButtonInset(24),
                    8,
                  ),
                  child: Row(
                    children: <Widget>[
                      const Expanded(child: Text('储存路径')),
                      IconButton(
                        icon: const Icon(Icons.folder_open_outlined, size: 24),
                        visualDensity: VisualDensity.standard,
                        constraints: BoxConstraints.tightFor(
                          width: AppTheme.minTapTarget,
                          height: AppTheme.minTapTarget,
                        ),
                        padding: EdgeInsets.zero,
                        onPressed: () {},
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final Rect card = tester.getRect(find.byType(Card));
    double rightOf(Finder finder) => card.right - tester.getRect(finder).right;

    final double column = rightOf(find.byIcon(Icons.chevron_right));
    expect(
      rightOf(find.byType(Switch).first),
      moreOrLessEquals(column),
      reason: '开关',
    );
    expect(
      rightOf(find.byType(Switch).last),
      moreOrLessEquals(column),
      reason: '带齿轮的开关',
    );
    expect(
      rightOf(find.byType(OptionDropdown<int>)),
      moreOrLessEquals(column),
      reason: '下拉框',
    );
    expect(
      rightOf(find.byIcon(Icons.refresh)),
      moreOrLessEquals(column),
      reason: '刷新',
    );
    expect(
      rightOf(find.byIcon(Icons.folder_open_outlined)),
      moreOrLessEquals(column),
      reason: '日志目录',
    );

    final Size iconSize = tester.getSize(find.byIcon(Icons.chevron_right));
    expect(
      tester.getSize(find.byIcon(Icons.refresh)),
      iconSize,
      reason: '刷新图标',
    );
    expect(
      tester.getSize(find.byIcon(Icons.folder_open_outlined)),
      iconSize,
      reason: '日志目录图标',
    );

    // 须恰好等于 minTapTarget：visualDensity 会把紧约束退化成松约束，只查下限漏不掉
    final Finder buttons = find.byType(IconButton);
    for (int i = 0; i < buttons.evaluate().length; i++) {
      final Size box = tester.getSize(buttons.at(i));
      expect(box.width, AppTheme.minTapTarget, reason: '图标按钮 $i 可点宽度');
      expect(box.height, AppTheme.minTapTarget, reason: '图标按钮 $i 可点高度');
    }
  });

  // 测试字体里 p 只画基线以下的部分，笔画中线既不在行框中线，也不在按字号估的位置
  for (final MaterialTapTargetSize tapSize in MaterialTapTargetSize.values) {
    testWidgets('开关行齿轮对准标题笔画中线，不对行框中线（$tapSize）', (WidgetTester tester) async {
      const String titleText = 'pp';
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light().copyWith(materialTapTargetSize: tapSize),
            home: Scaffold(
              body: Card(
                child: SwitchTile(
                  title: titleText,
                  subtitle: '接管系统全部流量',
                  value: true,
                  onChanged: (_) {},
                  onSettings: () {},
                ),
              ),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      final Rect title = tester.getRect(find.text(titleText));
      final ui.Image shot = (await tester.runAsync(
        () => captureImage(find.byType(Card).evaluate().single),
      ))!;
      addTearDown(shot.dispose);
      final ByteData pixels = (await tester.runAsync<ByteData?>(
        () => shot.toByteData(),
      ))!;
      final double ratio = shot.width / tester.getSize(find.byType(Card)).width;
      final Offset card = tester.getTopLeft(find.byType(Card));
      int? top;
      int? bottom;
      for (
        int y = ((title.top - card.dy) * ratio).floor();
        y < ((title.bottom - card.dy) * ratio).ceil();
        y++
      ) {
        for (
          int x = ((title.left - card.dx) * ratio).floor();
          x < ((title.right - card.dx) * ratio).ceil();
          x++
        ) {
          if (pixels.getUint8((y * shot.width + x) * 4) < 128) {
            top ??= y;
            bottom = y;
            break;
          }
        }
      }
      final double inkCenter = card.dy + (top! + bottom! + 1) / 2 / ratio;

      expect(inkCenter, isNot(moreOrLessEquals(title.center.dy)));
      expect(
        tester.getCenter(find.byIcon(Icons.settings_outlined)).dy,
        moreOrLessEquals(inkCenter, epsilon: 0.5),
      );
    });
  }

  testWidgets('刷新行整行即按钮，尾部图标不单独响应点击', (WidgetTester tester) async {
    int runs = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RefreshButton.tile(
            title: '刷新面板配置',
            tooltip: '刷新面板配置',
            onRefresh: () async => runs++,
          ),
        ),
      ),
    );

    expect(
      find.descendant(
        of: find.byType(RefreshButton),
        matching: find.byType(IconButton),
      ),
      findsNothing,
    );
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(runs, 1);
    await tester.tap(find.text('刷新面板配置'));
    await tester.pumpAndSettle();
    expect(runs, 2);
  });

  test('设置页的日志目录按钮取同一份内边距算法', () {
    final String settings = File('lib/ui/pages/settings_page.dart')
        .readAsStringSync();

    expect(settings.contains('AppTheme.trailingIconButtonInset('), isTrue);
  });

  test('系统代理与 TUN 的绕过入口在开关行齿轮上，不再单独占一行', () {
    final String settings = File('lib/ui/pages/settings_page.dart')
        .readAsStringSync();
    final String home = File('lib/ui/pages/home_page.dart').readAsStringSync();
    final String tile = File('lib/ui/widgets/switch_tile.dart')
        .readAsStringSync();

    expect(settings.contains("title: Text(L10n.t('系统代理绕过'))"), isFalse);
    expect(settings.contains("title: Text(L10n.t('TUN 排除自定义网段'))"), isFalse);
    expect(settings.contains('openSystemProxyBypass'), isTrue);
    expect(home.contains('openSystemProxyBypass'), isTrue);
    expect(home.contains('openTunExcludeAddresses'), isTrue);
    expect(tile.contains('Icons.settings_outlined'), isTrue);
  });
}
