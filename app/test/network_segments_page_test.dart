import 'dart:async';

import 'package:ecycloud_client/ui/pages/network_segments_page.dart';
import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/app_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final String title in <String>['系统代理绕过', '排除自定义网段']) {
    for (final bool fail in <bool>[false, true]) {
      testWidgets('$title 保存完成后提示结果，失败 $fail', (tester) async {
        final Completer<void> saved = Completer<void>();
        List<String>? submitted;
        await _pumpEditor(tester, title, (value) {
          submitted = value;
          return saved.future;
        });
        await tester.enterText(find.byType(TextField), '192.168.56.0/24');
        await tester.tap(find.text('添加'));
        await tester.pump();
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(submitted, <String>['192.168.56.0/24']);
        expect(find.byType(NetworkSegmentsPage), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        if (fail) {
          saved.completeError(StateError('测试写入失败'));
        } else {
          saved.complete();
        }
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsOneWidget);
        expect(
          fail ? find.textContaining('保存失败：') : find.text('保存成功'),
          findsOneWidget,
        );
        expect(find.text('保存成功'), fail ? findsNothing : findsOneWidget);
        if (fail) expect(find.textContaining('测试写入失败'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('$title 取消时不保存、不提示成功', (tester) async {
      bool saved = false;
      await _pumpEditor(tester, title, (_) async => saved = true);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(saved, isFalse);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _pumpEditor(
  WidgetTester tester,
  String title,
  Future<void> Function(List<String>) onSave,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: AppScaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => editNetworkSegments(
              context,
              title: title,
              helperText: '测试说明',
              hintText: '192.168.56.0/24',
              items: const <String>[],
              onSave: onSave,
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}
