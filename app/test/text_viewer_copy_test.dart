import 'package:ecycloud_client/ui/pages/text_viewer_page.dart';
import 'package:ecycloud_client/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> open(WidgetTester tester, String title) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: TextViewerPage(
          title: title,
          load: () async => '{"proxies":[{"uuid":"node-credential"}]}',
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool selectionDisabled(WidgetTester tester) => find
      .ancestor(
        of: find.textContaining('node-credential'),
        matching: find.byWidgetPredicate(
          (Widget widget) =>
              widget is SelectionContainer && widget.delegate == null,
        ),
      )
      .evaluate()
      .isNotEmpty;

  testWidgets('显示总行数与行号，长文件只构建可见行', (WidgetTester tester) async {
    final String text = List<String>.generate(
      5000,
      (int i) => 'DOMAIN-SUFFIX,example$i.com',
    ).join('\n');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: TextViewerPage(title: 'rules', load: () async => text),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('共 5000 行'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('DOMAIN-SUFFIX,example0.com'), findsOneWidget);
    expect(find.text('DOMAIN-SUFFIX,example4999.com'), findsNothing);
    expect(
      find.textContaining('DOMAIN-SUFFIX').evaluate().length,
      lessThan(200),
    );
  });

  testWidgets('运行配置与分流规则都可复制全部，正文可选择', (WidgetTester tester) async {
    for (final String title in <String>['运行配置', 'Apple']) {
      await open(tester, title);
      expect(find.textContaining('node-credential'), findsOneWidget);
      expect(find.byIcon(Icons.copy_all_outlined), findsOneWidget);
      expect(selectionDisabled(tester), isFalse);
    }
  });
}
