import 'dart:io';

import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/delay_badge.dart';
import 'package:ecycloud_client/ui/widgets/group_delay_test_button.dart';
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
              const PageHeader(title: '标题', showBackButton: true),
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
  });

  test('登录记住密码用可聚焦 InkWell，不用 GestureDetector', () {
    final String login = File('lib/ui/pages/login_page.dart').readAsStringSync();
    expect(login.contains('GestureDetector('), isFalse);
    expect(login.contains('InkWell('), isTrue);
  });

  test('首页公告键取同一份触控盒', () {
    final String home = File('lib/ui/pages/home_page.dart').readAsStringSync();
    expect(home.contains('AppTheme.minTapTarget'), isTrue);
  });
}
