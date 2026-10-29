import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ecycloud_client/ui/widgets/icon_image.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<Object> loadFailure(
  RemoteImage image, {
  void Function(int length)? onDecode,
  Future<ui.Codec> Function(ui.ImmutableBuffer buffer)? decode,
}) {
  final Completer<Object> failure = Completer<Object>();
  final ImageStreamCompleter stream = image.loadImage(image, (
    ui.ImmutableBuffer buffer, {
    ui.TargetImageSizeCallback? getTargetSize,
  }) async {
    onDecode?.call(buffer.length);
    if (decode != null) return decode(buffer);
    buffer.dispose();
    throw StateError('已到达测试解码器');
  });
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (_, _) => failure.completeError(StateError('不应产生图片帧')),
    onError: (Object error, StackTrace? stack) {
      stream.removeListener(listener);
      failure.complete(error);
    },
  );
  stream.addListener(listener);
  return failure.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final HttpOverrides? previousHttpOverrides = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() => HttpOverrides.global = previousHttpOverrides);
  late HttpServer server;
  late String origin;
  late Future<void> Function(HttpRequest request) respond;

  setUp(() async {
    RemoteIcon.resumeSession();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';
    server.listen((HttpRequest request) async {
      try {
        await respond(request);
      } on HttpException {
        // 限额或取消触发后，客户端会关闭连接。
      } on SocketException {
        // 限额或取消触发后，客户端会关闭连接。
      }
    });
  });
  tearDown(() async {
    await RemoteIcon.clearSession();
    await server.close(force: true);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  for (final String encoding in <String>['length', 'chunked', 'gzip']) {
    test('远程图片拒绝超过 50 MiB 的 $encoding 响应', () async {
      respond = (HttpRequest request) async {
        final Uint8List chunk = Uint8List(1 << 20);
        if (encoding == 'length') request.response.contentLength = 51 << 20;
        if (encoding == 'gzip') {
          request.response.headers.set(
            HttpHeaders.contentEncodingHeader,
            'gzip',
          );
          request.response.add(gzip.encode(Uint8List(51 << 20)));
        } else {
          for (int i = 0; i < 51; i++) {
            request.response.add(chunk);
          }
        }
        await request.response.close();
      };
      int decoded = 0;
      await loadFailure(
        RemoteImage('$origin/image'),
        onDecode: (int n) => decoded = n,
      );
      expect(decoded, 0);
    });
  }

  test('50 MiB 边界内图片仍可进入解码', () async {
    respond = (HttpRequest request) async {
      request.response.contentLength = 50 << 20;
      final Uint8List chunk = Uint8List(1 << 20);
      for (int i = 0; i < 50; i++) {
        request.response.add(chunk);
      }
      await request.response.close();
    };
    int decoded = 0;
    await loadFailure(
      RemoteImage('$origin/image'),
      onDecode: (int n) => decoded = n,
    );
    expect(decoded, 50 << 20);
  });

  test('退出会取消未结束的图片响应，旧会话不能再次发起下载', () async {
    final Completer<void> started = Completer<void>();
    int requests = 0;
    respond = (HttpRequest request) async {
      requests++;
      request.response.add(<int>[1]);
      await request.response.flush();
      started.complete();
    };
    final RemoteImage old = RemoteImage('$origin/image');
    int decoded = 0;
    final Future<Object> failure = loadFailure(
      old,
      onDecode: (int n) => decoded = n,
    );
    await started.future;
    await RemoteIcon.clearSession().timeout(const Duration(seconds: 5));
    await failure;
    expect(decoded, 0);
    RemoteIcon.resumeSession();
    expect(RemoteImage('$origin/image'), isNot(old));
    await loadFailure(old, onDecode: (int n) => decoded = n);
    expect(decoded, 0);
    expect(requests, 1);
  });

  test('持续发送少量图片数据也受 30 秒总时限约束', () async {
    respond = (HttpRequest request) async {
      for (int i = 0; i < 35; i++) {
        request.response.add(<int>[1]);
        await request.response.flush();
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      await request.response.close();
    };
    int decoded = 0;
    final Stopwatch elapsed = Stopwatch()..start();
    final Object error = await loadFailure(
      RemoteImage('$origin/slow'),
      onDecode: (int n) => decoded = n,
    );
    expect(error, isA<http.RequestAbortedException>());
    expect(decoded, 0);
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 35)));
  }, timeout: const Timeout(Duration(seconds: 45)));

  test('退出等待已开始的解码结束并释放旧解码器', () async {
    respond = (HttpRequest request) async {
      request.response.add(<int>[1]);
      await request.response.close();
    };
    final Completer<void> started = Completer<void>();
    final Completer<ui.Codec> result = Completer<ui.Codec>();
    final _TrackedCodec codec = _TrackedCodec();
    final Future<Object> failure = loadFailure(
      RemoteImage('$origin/image'),
      decode: (buffer) {
        buffer.dispose();
        started.complete();
        return result.future;
      },
    );
    await started.future;
    bool cleared = false;
    final Future<void> clearing = RemoteIcon.clearSession().then(
      (_) => cleared = true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(cleared, isFalse);
    result.complete(codec);
    await clearing;
    await failure;
    expect(codec.disposed, isTrue);
  });

  for (final String target in <String>[
    'http://example.test/image',
    'file:///private/image',
    'https://user:password@example.test/image',
  ]) {
    test('HTTPS 图片拒绝不安全重定向 $target', () async {
      int requests = 0;
      final MockClient client = MockClient.streaming((request, _) async {
        requests++;
        return http.StreamedResponse(
          const Stream<List<int>>.empty(),
          302,
          isRedirect: true,
          headers: <String, String>{'location': target},
        );
      });
      int decoded = 0;
      await http.runWithClient(
        () => loadFailure(
          RemoteImage('https://example.test/start'),
          onDecode: (int n) => decoded = n,
        ),
        () => client,
      );
      expect(requests, 1);
      expect(decoded, 0);
    });
  }

  test('同协议重定向仍可加载且循环重定向次数有限', () async {
    int requests = 0;
    bool loop = false;
    final MockClient client = MockClient.streaming((request, _) async {
      requests++;
      if (loop || request.url.path == '/start') {
        return http.StreamedResponse(
          const Stream<List<int>>.empty(),
          302,
          isRedirect: true,
          headers: <String, String>{'location': '/image'},
        );
      }
      return http.StreamedResponse(
        Stream<List<int>>.value(<int>[1, 2, 3]),
        200,
      );
    });
    int decoded = 0;
    await http.runWithClient(
      () => loadFailure(
        RemoteImage('https://example.test/start'),
        onDecode: (int n) => decoded = n,
      ),
      () => client,
    );
    expect(decoded, 3);
    expect(requests, 2);
    requests = 0;
    decoded = 0;
    loop = true;
    await http.runWithClient(
      () => loadFailure(
        RemoteImage('https://example.test/start'),
        onDecode: (int n) => decoded = n,
      ),
      () => client,
    );
    expect(decoded, 0);
    expect(requests, 6);
  });

  test('正常 PNG 能生成图片帧并报告下载进度', () async {
    final ui.Image source = await createTestImage(cache: false);
    final Uint8List png = (await source.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    source.dispose();
    respond = (HttpRequest request) async {
      request.response.contentLength = png.length;
      request.response.add(png);
      await request.response.close();
    };
    final RemoteImage provider = RemoteImage('$origin/image');
    final ImageStreamCompleter stream = provider.loadImage(
      provider,
      ui.instantiateImageCodecWithSize,
    );
    final Completer<ImageInfo> image = Completer<ImageInfo>();
    int downloaded = 0;
    final ImageStreamListener listener = ImageStreamListener(
      (ImageInfo info, _) => image.complete(info),
      onChunk: (ImageChunkEvent event) =>
          downloaded = event.cumulativeBytesLoaded,
      onError: (Object error, StackTrace? stack) =>
          image.completeError(error, stack),
    );
    stream.addListener(listener);
    final ImageInfo info = await image.future;
    expect(info.image.width, 1);
    expect(downloaded, png.length);
    stream.removeListener(listener);
    info.dispose();
  });
}

class _TrackedCodec implements ui.Codec {
  bool disposed = false;
  @override
  void dispose() => disposed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
