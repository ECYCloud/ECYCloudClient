import 'package:ecycloud_client/ui/widgets/section_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('同宽两列里，标签长短不同的取值右边缘对齐', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            child: Column(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: InfoRow(label: '到期', value: '2027-04-07'),
                    ),
                    Expanded(
                      child: InfoRow(label: '剩余天数', value: '252 天'),
                    ),
                  ],
                ),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: InfoRow(label: '限速', value: '不限速'),
                    ),
                    Expanded(
                      child: InfoRow(label: '在线 IP', value: '2 / 2'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(
      tester.getRect(find.text('不限速')).right,
      tester.getRect(find.text('2027-04-07')).right,
    );
    expect(
      tester.getRect(find.text('2 / 2')).right,
      tester.getRect(find.text('252 天')).right,
    );
  });
}
