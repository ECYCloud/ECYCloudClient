import 'package:ecycloud_client/ui/widgets/section_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('数值在标签下方居中，整块仍从格子左边起', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: MetricTile(
                  icon: Icons.blur_on,
                  label: 'Goroutines',
                  value: '310',
                ),
              ),
              Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );

    final Rect icon = tester.getRect(find.byIcon(Icons.blur_on));
    final Rect label = tester.getRect(find.text('Goroutines'));
    final Rect value = tester.getRect(find.text('310'));

    expect(icon.left, 0);
    expect(
      value.center.dx,
      moreOrLessEquals((icon.left + label.right) / 2, epsilon: 0.5),
    );
  });
}
