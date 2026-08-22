import 'package:ecycloud_client/domain/update/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

AppUpdate at(String current, String latest) =>
    AppUpdate(current: current, latest: latest, installer: null);

void main() {
  test('同通道按号段比大小', () {
    expect(at('1.0.2', '1.0.3').outdated, isTrue);
    expect(at('1.0.2', '1.0.2').outdated, isFalse);
    expect(at('1.0.3', '1.0.2').outdated, isFalse);

    expect(at('Pre 1.0.2', 'Pre 1.0.3').outdated, isTrue);
    expect(at('Pre 1.0.3', 'Pre 1.0.3').outdated, isFalse);
    expect(at('Pre 1.0.4', 'Pre 1.0.3').outdated, isFalse);
  });

  test('Pre 落回 Last 是通道切换，正式版号段更低也要更新', () {
    expect(at('Pre 1.0.3', '1.0.1').outdated, isTrue);
    expect(at('Pre 1.0.1', '1.0.1').outdated, isTrue);
  });

  test('调试构建的 dev 版本不会被判成过时', () {
    expect(at('dev', '1.0.3').outdated, isFalse);
  });
}
