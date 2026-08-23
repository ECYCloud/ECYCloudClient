import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('桌面三端都会注册图片放大缩小指针', () {
    final String src = File('lib/ui/widgets/zoom_cursors.dart').readAsStringSync();
    expect(src, contains('Platform.isWindows'));
    expect(src, contains('Platform.isMacOS'));
    expect(src, contains('Platform.isLinux'));
    expect(src, contains('createCustomCursor/windows'));
    expect(src, contains('cursor.create'));
    expect(src, contains('cursor.set'));
    expect(
      File('macos/Runner/PlatformChannel.swift').readAsStringSync(),
      contains('cursor.create'),
    );
    expect(
      File('macos/Runner/PlatformChannel.swift').readAsStringSync(),
      contains('didUpdateMouseCursor:'),
    );
    expect(
      File('linux/runner/platform_channel.cc').readAsStringSync(),
      contains('cursor.create'),
    );
  });

  test('macOS 安装器按语言带中文许可译本', () {
    final String src = File('../scripts/build-macos.sh').readAsStringSync();
    expect(src, contains('LICENSE.zh-CN.txt'));
    expect(src, contains('LICENSE.zh-TW.txt'));
    expect(src, contains('zh_CN.lproj'));
    expect(src, contains('zh-Hans.lproj'));
    expect(src, contains('zh_TW.lproj'));
    expect(src, contains('zh-Hant.lproj'));
  });
}
