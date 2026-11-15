import 'dart:io';

import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/platform/macos/macos_platform_service.dart';
import 'package:flutter_test/flutter_test.dart';

// 下载地址与 sha256 同出自 GitHub 应答：发布被顶替时两者一起换，只有安装包签名能说明出自同一开发者
void main() {
  const String signedApp = '''
Executable=/Applications/ECYCloud.app/Contents/MacOS/ECYCloud
Identifier=com.ecycloud.client
TeamIdentifier=ABCDE12345
''';

  String installer(
    String team, {
    String status =
        'signed by a developer certificate issued by Apple for distribution',
  }) =>
      '''
Package "ECYCloud-0.1.1-macos-arm64.pkg":
   Status: $status
   Notarization: trusted by the Apple notary service
   Certificate Chain:
    1. Developer ID Installer: Example Inc ($team)
       Expires: 2027-11-26 02:17:29 +0000
       ------------------------------------------------------------------------
    2. Developer ID Certification Authority
       ------------------------------------------------------------------------
    3. Apple Root CA
''';

  Future<ProcessResult> Function(String, List<String>) runner(
    String codesign,
    String pkgutil, {
    int pkgutilExit = 0,
    List<String>? calls,
  }) => (String executable, List<String> arguments) async {
    calls?.add(executable);
    return executable.endsWith('codesign')
        ? ProcessResult(1, 0, '', codesign)
        : ProcessResult(2, pkgutilExit, pkgutil, '');
  };

  test('同一团队 Developer ID Installer 签名的安装包可以安装', () async {
    await MacosPlatformService.verifyInstaller(
      '/tmp/update.pkg',
      run: runner(signedApp, installer('ABCDE12345')),
    );
  });

  for (final (String name, String output, int exit) in <(String, String, int)>[
    ('其它团队签名', installer('ZYXWV98765'), 0),
    ('未签名', 'Package "update.pkg":\n   Status: no signature\n', 1),
    (
      '自签证书冒用本团队名称',
      installer('ABCDE12345', status: 'signed by untrusted certificate'),
      0,
    ),
  ]) {
    test('拒绝$name的安装包', () async {
      await expectLater(
        MacosPlatformService.verifyInstaller(
          '/tmp/update.pkg',
          run: runner(signedApp, output, pkgutilExit: exit),
        ),
        throwsA(isA<PlatformServiceException>()),
      );
    });
  }

  test('本机未带团队签名的开发构建不核对安装包', () async {
    final List<String> calls = <String>[];
    await MacosPlatformService.verifyInstaller(
      '/tmp/update.pkg',
      run: runner(
        'Signature=adhoc\nTeamIdentifier=not set\n',
        installer('ZYXWV98765'),
        calls: calls,
      ),
    );
    expect(calls, <String>['/usr/bin/codesign']);
  });
}
