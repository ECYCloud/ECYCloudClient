import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'app_paths.dart';

/// 取值与 mihomo 的合法级别一一对应：label 同时用作内核配置的 `log-level`、
/// `/logs?level=` 的查询值与设置项的持久化值，内核不认 `warn` / `trace`。
enum LogLevel { debug, info, warn, error, silent }

extension LogLevelName on LogLevel {
  String get label => switch (this) {
    LogLevel.debug => 'debug',
    LogLevel.info => 'info',
    LogLevel.warn => 'warning',
    LogLevel.error => 'error',
    LogLevel.silent => 'silent',
  };
}

class LogEntry {
  LogEntry(this.time, this.level, this.source, this.message);

  final DateTime time;
  final LogLevel level;
  final String source;
  final String message;

  @override
  String toString() =>
      '${time.toIso8601String()} [${level.label}] [$source] $message';
}

class Logger {
  Logger._();

  static final Logger instance = Logger._();

  static const int _ringCapacity = 2000;
  static const int _maxFileBytes = 10 * 1024 * 1024;
  static const int _retentionDays = 30;

  static final RegExp _logFileName = RegExp(r'app-(\d{4}-\d{2}-\d{2})\.log$');

  final Queue<LogEntry> _ring = Queue<LogEntry>();
  final List<void Function(LogEntry)> _listeners = <void Function(LogEntry)>[];

  LogLevel level = LogLevel.warn;
  LogFileSink? _sink;
  String? _sinkDate;

  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_ring);

  void addListener(void Function(LogEntry) listener) =>
      _listeners.add(listener);

  void removeListener(void Function(LogEntry) listener) =>
      _listeners.remove(listener);

  void debug(String source, String message) =>
      log(LogLevel.debug, source, message);

  void info(String source, String message) =>
      log(LogLevel.info, source, message);

  void warn(String source, String message) =>
      log(LogLevel.warn, source, message);

  void error(String source, String message, [Object? cause]) =>
      log(LogLevel.error, source, cause == null ? message : '$message: $cause');

  // 内核级别写在行内，两种排版都要认，否则错误行会被当成 info：
  //   进程 stdout：`time="..." level=warning msg="..."`
  //   /logs 流：`WARNING <正文>`
  static LogLevel kernelLevel(String line) {
    // 只在 msg= 之前找，避免正文里出现的 level= 字样被当成级别
    final int body = line.indexOf(' msg=');
    final String head = body < 0 ? line : line.substring(0, body);

    final String? level =
        _logfmtLevel.firstMatch(head)?.group(1) ??
        _prefixLevel.firstMatch(line)?.group(1)?.toLowerCase();

    return switch (level) {
      'debug' => LogLevel.debug,
      'warning' => LogLevel.warn,
      // 我们的级别到 error 为止，内核的 fatal / panic 归到这一档
      'error' || 'fatal' || 'panic' => LogLevel.error,
      _ => LogLevel.info,
    };
  }

  static String kernelMessage(String line) {
    final int body = line.indexOf(' msg=');
    if (body >= 0) {
      return _logfmtValue(line.substring(body + 5));
    }
    final Match? prefix = _prefixLevel.firstMatch(line);
    if (prefix != null &&
        prefix.end < line.length &&
        line.codeUnitAt(prefix.end) == 0x20) {
      return line.substring(prefix.end + 1);
    }
    return line;
  }

  static final RegExp _logfmtLevel = RegExp(r'(?:^|\s)level=([a-z]+)');
  static final RegExp _prefixLevel = RegExp(
    r'^(DEBUG|INFO|WARNING|ERROR|FATAL|PANIC)\b',
  );

  static String _logfmtValue(String raw) {
    if (raw.isEmpty) {
      return '';
    }
    if (raw.codeUnitAt(0) != 0x22) {
      final int end = raw.indexOf(' ');
      return end < 0 ? raw : raw.substring(0, end);
    }
    final StringBuffer out = StringBuffer();
    for (int i = 1; i < raw.length; i++) {
      final int unit = raw.codeUnitAt(i);
      if (unit == 0x5C && i + 1 < raw.length) {
        final int next = raw.codeUnitAt(++i);
        out.writeCharCode(switch (next) {
          0x6E => 0x0A,
          0x74 => 0x09,
          0x72 => 0x0D,
          _ => next,
        });
        continue;
      }
      if (unit == 0x22) {
        break;
      }
      out.writeCharCode(unit);
    }
    return out.toString();
  }

  // 环形缓冲不做级别过滤，否则日志页调高级别后看不到已发生的记录；
  // level 只决定哪些条目落盘，避免调试级别把磁盘写满
  void log(LogLevel entryLevel, String source, String message) {
    final LogEntry entry = LogEntry(
      DateTime.now(),
      entryLevel,
      source,
      message,
    );

    _ring.addLast(entry);
    while (_ring.length > _ringCapacity) {
      _ring.removeFirst();
    }

    _write(entry);

    for (final void Function(LogEntry) listener
        in List<void Function(LogEntry)>.of(_listeners)) {
      listener(entry);
    }
  }

  void _write(LogEntry entry) {
    if (entry.level.index < level.index) {
      return;
    }

    final String date =
        '${entry.time.year.toString().padLeft(4, '0')}-'
        '${entry.time.month.toString().padLeft(2, '0')}-'
        '${entry.time.day.toString().padLeft(2, '0')}';

    if (_sinkDate != date) {
      _sinkDate = date;
      pruneExpired(AppPaths.logs, entry.time);
    }

    (_sink ??= LogFileSink(AppPaths.logs)).write(date, '${entry.toString()}\n');
  }

  static void trimToLastBytes(File file, int maxBytes) {
    if (!file.existsSync()) {
      return;
    }
    final int length = file.lengthSync();
    if (length <= maxBytes) {
      return;
    }
    final RandomAccessFile raf = file.openSync(mode: FileMode.read);
    try {
      raf.setPositionSync(length - maxBytes);
      file.writeAsBytesSync(raf.readSync(maxBytes));
    } finally {
      raf.closeSync();
    }
  }

  static void pruneExpired(Directory dir, DateTime now) {
    if (!dir.existsSync()) {
      return;
    }
    final DateTime oldest = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(const Duration(days: _retentionDays - 1));

    for (final FileSystemEntity entity in dir.listSync()) {
      final RegExpMatch? match = _logFileName.firstMatch(entity.path);
      final DateTime? day = match == null
          ? null
          : DateTime.tryParse(match.group(1)!);
      if (day == null || !day.isBefore(oldest)) {
        continue;
      }
      try {
        entity.deleteSync();
      } on FileSystemException catch (_) {}
    }
  }

  Future<void> flush() async {
    _sink?.flush();
  }

  Future<void> dispose() async {
    _sink?.close();
    _sink = null;
    _sinkDate = null;
  }
}

