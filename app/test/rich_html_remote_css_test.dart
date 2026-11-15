import 'package:ecycloud_client/ui/widgets/rich_html_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('富文本里的 CSS 不能绕开 SafeUrl 与远程图片限额加载图片', () {
    final String cleaned = withoutRemoteCss(
      '<STYLE>li{list-style-image:url(https://tracker.test/a.png)}</STYLE>'
      '<ul style="list-style-image:url(https://tracker.test/b.png)">'
      '<li style="LIST-STYLE: URL(https://tracker.test/c.png) inside">a</li>'
      r'<li style="list-style-image:\75rl(https://tracker.test/d.png)">b</li>'
      '<li style="color: red">c</li>'
      '</ul><svg><style>li{list-style:url(https://tracker.test/e.png)}</style></svg>',
    );
    expect(cleaned.toLowerCase(), isNot(contains('<style')));
    expect(cleaned.toLowerCase(), isNot(contains('url(')));
    expect(cleaned, isNot(contains('tracker.test')));
    expect(cleaned, contains('style="color: red"'));
    expect(cleaned, contains('<li>a</li>'));
  });
}
