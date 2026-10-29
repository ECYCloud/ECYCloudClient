import 'dart:io';

import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/section_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('设置分组标题与邀请卡片标题同一字号', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: Column(
            children: <Widget>[
              Section(
                icon: Icons.vpn_lock_outlined,
                title: '代理',
                children: <Widget>[Text('行')],
              ),
              SectionCard(icon: Icons.link, title: '邀请信息', child: Text('内容')),
            ],
          ),
        ),
      ),
    );

    expect(fontSizeOf(tester, '代理'), AppTheme.sectionTitleSize);
    expect(fontSizeOf(tester, '邀请信息'), AppTheme.sectionTitleSize);
  });

  test('流量排行分类标题用小节标题，窄屏两栏用分割线隔开', () {
    final String home = File('lib/ui/pages/home_page.dart').readAsStringSync();
    final int card = home.indexOf('class _TrafficRankCardState');
    final int list = home.indexOf('class _RankList');
    expect(card, greaterThan(0));
    expect(list, greaterThan(card));

    final String rankCard = home.substring(card, list);
    expect(rankCard.contains('stackedSeparator'), isTrue);
    expect(rankCard.contains('vertical: 20'), isTrue);
    expect(rankCard.contains('Divider(height: 1)'), isTrue);
    expect(rankCard.contains('NodeLabels.groupIcon'), isTrue);
    expect(rankCard.contains('Icons.language'), isTrue);

    final String rank = home.substring(list, home.indexOf('class _KernelCard'));
    expect(rank.contains('titleSmall'), isTrue);
    expect(rank.indexOf('titleSmall'), lessThan(rank.indexOf('bodySmall')));
  });
}

double fontSizeOf(WidgetTester tester, String text) =>
    tester.renderObject<RenderParagraph>(find.text(text)).text.style!.fontSize!;
