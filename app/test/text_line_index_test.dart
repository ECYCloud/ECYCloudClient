import 'dart:convert';

import 'package:ecycloud_client/core/text_line_index.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('断行与 LineSplitter 一致', () async {
    for (final String text in <String>[
      '',
      'a',
      'a\n',
      'a\r\nb\rc\n\nd',
      '\n\n',
      'payload:\n  - DOMAIN,apple.com\n',
    ]) {
      final TextLineIndex index = await TextLineIndex.build(text);
      expect(
        <String>[for (int i = 0; i < index.length; i++) index[i]],
        const LineSplitter().convert(text),
        reason: jsonEncode(text),
      );
    }
  });

  test('超长单行只截取显示部分，且记下最长的行', () async {
    final String long = 'x' * (TextLineIndex.maxLineChars + 50);
    final TextLineIndex index = await TextLineIndex.build('short\n$long\nend');
    expect(index[1].length, TextLineIndex.maxLineChars + 1);
    expect(index[1].endsWith('…'), isTrue);
    expect(index.widest, contains(1));
  });

  test('大文件在后台建索引，按需取行', () async {
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < 300000; i++) {
      buffer.writeln('DOMAIN-SUFFIX,example$i.com');
    }
    final TextLineIndex index = await TextLineIndex.build(buffer.toString());
    expect(index.length, 300000);
    expect(index[0], 'DOMAIN-SUFFIX,example0.com');
    expect(index[299999], 'DOMAIN-SUFFIX,example299999.com');
  });
}
