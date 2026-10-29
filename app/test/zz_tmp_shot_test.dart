import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/multiline_content_field.dart';
import 'package:ecycloud_client/ui/widgets/option_dropdown.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const Key shotKey = Key('shot');

Future<void> save(WidgetTester tester, String path, double ratio) async {
  final RenderRepaintBoundary boundary =
      tester.renderObject(find.byKey(shotKey)) as RenderRepaintBoundary;
  final ui.Image? image = await tester.runAsync(
    () => boundary.toImage(pixelRatio: ratio),
  );
  final ByteData? data = await tester.runAsync<ByteData?>(
    () => image!.toByteData(format: ui.ImageByteFormat.png),
  );
  File(path).writeAsBytesSync(data!.buffer.asUint8List());
}

void main() {
  testWidgets('menu 1:1', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(260, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark().copyWith(platform: TargetPlatform.windows),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OptionDropdown<int>(
                  width: 200,
                  value: 0,
                  options: <int, String>{for (int i = 0; i < 30; i++) i: 'x $i'},
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(OptionDropdown<int>));
    await tester.pumpAndSettle();
    await save(tester, 'D:/tmp/w-menu.png', 1);
    await save(tester, 'D:/tmp/w-menu-2x.png', 2);
  });

  testWidgets('field 1:1', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final TextEditingController controller = TextEditingController(
      text: List<String>.generate(
        40,
        (int i) => 'line $i ${'content' * 20}',
      ).join('\n'),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark().copyWith(platform: TargetPlatform.windows),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(10),
              child: MultilineContentField(
                controller: controller,
                labelText: 'content',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      pointer: 1,
    );
    addTearDown(() => mouse.removePointer());
    final Rect field = tester.getRect(find.byType(TextField));
    await mouse.addPointer(location: field.center);
    await tester.pumpAndSettle();
    await mouse.moveTo(field.centerRight - const Offset(5, 0));
    await tester.pumpAndSettle();
    await save(tester, 'D:/tmp/w-field.png', 1);
    await save(tester, 'D:/tmp/w-field-2x.png', 2);
  });
}
