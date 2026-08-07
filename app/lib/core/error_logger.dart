import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_paths.dart';

class ErrorLogger {
  ErrorLogger._();

  static const int _maxBytes = 10 * 1024 * 1024;
  static const int _maxMessageLen = 200;
  static const String _packagePrefix = 'package:ecycloud_client/';

  static bool _initialized = false;

  static File get logFile => File(
    '${AppPaths.logs.path}${Platform.pathSeparator}software_errors.log',
  );

  static void init() {
    if (_initialized) {
      return;
    }

    FlutterError.onError = (FlutterErrorDetails details) {
      handleFlutterError(details);
      FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      handleException(error, stack);
      return true;
    };

    _initialized = true;
  }

  static void handleFlutterError(FlutterErrorDetails details) {
    final Object exception = details.exception;
    final String className = exception.runtimeType.toString();
    final String raw = exception.toString();
    final String message = _shortenMessage(
      raw.startsWith(className) ? raw : '$className: $raw',
    );
    final ({String file, int line})? loc = _locationFromStack(details.stack);
    log('FLUTTER', message, loc?.file ?? '', loc?.line ?? 0);
    if (exception is Error && details.stack != null) {
      final String trace = _shortTrace(details.stack!);
      if (trace.isNotEmpty) {
        logRaw('[TRACE] $trace');
      }
    }
  }

  static void handleException(Object error, StackTrace stack) {
    final String className = error.runtimeType.toString();
    final String raw = error.toString();
    final String message = _shortenMessage(
      raw.startsWith(className) ? raw : '$className: $raw',
    );
    final ({String file, int line})? loc = _locationFromStack(stack);
    log('EXCEPTION', message, loc?.file ?? '', loc?.line ?? 0);
    if (error is Error) {
      final String trace = _shortTrace(stack);
      if (trace.isNotEmpty) {
        logRaw('[TRACE] $trace');
      }
    }
  }

  static bool log(String level, String message, [String file = '', int line = 0]) {
    final String date = _formatDate(DateTime.now());
    final String location = file.isEmpty ? '' : ' @ $file:$line';
    return _writeEntry('[$date] [$level] $message$location\n');
  }

  static bool logRaw(String message) {
    final String date = _formatDate(DateTime.now());
    return _writeEntry('[$date] $message\n');
  }

  static bool _writeEntry(String entry) {
    final File file = logFile;
    try {
      if (file.existsSync() && file.lengthSync() > _maxBytes) {
        final RandomAccessFile raf = file.openSync(mode: FileMode.read);
        try {
          raf.setPositionSync(file.lengthSync() - _maxBytes);
          file.writeAsBytesSync(raf.readSync(_maxBytes));
        } finally {
          raf.closeSync();
        }
      }
      file.writeAsStringSync(entry, mode: FileMode.append, flush: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static String _formatDate(DateTime time) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  static String _shortenMessage(String message) {
    if (message.length <= _maxMessageLen) {
      return message;
    }
    return '${message.substring(0, _maxMessageLen)}...';
  }

  static String _shortenPath(String path) {
    if (path.startsWith(_packagePrefix)) {
      return path.substring(_packagePrefix.length);
    }
    final String normalized = path.replaceAll('\\', '/');
    final int libIdx = normalized.lastIndexOf('/lib/');
    if (libIdx >= 0) {
      return normalized.substring(libIdx + '/lib/'.length);
    }
    return normalized.split('/').last;
  }

  static final RegExp _frameLoc = RegExp(
    r'(package:[\w.]+/[^\s:]+|file://[^\s:]+|[^\s(]+\.dart):(\d+)(?::\d+)?',
  );

  static final RegExp _frameFull = RegExp(
    r'#\d+\s+(\S+)\s+\((package:[\w.]+/[^\s:]+|file://[^\s:]+|[^\s(]+\.dart):(\d+)(?::\d+)?\)',
  );

  static ({String file, int line})? _locationFromStack(StackTrace? stack) {
    if (stack == null) {
      return null;
    }
    final Match? match = _frameLoc.firstMatch(stack.toString());
    if (match == null) {
      return null;
    }
    return (
      file: _shortenPath(match.group(1)!),
      line: int.parse(match.group(2)!),
    );
  }

  static String _shortTrace(StackTrace stack) {
    final List<String> parts = <String>[];
    for (final RegExpMatch match in _frameFull.allMatches(stack.toString())) {
      if (parts.length >= 3) {
        break;
      }
      parts.add(
        '${match.group(1)}@${_shortenPath(match.group(2)!)}:${match.group(3)}',
      );
    }
    return parts.join(' <- ');
  }
}
