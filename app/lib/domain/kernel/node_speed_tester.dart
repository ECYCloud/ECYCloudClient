import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

class NodeSpeedTestException implements Exception {
  NodeSpeedTestException(this.message);

  final String message;

  @override
  String toString() => message;
}

class NodeSpeedTester {
  static const String downloadUrl =
      'https://speed.cloudflare.com/__down?bytes=100000000';
  static const String referer = 'https://speed.cloudflare.com/';
  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  static const Duration timeout = Duration(seconds: 10);
  static const Duration connectTimeout = Duration(seconds: 2);
  static const Duration isolateTimeout = Duration(seconds: 15);
  static const Duration sampleInterval = Duration(seconds: 1);
  static const int minBytes = 32768;
  static const int readSize = 256 * 1024;

  static int bytesPerSecond(int bytes, Duration elapsed) {
    final int micros = elapsed.inMicroseconds;
    if (bytes <= 0 || micros <= 0) {
      return 0;
    }
    return (bytes * 1000000 / micros).round();
  }

  static int windowSpeed(int bytes, Duration elapsed) {
    final int millis = elapsed.inMilliseconds + 1;
    if (bytes <= 0 || millis <= sampleInterval.inMilliseconds) {
      return 0;
    }
    return (bytes * 1000 / millis).round();
  }

  static int peak(int current, int sample) => sample > current ? sample : current;

  static int httpStatus(String head) {
    final Match? match = RegExp(r'^HTTP/1\.[01] (\d{3})').firstMatch(head);
    if (match == null) {
      return 0;
    }
    return int.parse(match.group(1)!);
  }

