import 'dart:convert';
import 'dart:io';

import 'package:ecycloud_client/core/logger.dart';
import 'package:ecycloud_client/data/store/json_file_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('损坏的配置不能将原文中的秘密写入日志', () {
    final Directory directory = Directory.systemTemp.createTempSync(
      'ecycloud-json-security-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final File file = File('${directory.path}/config.json');
    file.writeAsStringSync('{"password":"private-secret",BROKEN}');
    final JsonFileStore store = JsonFileStore(file, 'json-security-test');
    expect(store.read(), isEmpty);
    final String log = Logger.instance.entries.last.message;
    expect(log, contains('失败'));
    expect(log, isNot(contains('private-secret')));
    expect(log, isNot(contains('BROKEN')));
    store.write(<String, dynamic>{'value': 'normal'});
    expect(store.read(), <String, dynamic>{'value': 'normal'});
  });

  test('替换文件失败不能删除已保存的数据，重试后可继续更新', () {
    final Directory directory = Directory.systemTemp.createTempSync(
      'ecycloud-json-replace-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final File file = File('${directory.path}/config.json');
    final File temp = File('${file.path}.tmp');
    final JsonFileStore store = JsonFileStore(file, 'json-replace-test');
    store.write(<String, dynamic>{'value': 'saved'});
    expect(
      () => IOOverrides.runZoned(
        () => store.write(<String, dynamic>{'value': 'new'}),
        createFile: (_) => _RenameFailureFile(temp),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(store.read(), <String, dynamic>{'value': 'saved'});
    store.write(<String, dynamic>{'value': 'new'});
    expect(store.read(), <String, dynamic>{'value': 'new'});
    expect(temp.existsSync(), isFalse);
  });
}

class _RenameFailureFile implements File {
  _RenameFailureFile(this.file);

  final File file;

  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => file.writeAsStringSync(
    contents,
    mode: mode,
    encoding: encoding,
    flush: flush,
  );

  @override
  File renameSync(String newPath) =>
      throw FileSystemException('模拟文件替换失败', newPath);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
