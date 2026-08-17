import 'dart:io';

import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/option_dropdown.dart';
import 'package:ecycloud_client/ui/widgets/refresh_button.dart';
import 'package:ecycloud_client/ui/widgets/switch_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 卡片里每行右侧的控件要落在同一条右边缘上：ListTile 自己会把 trailing 靠到内边距
// 上，而 IconButton 的图标会被触摸盒居中而内缩，缩放后的开关也会内缩，这些偏移只
// 在渲染后才看得出来，改动很容易把某一行挪出这一列。
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
                ListTile(
                  title: const Text('下拉选择'),
                  trailing: OptionDropdown<int>(
                    value: 1,
                    options: const <int, String>{1: '选项'},
                    onChanged: (_) {},
                  ),
                ),
                RefreshButton.tile(title: '检查更新', onRefresh: () async {}),
                // 设置页「储存路径」那行的等价搭法
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    0,
                    AppTheme.trailingIconButtonInset(16),
                    8,
                  ),
                  child: Row(
                    children: <Widget>[
                      const Expanded(child: Text('储存路径')),
                      IconButton(
                        icon: const Icon(Icons.folder_open_outlined, size: 16),
                        visualDensity: VisualDensity.compact,
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

    // 开关按 centerRight 缩放，绘制后的右边缘即布局盒子的右边缘
    final double column = rightOf(find.byIcon(Icons.chevron_right));
    expect(
      rightOf(find.byType(Switch)),
      moreOrLessEquals(column),
      reason: '开关',
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

    // 图标缩到 16 也不能让可点范围跟着缩：对齐是靠挪内边距，不是靠削触摸盒
    final Finder buttons = find.byType(IconButton);
    for (int i = 0; i < buttons.evaluate().length; i++) {
      final Size box = tester.getSize(buttons.at(i));
      expect(box.width, greaterThanOrEqualTo(40), reason: '图标按钮 $i 可点宽度');
      expect(box.height, greaterThanOrEqualTo(40), reason: '图标按钮 $i 可点高度');
    }
  });

  // 上面那行是设置页「储存路径」的等价搭法；那行的右内边距若不再取同一个算法，
  // 这里测得再准也管不到它
  test('设置页的日志目录按钮取同一份内边距算法', () {
    final String settings = File(
      'lib/ui/pages/settings_page.dart',
    ).readAsStringSync();

    expect(settings.contains('AppTheme.trailingIconButtonInset('), isTrue);
  });
}
