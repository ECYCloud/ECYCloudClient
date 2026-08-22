import 'dart:io';

import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/refresh_button.dart';
import 'package:ecycloud_client/ui/widgets/section_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(body: child),
  );

  Material pillOf(WidgetTester tester, Finder button) =>
      tester.widget<Material>(
        find.descendant(of: button, matching: find.byType(Material)).first,
      );

  BorderSide sideOf(WidgetTester tester, Finder button) =>
      (pillOf(tester, button).shape! as OutlinedBorder).side;

  testWidgets('文字按钮透明底且有描边', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(TextButton(onPressed: () {}, child: const Text('商店'))),
    );

    expect(pillOf(tester, find.byType(TextButton)).color?.a ?? 0, 0);
    expect(sideOf(tester, find.byType(TextButton)).style, BorderStyle.solid);
    expect(sideOf(tester, find.byType(TextButton)).width, greaterThan(0));
  });

  testWidgets('文字按钮与描边按钮同尺寸', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextButton(onPressed: () {}, child: const Text('商店')),
            OutlinedButton(onPressed: () {}, child: const Text('商店')),
          ],
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(TextButton)),
      tester.getSize(find.byType(OutlinedButton)),
    );
    expect(pillOf(tester, find.byType(TextButton)).color?.a ?? 0, 0);
    expect(pillOf(tester, find.byType(OutlinedButton)).color?.a ?? 0, 0);
    expect(sideOf(tester, find.byType(TextButton)).style, BorderStyle.solid);
    expect(
      sideOf(tester, find.byType(OutlinedButton)).style,
      BorderStyle.solid,
    );
  });

  testWidgets('次要按钮底色与主操作按钮不同', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextButton(onPressed: () {}, child: const Text('取消')),
            FilledButton(onPressed: () {}, child: const Text('确定')),
          ],
        ),
      ),
    );

    expect(
      pillOf(tester, find.byType(TextButton)).color,
      isNot(pillOf(tester, find.byType(FilledButton)).color),
    );
    expect(
      tester.getSize(find.byType(TextButton)).height,
      tester.getSize(find.byType(FilledButton)).height,
    );
  });

  testWidgets('同一个按钮在各容器里等高', (WidgetTester tester) async {
    Widget btn(String label) =>
        TextButton(onPressed: () {}, child: Text(label));

    await tester.pumpWidget(
      host(
        SingleChildScrollView(
          child: Column(
            children: <Widget>[
              SectionCard(
                title: '卡片',
                action: btn('卡片右上角'),
                child: const Text('内容'),
              ),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[const Text('前往 '), btn('句子内联')],
              ),
              ListTile(title: const Text('行'), trailing: btn('列表尾部')),
              RefreshButton.tile(
                title: '刷新行',
                action: btn('刷新行动作'),
                onRefresh: () async {},
              ),
              Row(children: <Widget>[btn('独立动作')]),
            ],
          ),
        ),
      ),
    );

    Finder buttonOf(String label) =>
        find.ancestor(of: find.text(label), matching: find.byType(TextButton));
    double tapHeight(String label) => tester.getSize(buttonOf(label)).height;
    double pillHeight(String label) => tester
        .getSize(
          find
              .descendant(of: buttonOf(label), matching: find.byType(Material))
              .first,
        )
        .height;

    const List<String> labels = <String>[
      '卡片右上角',
      '句子内联',
      '列表尾部',
      '刷新行动作',
      '独立动作',
    ];
    for (final String label in labels) {
      expect(tapHeight(label), tapHeight(labels.first), reason: '$label 可点高度');
      expect(
        pillHeight(label),
        pillHeight(labels.first),
        reason: '$label 胶囊高度',
      );
    }
  });

  testWidgets('禁用态文字按钮仍是透明底', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(const TextButton(onPressed: null, child: Text('商店'))),
    );

    expect(pillOf(tester, find.byType(TextButton)).color?.a ?? 0, 0);
  });

  test('界面里不再手搓下划线链接', () {
    // HTML 正文里的 <a> 落在 flutter_html 的行内 span 上，取不到按钮
    const Set<String> allowed = <String>{'lib/ui/widgets/rich_html_view.dart'};
    final List<String> offenders = <String>[];
    for (final File file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((File f) => f.path.endsWith('.dart'))) {
      final String path = file.path.replaceAll(r'\', '/');
      if (allowed.contains(path)) {
        continue;
      }
      if (file.readAsStringSync().contains('TextDecoration.underline')) {
        offenders.add(path);
      }
    }
    expect(offenders, isEmpty, reason: '下划线链接只许出现在 $allowed');
  });
}
