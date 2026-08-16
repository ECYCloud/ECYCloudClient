import 'dart:collection';
import 'dart:convert';
import 'dart:io';

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

  // 内核的级别写在行内，必须解析出来，否则错误行会被当成 info：日志页按级别过滤
  // 翻不出来，级别门槛也会把它挡在日志文件外。两种来源的排版不同，都要认：
  //   进程标准输出是 logrus 的 key=value：`time="..." level=warning msg="..."`
  //   Clash API 的 /logs 只给类型与正文，由 logStream 拼成：`WARNING <正文>`
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

  static final RegExp _logfmtLevel = RegExp(r'(?:^|\s)level=([a-z]+)');
  static final RegExp _prefixLevel = RegExp(
    r'^(DEBUG|INFO|WARNING|ERROR|FATAL|PANIC)\b',
  );

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

    appendCapped(
      File('${AppPaths.logs.path}${Platform.pathSeparator}app-$date.log'),
      '${entry.toString()}\n',
    );
  }

  // 裁到上限以下留出续写空间，否则触顶后每行都要重写整份文件
  static void appendCapped(File file, String line) {
    final int incoming = utf8.encode(line).length;
    final int current = file.existsSync() ? file.lengthSync() : 0;
    if (current + incoming > _maxFileBytes) {
      trimToLastBytes(file, _maxFileBytes * 4 ~/ 5);
    }
    try {
      file.writeAsStringSync(line, mode: FileMode.append);
    } on FileSystemException {}
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
      } on FileSystemException {
        // 文件可能正被外部程序占用，下次轮转再试
      }
    }
  }

  Future<void> flush() async {}

  Future<void> dispose() async {
    _sinkDate = null;
  }
}
