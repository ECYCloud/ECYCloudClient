import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/page_header.dart';
import 'package:ecycloud_client/ui/widgets/refresh_button.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 小图标键在触控端（Android/iOS）要有 48dp 触控盒，桌面用鼠标保持紧凑。
// 渲染类断言只在测试环境的默认平台（android）下做：AppTheme.light() 是
// static final，第一次访问就冻结 ThemeData.platform（materialTapTargetSize 由它
// 推出），同进程内改 debugDefaultTargetPlatformOverride 也不会重建，换平台再渲染
// 量到的是上一个平台的主题。桌面端因此只断言取值，不重复渲染。
void main() {
  testWidgets('触控端小图标键触控盒恰好 48', (WidgetTester tester) async {
    expect(AppTheme.isTouch, isTrue, reason: '测试默认平台应为 android');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              const PageHeader(title: '标题', showBackButton: true),
              RefreshButton(onRefresh: () async {}),
            ],
          ),
        ),
      ),
    );

    // 返回键与刷新键。断言「恰好等于」而非下限：visualDensity 会把紧约束的 min
    // 减 8 使其退化成松约束，盒子随内容缩小，图标就偏出右侧那一列
    final Finder iconButtons = find.byType(IconButton);
    expect(iconButtons, findsNWidgets(2));
    expect(AppTheme.minTapTarget, 48);
    for (int i = 0; i < 2; i++) {
      expect(
        tester.getSize(iconButtons.at(i)),
        const Size.square(48),
        reason: '图标按钮 $i 触控盒',
      );
    }
  });

  test('桌面端小图标键收回 32', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      expect(AppTheme.isTouch, isFalse);
      expect(AppTheme.minTapTarget, 32);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
