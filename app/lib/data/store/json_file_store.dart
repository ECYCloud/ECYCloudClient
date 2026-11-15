import 'dart:convert';
import 'dart:io';

import '../../core/logger.dart';

class JsonFileStore {
  JsonFileStore(File file, this.source) : _locate = (() => file);

  JsonFileStore.at(this._locate, this.source);

  final File Function() _locate;
  final String source;

  File get file => _locate();

  Map<String, dynamic> read() {
    final File file = this.file;
    if (!file.existsSync()) {
      return <String, dynamic>{};
    }

    try {
      final Object? decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } on Object catch (e) {
      final String detail = e is FormatException ? e.message : '$e';
      Logger.instance.warn(source, '读取 ${file.path} 失败，按空配置处理: $detail');
      return <String, dynamic>{};
    }
  }

  void write(Map<String, dynamic> data) {
    final File file = this.file;
    final File temp = File('${file.path}.tmp');
    temp.writeAsStringSync(jsonEncode(data), flush: true);
    temp.renameSync(file.path);
  }

  void clear() {
    final File file = this.file;
    if (file.existsSync()) {
      file.deleteSync();
    }
  }
}
