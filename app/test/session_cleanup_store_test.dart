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

  test('清理中断标记在销毁凭证和重新加载后仍存在', () {
    store.save(
      Credentials(
        token: 'test',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        email: 'a@example.test',
      ),
    );
    final String device = store.deviceId();
    store.beginSessionCleanup();
    store.clear();
    final CredentialStore restored = CredentialStore(
      store: JsonFileStore(file, 'test'),
    );
    expect(restored.sessionCleanupPending, isTrue);
    expect(restored.load(), isNull);
    expect(restored.deviceId(), device);
    restored.finishSessionCleanup();
    expect(store.sessionCleanupPending, isFalse);
  });

  test('凭证文件损坏不能使清理标记失效', () {
    store.beginSessionCleanup();
    file.writeAsStringSync('{broken');
    expect(store.sessionCleanupPending, isTrue);
  });

  test('异常标记路径必须阻止开始和完成清理', () {
    Directory('${file.path}.session-ending').createSync();
    expect(store.sessionCleanupPending, isTrue);
    expect(store.beginSessionCleanup, throwsA(isA<FileSystemException>()));
    expect(store.finishSessionCleanup, throwsA(isA<FileSystemException>()));
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
