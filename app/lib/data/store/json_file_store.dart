import 'dart:convert';
import 'dart:io';

import '../../core/logger.dart';

class JsonFileStore {
  JsonFileStore(this.file, this.source);

  final File file;
  final String source;

  Map<String, dynamic> read() {
    if (!file.existsSync()) {
      return <String, dynamic>{};
    }

    try {
      final Object? decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } on Object catch (e) {
      Logger.instance.warn(source, '读取 ${file.path} 失败，按空配置处理: $e');
      return <String, dynamic>{};
    }
  }

  void write(Map<String, dynamic> data) {
    final File temp = File('${file.path}.tmp');
    temp.writeAsStringSync(jsonEncode(data), flush: true);
    if (file.existsSync()) {
      file.deleteSync();
    }
    temp.renameSync(file.path);
  }

  void clear() {
    if (file.existsSync()) {
      file.deleteSync();
    }
  }
}
