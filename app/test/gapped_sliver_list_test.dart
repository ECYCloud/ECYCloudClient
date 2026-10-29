import 'package:ecycloud_client/ui/widgets/gapped_sliver_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const int _rows = 2000;
const double _gap = 2;
const double _viewport = 600;

Future<ScrollController> _pump(
  WidgetTester tester, {
  required double rowEstimate,
  required Widget Function(int index) row,
}) async {
  tester.view.physicalSize = const Size(800, _viewport);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final ScrollController controller = ScrollController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          controller: controller,
          slivers: <Widget>[
            GappedSliverList(
              itemCount: _rows,
              gap: _gap,
              rowEstimate: rowEstimate,
              itemBuilder: (BuildContext context, int index) => row(index),
            ),
          ],
        ),
      ),
    ),
  );
  return controller;
}

void main() {
  testWidgets('拖到远处只构建可视区附近的行，不逐个布局中间条目', (WidgetTester tester) async {
    int built = 0;
    final ScrollController controller = await _pump(
      tester,
      rowEstimate: 28,
      row: (int index) {
        built++;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Text('第 $index 行 ${'内容' * (index % 7 * 20)}'),
        );
      },
    );
    for (final double fraction in <double>[0.5, 1, 0.1, 0.7]) {
      built = 0;
      controller.jumpTo(controller.position.maxScrollExtent * fraction);
      await tester.pump();
      expect(built, lessThan(100), reason: '跳到 ${fraction * 100}%');
    }
  });

  testWidgets('分隔条按实际高度估算，行高估错时由预计算收敛到实际总高', (WidgetTester tester) async {
    const double row = 30;
    const double actual = _rows * row + (_rows - 1) * _gap - _viewport;

    final ScrollController exact = await _pump(
      tester,
      rowEstimate: row,
      row: (_) => const SizedBox(height: row),
    );
    expect(exact.position.maxScrollExtent, moreOrLessEquals(actual));

    final ScrollController low = await _pump(
      tester,
      rowEstimate: 10,
      row: (_) => const SizedBox(height: row),
    );
    for (int frame = 0; frame < 600; frame++) {
      if ((low.position.maxScrollExtent - actual).abs() < 0.5) {
        break;
      }
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(low.position.maxScrollExtent, moreOrLessEquals(actual));
  });
}
