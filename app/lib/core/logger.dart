import 'dart:collection';
import 'dart:io';

import 'app_paths.dart';

enum LogLevel { trace, debug, info, warn, error }

extension LogLevelName on LogLevel {
  String get label => switch (this) {
    LogLevel.trace => 'trace',
    LogLevel.debug => 'debug',
    LogLevel.info => 'info',
    LogLevel.warn => 'warn',
    LogLevel.error => 'error',
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

  // 内核自己写日志文件是纯 append、既不轮转也没上限（sing-box log/observable.go
  // 只用 O_APPEND 打开 log.output），长期开着就一直涨。客户端这边按天分文件，
  // 并只留最近这么多天，避免同样的问题。
  static const int _retentionDays = 7;

  final Queue<LogEntry> _ring = Queue<LogEntry>();
  final List<void Function(LogEntry)> _listeners = <void Function(LogEntry)>[];

  LogLevel level = LogLevel.warn;
  IOSink? _sink;
  String? _sinkDate;

  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_ring);

  void addListener(void Function(LogEntry) listener) =>
      _listeners.add(listener);

  void removeListener(void Function(LogEntry) listener) =>
      _listeners.remove(listener);

  void trace(String source, String message) =>
      log(LogLevel.trace, source, message);

  void debug(String source, String message) =>
      log(LogLevel.debug, source, message);

  void info(String source, String message) =>
      log(LogLevel.info, source, message);

  void warn(String source, String message) =>
      log(LogLevel.warn, source, message);

  void error(String source, String message, [Object? cause]) =>
      log(LogLevel.error, source, cause == null ? message : '$message: $cause');

  // 内核日志的级别写在行内，由 sing-box 自己排版：
  // `<时间戳> ERROR [id 49ms] source: message`（log/format.go 的 Formatter.Format，
  // 级别取 FormatLevel 转大写）。整行照抄进来时必须把它解析出来，否则内核的错误行
  // 会被当成 info：日志页按级别过滤翻不出来，级别门槛也会把它挡在日志文件外。
  // 只在行首这段里找，避免消息正文里出现的同名词被当成级别。
  static LogLevel kernelLevel(String line) {
    final String head = line.length > 48 ? line.substring(0, 48) : line;

    return switch (_kernelLevel.firstMatch(head)?.group(1)) {
      'TRACE' => LogLevel.trace,
      'DEBUG' => LogLevel.debug,
      'WARN' => LogLevel.warn,
      // 我们的级别到 error 为止，内核的 FATAL / PANIC 归到这一档
      'ERROR' || 'FATAL' || 'PANIC' => LogLevel.error,
      _ => LogLevel.info,
    };
  }

  static final RegExp _kernelLevel = RegExp(
    r'\b(TRACE|DEBUG|INFO|WARN|ERROR|FATAL|PANIC)\b',
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
      _sink?.close();
      _sink = File(
        '${AppPaths.logs.path}${Platform.pathSeparator}app-$date.log',
      ).openWrite(mode: FileMode.append);
      _sinkDate = date;
      _prune(entry.time);
    }

    _sink?.writeln(entry.toString());
  }

  static final RegExp _logFileName = RegExp(r'app-(\d{4}-\d{2}-\d{2})\.log$');

  void _prune(DateTime now) {
    final DateTime oldest = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(const Duration(days: _retentionDays - 1));

    for (final FileSystemEntity entity in AppPaths.logs.listSync()) {
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

  Future<void> dispose() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
    _sinkDate = null;
  }
}
