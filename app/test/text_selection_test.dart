import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/app_alert_dialog.dart';
import 'package:ecycloud_client/ui/widgets/app_scaffold.dart';
import 'package:ecycloud_client/ui/widgets/app_text_field.dart';
import 'package:ecycloud_client/ui/widgets/app_text_selection.dart';
import 'package:ecycloud_client/ui/widgets/auth_store_panel.dart';
import 'package:ecycloud_client/ui/widgets/overlay_scroll_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _desktop = TargetPlatformVariant(<TargetPlatform>{
  TargetPlatform.windows,
  TargetPlatform.linux,
  TargetPlatform.macOS,
});

void main() {
  String clipboard = '';

  setUp(() {
    clipboard = '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          switch (call.method) {
            case 'Clipboard.setData':
              clipboard = (call.arguments as Map)['text'] as String;
              return null;
            case 'Clipboard.getData':
              return <String, String>{'text': clipboard};
            case 'Clipboard.hasStrings':
              return <String, bool>{'value': clipboard.isNotEmpty};
          }
          return null;
        });
  });

  testWidgets('鼠标按住后拖选相邻选区，只保留最后一处高亮', (tester) async {
    await _pump(
      tester,
      const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppTextSelection(child: Text('first cell')),
          SizedBox(height: 40),
          AppTextSelection(child: Text('second cell')),
        ],
      ),
    );
    for (final label in ['first cell', 'second cell']) {
      final rect = tester.getRect(find.text(label));
      final gesture = await tester.startGesture(
        rect.centerLeft + const Offset(1, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.moveTo(rect.centerRight - const Offset(1, 0));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pump();
      expect(_isSelected(tester, find.text(label)), isTrue);
      final region = tester.widget<SelectionArea>(
        find
            .ancestor(
              of: find.text(label),
              matching: find.byType(SelectionArea),
            )
            .first,
      );
      expect(
        region.focusNode!.hasPrimaryFocus,
        isTrue,
        reason: '拖选结束后焦点必须属于实际选中的区域：$label',
      );
    }
    expect(_isSelected(tester, find.text('first cell')), isFalse);
    await _shortcut(tester, LogicalKeyboardKey.keyC);
    expect(clipboard, 'second cell');
  }, variant: _desktop);

  for (final clicks in [2, 3]) {
    testWidgets('同一鼠标连续 $clicks 击切换选区并复制', (tester) async {
      await _pump(
        tester,
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppTextSelection(child: Text('first cell')),
            SizedBox(height: 120),
            AppTextSelection(child: Text('second cell')),
          ],
        ),
      );
      final mouse = await tester.createGesture(
        pointer: 42,
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      String? previous;
      for (final label in [
        'first cell',
        'second cell',
        'first cell',
        'second cell',
      ]) {
        final rect = tester.getRect(find.text(label));
        final at = rect.centerLeft + const Offset(5, 0);
        await mouse.moveTo(at);
        for (var i = 0; i < clicks; i++) {
          await mouse.down(at);
          await tester.pump(const Duration(milliseconds: 50));
          await mouse.up();
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(_isSelected(tester, find.text(label)), isTrue);
        if (previous != null) {
          expect(_isSelected(tester, find.text(previous)), isFalse);
        }
        previous = label;
        await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 10));
      }
      await _shortcut(tester, LogicalKeyboardKey.keyC);
      expect(clipboard, clicks == 2 ? 'second' : 'second cell');
    }, variant: _desktop);
  }

  for (final lifecycle in [
    AppLifecycleState.resumed,
    AppLifecycleState.inactive,
  ]) {
    testWidgets('父子与相邻选区切换只保留当前高亮：$lifecycle', (tester) async {
      tester.binding.handleAppLifecycleStateChanged(lifecycle);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      await _pump(
        tester,
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('outer content'),
            AppTextSelection(child: Text('first cell')),
            AppTextSelection(child: Text('second cell')),
          ],
        ),
      );
      final labels = [
        'outer content',
        'first cell',
        'second cell',
        'outer content',
      ];
      for (var i = 0; i < labels.length; i++) {
        await _selectText(tester, find.text(labels[i]));
        expect(_isSelected(tester, find.text(labels[i])), isTrue);
        if (i > 0) {
          expect(_isSelected(tester, find.text(labels[i - 1])), isFalse);
        }
      }
      await _rightClick(tester, find.text('outer content'));
      expect(_isSelected(tester, find.text('outer content')), isTrue);
      await _menu(tester, 'Copy');
      expect(clipboard, 'outer content');
    }, variant: _desktop);
  }

  testWidgets('正文转输入框时旧正文高亮清除，输入框仍能复制', (tester) async {
    final controller = TextEditingController(text: 'editable content');
    addTearDown(controller.dispose);
    await _pump(
      tester,
      Column(
        children: [
          const Text('page content'),
          AppTextField(controller: controller),
        ],
      ),
    );
    await _selectText(tester, find.text('page content'));
    expect(_isSelected(tester, find.text('page content')), isTrue);
    await tester.tap(find.byType(TextField));
    await _shortcut(tester, LogicalKeyboardKey.keyA);
    expect(_isSelected(tester, find.text('page content')), isFalse);
    await _rightClick(tester, find.byType(EditableText));
    await _menu(tester, 'Copy');
    expect(clipboard, 'editable content');
  }, variant: _desktop);

  testWidgets('临时切换到其他应用再回来保留选区', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    await _pump(tester, const Text('retained content'));
    await _selectText(tester, find.text('retained content'));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(_isSelected(tester, find.text('retained content')), isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await _shortcut(tester, LogicalKeyboardKey.keyC);
    expect(clipboard, 'retained content');
  }, variant: _desktop);

  testWidgets('手机长按切换正文和单元格只保留新选区', (tester) async {
    await _pump(
      tester,
      const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('outer'),
          SizedBox(height: 100),
          AppTextSelection(child: Text('first')),
          SizedBox(height: 100),
          AppTextSelection(child: Text('second')),
        ],
      ),
    );
    for (final (previous, current) in [
      (null, 'outer'),
      ('outer', 'first'),
      ('first', 'second'),
    ]) {
      await tester.longPress(find.text(current));
      await tester.pumpAndSettle();
      expect(_isSelected(tester, find.text(current)), isTrue, reason: current);
      if (previous != null) {
        expect(_isSelected(tester, find.text(previous)), isFalse);
      }
    }
    await _menu(tester, 'Copy');
    expect(clipboard, 'second');
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final bool hold in <bool>[false, true]) {
    testWidgets('输入框选中文字后实际右键复制：长按 $hold', (tester) async {
      final controller = TextEditingController(text: 'copy target');
      addTearDown(controller.dispose);
      await _pump(
        tester,
        Column(
          children: <Widget>[
            const Text('surrounding text'),
            AppTextField(controller: controller),
          ],
        ),
      );
      await tester.tap(find.byType(TextField));
      await _shortcut(tester, LogicalKeyboardKey.keyA);
      await _rightClick(tester, find.byType(EditableText), hold: hold);
      expect(find.text('Select all'), findsNothing);
      await _menu(tester, 'Copy');
      expect(clipboard, 'copy target');
      expect(controller.text, 'copy target');
    }, variant: _desktop);
  }

  testWidgets('未聚焦输入框右键菜单不含全选，快捷键全选后可剪切粘贴', (tester) async {
    final controller = TextEditingController(text: 'first second');
    addTearDown(controller.dispose);
    await _pump(tester, AppTextField(controller: controller));
    await _rightClick(tester, find.byType(EditableText));
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      await _menu(tester, 'Copy');
      expect(clipboard, 'first');
    }
    expect(find.text('Select all'), findsNothing);
    await tester.tap(find.byType(TextField));
    await _shortcut(tester, LogicalKeyboardKey.keyA);
    await _rightClick(tester, find.byType(EditableText));
    await _menu(tester, 'Cut');
    expect(clipboard, 'first second');
    expect(controller.text, isEmpty);
    await _rightClick(tester, find.byType(EditableText));
    await _menu(tester, 'Paste');
    expect(controller.text, 'first second');
  }, variant: _desktop);

  testWidgets(
    '正文右键菜单不含全选，快捷键全选仍可复制',
    (tester) async {
      await _pump(tester, const Text('copy entire content'));
      final text = find.text('copy entire content');
      await _rightClick(tester, text);
      expect(find.text('Select all'), findsNothing);
      await _shortcut(tester, LogicalKeyboardKey.keyA);
      await _rightClick(tester, text);
      await _menu(tester, 'Copy');
      expect(clipboard, 'copy entire content');
    },
    variant: TargetPlatformVariant(<TargetPlatform>{
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );

  testWidgets('只读框只允许复制，密码框不允许复制剪切', (tester) async {
    clipboard = 'paste source';
    final controller = TextEditingController(text: 'private value');
    addTearDown(controller.dispose);
    for (final bool secret in <bool>[false, true]) {
      await _pump(
        tester,
        AppTextField(
          controller: controller,
          readOnly: !secret,
          obscureText: secret,
        ),
      );
      await tester.tap(find.byType(TextField));
      await _shortcut(tester, LogicalKeyboardKey.keyA);
      await _rightClick(tester, find.byType(EditableText));
      expect(find.text('Copy'), secret ? findsNothing : findsOneWidget);
      expect(find.text('Cut'), findsNothing);
      if (!secret) expect(find.text('Paste'), findsNothing);
      if (secret) {
        await _shortcut(tester, LogicalKeyboardKey.keyC);
        expect(clipboard, 'paste source');
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  }, variant: _desktop);

  testWidgets('禁用输入框不弹出编辑菜单', (tester) async {
    final controller = TextEditingController(text: 'disabled value');
    addTearDown(controller.dispose);
    await _pump(tester, AppTextField(controller: controller, enabled: false));
    await _rightClick(tester, find.byType(AppTextField));
    expect(find.text('Copy'), findsNothing);
    expect(find.text('Cut'), findsNothing);
    expect(find.text('Paste'), findsNothing);
    expect(controller.text, 'disabled value');
  }, variant: _desktop);

  for (final bool form in <bool>[false, true]) {
    testWidgets('输入框撤销后可重做，表单 $form', (tester) async {
      await _pump(
        tester,
        form ? const AppTextFormField() : const AppTextField(maxLines: 3),
      );
      final Finder field = find.byType(EditableText);
      final EditableText editable = tester.widget<EditableText>(field);
      await tester.tap(field);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.enterText(field, 'first');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.enterText(field, 'second');
      await tester.pump(const Duration(milliseconds: 600));
      await _shortcut(tester, LogicalKeyboardKey.keyZ);
      expect(editable.controller.text, 'first');
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        await _shortcut(tester, LogicalKeyboardKey.keyZ, shift: true);
      } else {
        await _shortcut(tester, LogicalKeyboardKey.keyY);
      }
      expect(editable.controller.text, 'second');
      await _shortcut(tester, LogicalKeyboardKey.keyZ);
      await _shortcut(tester, LogicalKeyboardKey.keyZ, shift: true);
      expect(editable.controller.text, 'second');
      await _shortcut(tester, LogicalKeyboardKey.keyZ);
      await tester.enterText(field, 'third');
      await tester.pump(const Duration(milliseconds: 600));
      await _shortcut(tester, LogicalKeyboardKey.keyZ, shift: true);
      expect(editable.controller.text, 'third');
      expect(tester.takeException(), isNull);
    }, variant: _desktop);
  }

  testWidgets('多行输入框方向键移动和 Shift 扩选仍由输入框处理', (tester) async {
    final controller = TextEditingController(text: 'first line\nsecond line');
    addTearDown(controller.dispose);
    await _pump(
      tester,
      OverlayScrollView(
        child: AppTextField(controller: controller, maxLines: 3),
      ),
    );
    await tester.enterText(find.byType(TextField), controller.text);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(controller.selection.baseOffset, lessThan(11));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(controller.selection.isCollapsed, isFalse);
    final selected = controller.selection.textInside(controller.text);
    await _shortcut(tester, LogicalKeyboardKey.keyC);
    expect(clipboard, selected);
    expect(tester.takeException(), isNull);
  }, variant: _desktop);

  testWidgets('正文选区内的图片缩放和平移手势仍可使用', (tester) async {
    final transform = TransformationController(
      Matrix4.diagonal3Values(2, 2, 1),
    );
    addTearDown(transform.dispose);
    await _pump(
      tester,
      SizedBox(
        width: 300,
        height: 300,
        child: InteractiveViewer(
          transformationController: transform,
          child: const SizedBox(
            width: 300,
            height: 300,
            child: ColoredBox(color: Colors.blue),
          ),
        ),
      ),
    );
    final before = transform.value.getTranslation();
    await tester.drag(
      find.byType(InteractiveViewer),
      const Offset(-40, -30),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    final after = transform.value.getTranslation();
    expect(after.x, lessThan(before.x));
    expect(after.y, lessThan(before.y));
  }, variant: _desktop);

  for (final bool dark in <bool>[false, true]) {
    testWidgets('正文跨段落选择并复制，深色 $dark', (tester) async {
      await _pump(
        tester,
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[Text('first paragraph'), Text('second paragraph')],
        ),
        dark: dark,
      );
      final first = find.text('first paragraph');
      final last = find.text('second paragraph');
      final gesture = await tester.startGesture(
        tester.getTopLeft(first) + const Offset(1, 8),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(tester.getBottomRight(last) - const Offset(1, 5));
      await gesture.up();
      await tester.pump();
      await _rightClick(tester, first);
      await _menu(tester, 'Copy');
      expect(clipboard, contains('first paragraph'));
      expect(clipboard, contains('second paragraph'));
    }, variant: _desktop);
  }

  testWidgets('滚动区域内输入框和表单框使用同一右键行为', (tester) async {
    final controller = TextEditingController(
      text: 'multiline text\nsecond line',
    );
    addTearDown(controller.dispose);
    String? submitted;
    await _pump(
      tester,
      OverlayScrollView(
        child: Column(
          children: <Widget>[
            AppTextField(controller: controller, minLines: 2, maxLines: 4),
            AppTextFormField(
              initialValue: '1080',
              onFieldSubmitted: (value) => submitted = value,
            ),
          ],
        ),
      ),
    );
    for (final (int index, String text) in <(int, String)>[
      (0, controller.text),
      (1, '1080'),
    ]) {
      final field = find.byType(EditableText).at(index);
      await tester.tap(field);
      await _shortcut(tester, LogicalKeyboardKey.keyA);
      await _rightClick(tester, field);
      await _menu(tester, 'Copy');
      expect(clipboard, text);
    }
    await tester.enterText(find.byType(TextFormField), '2080');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    expect(submitted, '2080');
  }, variant: _desktop);

  testWidgets('弹窗文字和输入框复制后关闭，原页面继续可复制', (tester) async {
    final controller = TextEditingController(text: 'dialog input');
    addTearDown(controller.dispose);
    await _pump(
      tester,
      Builder(
        builder: (context) => Column(
          children: <Widget>[
            const Text('page content'),
            FilledButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => AppAlertDialog(
                  title: const Text('dialog title'),
                  content: AppTextField(controller: controller),
                  actions: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
              child: const Text('Open'),
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await _selectText(tester, find.text('dialog title'));
    await _rightClick(tester, find.text('dialog title'));
    await _menu(tester, 'Copy');
    expect(clipboard, 'dialog title');
    await tester.tap(find.byType(TextField));
    await _shortcut(tester, LogicalKeyboardKey.keyA);
    await _rightClick(tester, find.byType(EditableText));
    await _menu(tester, 'Copy');
    expect(clipboard, 'dialog input');
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await _selectText(tester, find.text('page content'));
    await _shortcut(tester, LogicalKeyboardKey.keyC);
    expect(clipboard, 'page content');
  }, variant: _desktop);

  for (final bool dark in <bool>[false, true]) {
    testWidgets('手机窄屏长按文字和输入框可以复制，深色 $dark', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = TextEditingController(text: 'mobile');
      addTearDown(controller.dispose);
      await _pump(
        tester,
        AuthStorePanel(
          title: 'title',
          child: Column(
            children: <Widget>[
              const Text('content'),
              AppTextField(controller: controller),
            ],
          ),
        ),
        dark: dark,
      );
      await tester.longPress(find.text('content'));
      await tester.pumpAndSettle();
      await _menu(tester, 'Copy');
      expect(clipboard, 'content');
      await tester.longPressAt(
        tester.getTopLeft(find.byType(EditableText)) + const Offset(15, 12),
      );
      await tester.pumpAndSettle();
      await _menu(tester, 'Copy');
      expect(clipboard, 'mobile');
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}

Future<void> _pump(
  WidgetTester tester,
  Widget body, {
  bool dark = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? AppTheme.dark() : AppTheme.light(),
      home: AppScaffold(body: body),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _rightClick(
  WidgetTester tester,
  Finder target, {
  bool hold = true,
}) async {
  final rect = tester.getRect(target);
  final gesture = await tester.startGesture(
    rect.topLeft + Offset(5, rect.height.clamp(0, 24) / 2),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  if (hold) await tester.pump(const Duration(milliseconds: 300));
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _menu(WidgetTester tester, String label) async {
  expect(find.text(label), findsOneWidget);
  await tester.tap(
    find.text(label),
    kind: AppTheme.isTouch ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
  );
  await tester.pumpAndSettle();
}

Future<void> _shortcut(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  final modifier = defaultTargetPlatform == TargetPlatform.macOS
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modifier);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(modifier);
  await tester.pump();
}

Future<void> _selectText(WidgetTester tester, Finder target) async {
  final rect = tester.getRect(target);
  final gesture = await tester.startGesture(
    rect.centerLeft + const Offset(1, 0),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.moveTo(rect.centerRight - const Offset(1, 0));
  await gesture.up();
  await tester.pump();
}

bool _isSelected(WidgetTester tester, Finder text) => tester
    .renderObject<RenderParagraph>(
      find.descendant(of: text, matching: find.byType(RichText)),
    )
    .selections
    .any((selection) => selection.isValid && !selection.isCollapsed);
