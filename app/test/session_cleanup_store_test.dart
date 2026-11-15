import 'dart:io';
import 'dart:convert';

import 'package:ecycloud_client/data/store/credential_store.dart';
import 'package:ecycloud_client/data/store/json_file_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late File file;
  late CredentialStore store;
  setUp(() {
    final Directory base = Directory('build/security-session')
      ..createSync(recursive: true);
    directory = base.createTempSync('store-');
    file = File('${directory.path}/credentials.json');
    store = CredentialStore(store: JsonFileStore(file, 'test'));
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test('退出时会话键随令牌一起删除，设备标识保留', () {
    final String device = store.deviceId();
    store.saveSessionKey('a' * 64);
    store.save(
      Credentials(
        token: 'test',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        email: 'a@example.test',
      ),
    );
    final CredentialStore restored = CredentialStore(
      store: JsonFileStore(file, 'test'),
    );
    expect(restored.sessionKey, 'a' * 64);
    restored.clear();
    expect(store.sessionKey, isEmpty);
    expect(store.load(), isNull);
    expect(store.deviceId(), device);
  });

  test('会话键会拼进目录路径，只接受 64 位小写十六进制', () {
    expect(() => store.saveSessionKey('../escape'), throwsArgumentError);
    expect(() => store.saveSessionKey('A' * 64), throwsArgumentError);
    file.writeAsStringSync(jsonEncode(<String, String>{'session_key': '../x'}));
    expect(store.sessionKey, isEmpty);
    file.writeAsStringSync('{broken');
    expect(store.sessionKey, isEmpty);
  });

  test('新账户令牌不能把旧账户记住的密码配给新邮箱', () {
    store.saveRemembered(email: 'a@example.test', password: 'encrypted-a');
    store.save(
      Credentials(
        token: 'encrypted-token-b',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        email: 'b@example.test',
      ),
    );
    expect(store.load()?.email, 'b@example.test');
    expect(store.loadRemembered()?.email, 'a@example.test');
    expect(store.loadRemembered()?.password, 'encrypted-a');
    store.saveRemembered(email: 'c@example.test', password: 'encrypted-c');
    expect(store.load()?.email, 'b@example.test');
    expect(store.loadRemembered()?.email, 'c@example.test');
  });

  test('旧格式未绑定账户的记忆密码不得自动配给当前邮箱', () {
    file.writeAsStringSync(
      jsonEncode({
        'remember': true,
        'email': 'b@example.test',
        'password': 'encrypted-a',
      }),
    );
    expect(store.loadRemembered(), isNull);
    store.clearRemembered();
    expect(jsonDecode(file.readAsStringSync()), {'email': 'b@example.test'});
  });
}