  static int indexOfHeaderEnd(List<int> data) {
    for (int i = 0; i < data.length - 3; i++) {
      if (data[i] == 13 &&
          data[i + 1] == 10 &&
          data[i + 2] == 13 &&
          data[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  static void _tune(RawSocket socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    socket.readEventsEnabled = true;
    final bool bsd = !Platform.isLinux && !Platform.isAndroid;
    try {
      socket.setRawOption(
        RawSocketOption.fromInt(bsd ? 0xffff : 1, bsd ? 0x1002 : 8, 1024 * 1024),
      );
    } on Object {
      return;
    }
  }

  static void _writeAll(RawSocket socket, List<int> bytes) {
    int offset = 0;
    while (offset < bytes.length) {
      final int n = socket.write(
        offset == 0 ? bytes : bytes.sublist(offset),
      );
      if (n <= 0) {
        throw NodeSpeedTestException('测速失败');
      }
      offset += n;
    }
  }

  static List<int> _connectRequest(String host, int port) => ascii.encode(
    'CONNECT $host:$port HTTP/1.1\r\nHost: $host:$port\r\n\r\n',
  );

  static List<int> _getRequest(Uri uri) {
    final String path = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
    return ascii.encode(
      'GET $path HTTP/1.1\r\n'
      'Host: ${uri.host}\r\n'
      'User-Agent: $userAgent\r\n'
      'Referer: $referer\r\n'
      'Connection: close\r\n'
      '\r\n',
    );
  }

  Future<int> download({
    required int proxyPort,
    void Function(int speed)? onPeak,
  }) async {
    final ReceivePort reply = ReceivePort();
    final ReceivePort peaks = ReceivePort();
    final StreamSubscription<dynamic> peakSub = peaks.listen((Object? msg) {
      if (msg is int && msg > 0) {
        onPeak?.call(msg);
      }
    });
    final Isolate isolate = await Isolate.spawn(
      _isolateMain,
      (proxyPort, peaks.sendPort, reply.sendPort),
    );
    try {
      final Object? msg = await reply.first.timeout(isolateTimeout);
      if (msg is String) {
        throw NodeSpeedTestException(msg);
      }
      if (msg is int && msg > 0) {
        return msg;
      }
      throw NodeSpeedTestException('测速失败');
    } on TimeoutException {
      throw NodeSpeedTestException('测速超时');
    } finally {
      isolate.kill(priority: Isolate.immediate);
      await peakSub.cancel();
      peaks.close();
      reply.close();
    }
  }

  static Future<void> _isolateMain((int, SendPort, SendPort) args) async {
    final (int proxyPort, SendPort peaks, SendPort reply) = args;
    final ({int speed, String? error}) result = await _downloadOnWorker(
      proxyPort,
      peaks,
    );
    reply.send(result.error ?? result.speed);
  }

  static Future<({int speed, String? error})> _downloadOnWorker(
    int proxyPort,
    SendPort? peaks,
  ) async {
    try {
      return (
        speed: await NodeSpeedTester()._pull(proxyPort, peaks),
        error: null,
      );
    } on NodeSpeedTestException catch (e) {
      return (speed: 0, error: e.message);
    } on Object catch (e) {
      return (speed: 0, error: e.toString());
    }
  }

  Future<int> _pull(int proxyPort, SendPort? peaks) async {
    final Uri uri = Uri.parse(downloadUrl);
    final int port = uri.hasPort ? uri.port : 443;
    final Stopwatch total = Stopwatch()..start();
    final RawSocket raw = await RawSocket.connect(
      InternetAddress.loopbackIPv4,
      proxyPort,
      timeout: connectTimeout,
    );
    _tune(raw);
    RawSecureSocket? tls;
    try {
      final Future<StreamSubscription<RawSocketEvent>> connectReady =
          _awaitConnectOk(raw, connectTimeout);
      _writeAll(raw, _connectRequest(uri.host, port));
      final StreamSubscription<RawSocketEvent> connectSub = await connectReady;
      final Duration handshakeLimit = timeout - total.elapsed;
      if (handshakeLimit <= Duration.zero) {
        throw NodeSpeedTestException('测速超时');
      }
      final RawSecureSocket secure = await RawSecureSocket.secure(
        raw,
        host: uri.host,
        subscription: connectSub,
      ).timeout(handshakeLimit);
      tls = secure;
      _tune(secure);
      final Future<int> body = _readDownload(secure, total, peaks);
      _writeAll(secure, _getRequest(uri));
      return await body;
    } on TimeoutException {
      throw NodeSpeedTestException('测速超时');
    } on SocketException catch (e) {
      throw NodeSpeedTestException('无法连接测速地址：$e');
    } finally {
      if (tls != null) {
        tls.close();
      } else {
        raw.close();
      }
    }
  }

  static Future<StreamSubscription<RawSocketEvent>> _awaitConnectOk(
    RawSocket socket,
    Duration limit,
  ) async {
    final List<int> buf = <int>[];
    final Completer<void> done = Completer<void>();
    final StreamSubscription<RawSocketEvent> sub = socket.listen(
      (RawSocketEvent event) {
        if (done.isCompleted) {
          return;
        }
        if (event == RawSocketEvent.readClosed) {
          done.completeError(NodeSpeedTestException('测速连接已关闭'));
          return;
        }
        if (event != RawSocketEvent.read) {
          return;
        }
        while (true) {
          final Uint8List? byte = socket.read(1);
          if (byte == null || byte.isEmpty) {
            return;
          }
          buf.add(byte[0]);
          final int end = indexOfHeaderEnd(buf);
          if (end < 0) {
            continue;
          }
          final String head = ascii.decode(buf.sublist(0, end), allowInvalid: true);
          if (httpStatus(head) != 200) {
            done.completeError(
              NodeSpeedTestException('测速代理返回 HTTP ${httpStatus(head)}'),
            );
            return;
          }
          done.complete();
          return;
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!done.isCompleted) {
          done.completeError(error, stack);
        }
      },
      onDone: () {
        if (!done.isCompleted) {
          done.completeError(NodeSpeedTestException('测速连接已关闭'));
        }
      },
      cancelOnError: false,
    );
    try {
      await done.future.timeout(limit);
      return sub;
    } on Object {
      await sub.cancel();
      rethrow;
    }
  }

  static Future<int> _readDownload(
    RawSocket socket,
    Stopwatch total,
    SendPort? peaks,
  ) async {
    final BytesBuilder headBuf = BytesBuilder(copy: false);
    String? head;
    final Stopwatch watch = Stopwatch();
    int received = 0;
    int windowBytes = 0;
    int maxSpeed = 0;
    int checkpointMs = 0;
    final Completer<void> done = Completer<void>();

    void takeWindow() {
      if (!watch.isRunning) {
        return;
      }
      final int wallMs = watch.elapsedMilliseconds - checkpointMs;
      if (wallMs + 1 <= sampleInterval.inMilliseconds) {
        return;
      }
      final int next = peak(
        maxSpeed,
        windowSpeed(windowBytes, Duration(milliseconds: wallMs)),
      );
      if (next != maxSpeed) {
        maxSpeed = next;
        peaks?.send(maxSpeed);
      }
      windowBytes = 0;
      checkpointMs = watch.elapsedMilliseconds;
    }

    void onBody(int n) {
      if (!watch.isRunning) {
        watch.start();
      }
      received += n;
      windowBytes += n;
      takeWindow();
      if (total.elapsed >= timeout) {
        socket.close();
      }
    }

    void onData() {
      while (!done.isCompleted) {
        final Uint8List? chunk = socket.read(head == null ? 65536 : readSize);
        if (chunk == null || chunk.isEmpty) {
          return;
        }
        if (head != null) {
          onBody(chunk.length);
          continue;
        }
        headBuf.add(chunk);
        final Uint8List data = headBuf.takeBytes();
        final int end = indexOfHeaderEnd(data);
        if (end < 0) {
          headBuf.add(data);
          continue;
        }
        head = ascii.decode(data.sublist(0, end), allowInvalid: true);
        final int status = httpStatus(head!);
        if (status < 200 || status >= 300) {
          done.completeError(NodeSpeedTestException('测速地址返回 HTTP $status'));
          socket.close();
          return;
        }
        final int bodyStart = end + 4;
        if (bodyStart < data.length) {
          onBody(data.length - bodyStart);
        }
      }
    }

    final StreamSubscription<RawSocketEvent> sub = socket.listen(
      (RawSocketEvent event) {
        if (event == RawSocketEvent.readClosed) {
          if (!done.isCompleted) {
            done.complete();
          }
          return;
        }
        if (event != RawSocketEvent.read) {
          return;
        }
        onData();
      },
      onError: (Object error, StackTrace stack) {
        if (done.isCompleted) {
          return;
        }
        if (received >= minBytes) {
          done.complete();
          return;
        }
        done.completeError(error, stack);
      },
      onDone: () {
        if (!done.isCompleted) {
          done.complete();
        }
      },
      cancelOnError: false,
    );
    try {
      final Duration remain = timeout - total.elapsed;
      if (remain <= Duration.zero) {
        throw NodeSpeedTestException('测速超时');
      }
      await done.future.timeout(remain);
    } on TimeoutException {
      socket.close();
    } finally {
      await sub.cancel();
    }
    takeWindow();
    if (head == null) {
      throw NodeSpeedTestException('测速超时');
    }
    if (received < minBytes) {
      throw NodeSpeedTestException('测速数据不足');
    }
    if (maxSpeed <= 0) {
      maxSpeed = bytesPerSecond(received, watch.elapsed);
      if (maxSpeed > 0) {
        peaks?.send(maxSpeed);
      }
    }
    if (maxSpeed <= 0) {
      throw NodeSpeedTestException('测速失败');
    }
    return maxSpeed;
  }
}
