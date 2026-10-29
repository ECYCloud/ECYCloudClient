import 'dart:io';

import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/app_text_field.dart';
import 'package:ecycloud_client/ui/widgets/delay_badge.dart';
import 'package:ecycloud_client/ui/widgets/group_delay_test_button.dart';
import 'package:ecycloud_client/ui/widgets/group_speed_test_button.dart';
import 'package:ecycloud_client/ui/widgets/speed_badge.dart';
import 'package:ecycloud_client/ui/widgets/page_header.dart';
import 'package:ecycloud_client/ui/widgets/refresh_button.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// AppTheme.light() 是 static final，第一次访问就冻结 ThemeData.platform；
// 渲染断言只在默认 android 下做，桌面端只断言取值。
void main() {
  testWidgets('触控端小图标键触控盒恰好 48', (WidgetTester tester) async {
    expect(AppTheme.isTouch, isTrue, reason: '测试默认平台应为 android');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              const PageHeader(
                title: '标题',
                showBackButton: true,
                showUserAvatar: false,
              ),
              RefreshButton(onRefresh: () async {}),
            ],
          ),
        ),
      ),
    );

    // 须恰好等于 48：visualDensity 会把紧约束退化成松约束，只查下限漏不掉
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

  testWidgets('延迟测试键触控盒恰好 minTapTarget', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Row(
            children: <Widget>[
              DelayBadge(
                delay: 0,
                testing: false,
                unreachable: false,
                onTest: () {},
              ),
              GroupDelayTestButton(testing: false, onPressed: () {}),
              SpeedBadge(
                bytesPerSecond: 0,
                testing: false,
                failed: false,
                onTest: () {},
              ),
              GroupSpeedTestButton(testing: false, onPressed: () {}),
            ],
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(DelayBadge)),
      Size.square(AppTheme.minTapTarget),
    );
    expect(
      tester.getSize(find.byType(GroupDelayTestButton)),
      Size.square(AppTheme.minTapTarget),
    );
    expect(
      tester.getSize(find.byType(SpeedBadge)),
      Size.square(AppTheme.minTapTarget),
    );
    expect(
      tester.getSize(find.byType(GroupSpeedTestButton)),
      Size.square(AppTheme.minTapTarget),
    );
  });

  test('登录记住密码用可聚焦 InkWell，不用 GestureDetector', () {
    final String login = File('lib/ui/pages/login_page.dart').readAsStringSync();
    expect(login.contains('GestureDetector('), isFalse);
    expect(login.contains('InkWell('), isTrue);
  });

  test('首页公告键取同一份触控盒', () {
    final String home = File('lib/ui/pages/home_page.dart').readAsStringSync();
    expect(home.contains('AppTheme.minTapTarget'), isTrue);
    expect(home.contains('AppTheme.pointerTapTarget'), isTrue);
    final int button = home.indexOf('IconButton(');
    final int badge = home.indexOf('Badge(', button);
    expect(badge, greaterThan(button));
    expect(home.indexOf('pointerTapTarget', badge), greaterThan(badge));
    expect(home.indexOf('notifications_outlined', badge), greaterThan(badge));
  });

  testWidgets('公告红点按桌面端按钮盒落位', (WidgetTester tester) async {
    expect(AppTheme.isTouch, isTrue, reason: '测试默认平台应为 android');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: IconButton(
            onPressed: () {},
            icon: const Badge(
              isLabelVisible: true,
              backgroundColor: Color(0xFFE53935),
              smallSize: 8,
              child: SizedBox(
                width: AppTheme.pointerTapTarget,
                height: AppTheme.pointerTapTarget,
                child: Center(
                  child: Icon(Icons.notifications_outlined, size: 20),
                ),
              ),
            ),
            visualDensity: VisualDensity.standard,
            constraints: BoxConstraints.tightFor(
              width: AppTheme.minTapTarget,
              height: AppTheme.minTapTarget,
            ),
            padding: EdgeInsets.zero,
          ),
        ),
      ),
    );

    final Rect icon = tester.getRect(find.byIcon(Icons.notifications_outlined));
    final Rect dot = tester.getRect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is Container &&
            widget.constraints ==
                const BoxConstraints.tightFor(width: 8, height: 8),
      ),
    );
    final Rect button = tester.getRect(find.byType(IconButton));
    final Rect box = Rect.fromCenter(
      center: button.center,
      width: AppTheme.pointerTapTarget,
      height: AppTheme.pointerTapTarget,
    );
    expect(button.width, AppTheme.minTapTarget);
    expect(icon.center, button.center);
    expect(dot.top, box.top);
    expect(dot.right, box.right);
    expect(box.right - icon.right, (AppTheme.pointerTapTarget - icon.width) / 2);
  });

  testWidgets('密码框后缀不把输入框撑高', (WidgetTester tester) async {
    expect(AppTheme.isTouch, isTrue, reason: '测试默认平台应为 android');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              const AppTextField(
                decoration: InputDecoration(
                  labelText: '邮箱',
                  prefixIcon: Icon(Icons.mail_outline),
                ),
              ),
              AppTextField(
                obscureText: true,
                decoration: InputDecoration(
                  labelText: '密码',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    onPressed: () {},
                    icon: const Icon(Icons.visibility_outlined),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    expect(
      tester.getSize(find.byType(TextField).at(1)).height,
      tester.getSize(find.byType(TextField).at(0)).height,
    );
  });

  testWidgets('节点卡叠放的延迟和测速收进指针高度', (WidgetTester tester) async {
    expect(AppTheme.isTouch, isTrue, reason: '测试默认平台应为 android');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SizedBox(
            width: AppTheme.minTapTarget,
            height: AppTheme.pointerTapTarget * 2,
            child: Column(
              children: <Widget>[
                Expanded(
                  child: DelayBadge(
                    delay: 0,
                    testing: true,
                    unreachable: false,
                    onTest: () {},
                  ),
                ),
                Expanded(
                  child: SpeedBadge(
                    bytesPerSecond: 0,
                    testing: false,
                    failed: false,
                    onTest: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(DelayBadge)).height,
      AppTheme.pointerTapTarget,
    );
    expect(
      tester.getSize(find.byType(SpeedBadge)).height,
      AppTheme.pointerTapTarget,
    );

    final String nodes = File(
      'lib/ui/pages/nodes_page.dart',
    ).readAsStringSync();
    expect(nodes.contains('crossAxisAlignment: CrossAxisAlignment.end'), isTrue);
    expect(nodes.contains('AppTheme.pointerTapTarget * 2'), isTrue);
    expect(nodes.contains('isTouch ? 10'), isFalse);
  });
}