// 句柄必须常开、字节数记在内存：内核峰值 800 行/秒，逐行开-写-关实测 7.7ms/行，
// log() 在 UI isolate 上会卡死。常开句柄 0.0125ms/行，只有触顶裁切才碰文件长度。
class LogFileSink {
  LogFileSink(this.directory, {this.maxBytes = Logger._maxFileBytes});

  final Directory directory;
  final int maxBytes;

  RandomAccessFile? _handle;
  String? _date;
  int _bytes = 0;

  File fileFor(String date) =>
      File('${directory.path}${Platform.pathSeparator}app-$date.log');

  void write(String date, String line) {
    if (_date != date) {
      _open(date);
    }
    final Uint8List bytes = utf8.encode(line);
    if (_handle != null && _bytes + bytes.length > maxBytes) {
      _rotate(date);
    }
    final RandomAccessFile? handle = _handle;
    if (handle == null) {
      return;
    }
    try {
      handle.writeFromSync(bytes);
      _bytes += bytes.length;
    } on FileSystemException {
      close();
    }
  }

  void flush() {
    try {
      _handle?.flushSync();
    } on FileSystemException {
      close();
    }
  }

  void close() {
    try {
      _handle?.closeSync();
    } on FileSystemException catch (_) {}
    _handle = null;
    _date = null;
  }

  void _open(String date) {
    close();
    try {
      // 追加句柄的写入位置固定在末尾，长度只需在开的时候读一次
      final RandomAccessFile handle = fileFor(
        date,
      ).openSync(mode: FileMode.append);
      _handle = handle;
      _bytes = handle.lengthSync();
      _date = date;
    } on FileSystemException {
      _handle = null;
      _date = null;
    }
  }

  // 裁到上限的 4/5 留出续写空间，否则触顶后每行都要重写整份文件。
  // 裁切要独占文件，先放掉句柄再重开。
  void _rotate(String date) {
    close();
    try {
      Logger.trimToLastBytes(fileFor(date), maxBytes * 4 ~/ 5);
    } on FileSystemException catch (_) {}
    _open(date);
  }
}
