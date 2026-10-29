import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ecycloud_client/platform/windows/windows_platform_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Windows 系统凭据保护', () {
    final platform = WindowsPlatformService();

    test('后台加密和解密保持原有凭据格式', () async {
      const secret = '合成凭据-test-123';
      final blob = await platform.protectSecret('token', secret);
      expect(base64Decode(blob), isNotEmpty);
      expect(blob, isNot(contains(secret)));
      expect(await platform.unprotectSecret('token', blob), secret);
    });

    test('不同用途的凭据不能互相解密', () async {
      final blob = await platform.protectSecret('remembered_password', 'test');
      expect(await platform.unprotectSecret('token', blob), isNull);
      expect(
        await platform.unprotectSecret('remembered_password', blob),
        'test',
      );
    });

    test('损坏凭据保持原有失败语义', () async {
      for (final blob in [
        '',
        'invalid-base64',
        base64Encode([1, 2, 3]),
      ]) {
        expect(await platform.unprotectSecret('token', blob), isNull);
      }
    });

    test('并发处理不会混入另一份凭据', () async {
      final secrets = ['session-a', 'session-b', 'password-a', 'password-b'];
      final results = await Future.wait([
        for (var i = 0; i < secrets.length; i++)
          (() async {
            final name = i < 2 ? 'token' : 'remembered_password';
            final blob = await platform.protectSecret(name, secrets[i]);
            return platform.unprotectSecret(name, blob);
          })(),
      ]);
      expect(results, secrets);
    });
  }, skip: !Platform.isWindows);
}
