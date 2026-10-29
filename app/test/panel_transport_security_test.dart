import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ecycloud_client/data/api/api_exception.dart';
import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late PanelApiClient api;
  late Future<void> Function(HttpRequest) respond;
  Future<void> Function(HttpRequest)? readRequest;
  setUp(() async {
    readRequest = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        if (readRequest case final read?) {
          await read(request);
        } else {
          await request.drain<void>();
        }
        await respond(request);
      } on HttpException {
        // 超限或超时后客户端会主动关闭测试连接。
      } on SocketException {
        // 超限或超时后客户端会主动关闭测试连接。
      }
    });
    final String origin = 'http://127.0.0.1:${server.port}';
    api = PanelApiClient(
      baseUrl: origin,
      configBaseUrl: origin,
      device: const DeviceInfo(
        platform: 'windows',
        deviceId: 'audit',
        deviceName: 'audit',
        deviceModel: 'audit',
        osVersion: 'audit',
        appVersion: '0.0.0',
      ),
    );
  });
  tearDown(() async {
    api.close();
    await server.close(force: true);
  });

  test('隐私政策复用条款响应格式并可在登录前读取', () async {
    final List<String> paths = <String>[];
    respond = (request) async {
      paths.add(request.uri.path);
      expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
      request.response.write('{"ret":1,"data":{"content":"<p>fixture</p>"}}');
      await request.response.close();
    };
    expect(await api.fetchTos(), '<p>fixture</p>');
    expect(await api.fetchPrivacyPolicy(), '<p>fixture</p>');
    expect(paths, <String>[
      '/api/client/v1/auth/tos',
      '/api/client/v1/auth/privacy',
    ]);
  });

  for (final int status in <int>[301, 302, 303, 307, 308]) {
    test('面板不能把带凭据请求重定向到其他入口：$status', () async {
      int redirected = 0;
      api.token = 'test-bearer-do-not-forward';
      final HttpServer target = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => target.close(force: true));
      target.listen((request) async {
        redirected++;
        request.response.write('{"ret":1,"data":{"content":"unexpected"}}');
        await request.response.close();
      });
      respond = (request) async {
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer test-bearer-do-not-forward',
        );
        request.response.statusCode = status;
        request.response.headers.set(
          'location',
          'http://127.0.0.1:${target.port}/redirected',
        );
        await request.response.close();
      };
      await expectLater(api.fetchTos(), throwsA(isA<ApiException>()));
      expect(redirected, 0);
    });
  }

  for (final int status in <int>[302, 401, 403, 500]) {
    test('不能把 HTTP $status 中的 ret=1 当作成功', () async {
      respond = (request) async {
        request.response.statusCode = status;
        request.response.write('{"ret":1,"data":{"content":"unexpected"}}');
        await request.response.close();
      };
      await expectLater(api.fetchTos(), throwsA(isA<ApiException>()));
    });
  }

  test('HTTP 错误仍保留两步验证与限流语义', () async {
    respond = (request) async {
      request.response.statusCode = 401;
      request.response.write('{"ret":2,"msg":"请输入两步验证码"}');
      await request.response.close();
    };
    await expectLater(
      api.fetchTos(),
      throwsA(
        isA<ApiException>()
            .having((e) => e.needsTwoFactor, 'needsTwoFactor', isTrue)
            .having((e) => e.unauthorized, 'unauthorized', isFalse),
      ),
    );
    respond = (request) async {
      request.response.statusCode = 429;
      request.response.headers.set('retry-after', '60');
      request.response.write('{"ret":0,"msg":"请求过于频繁"}');
      await request.response.close();
    };
    await expectLater(
      api.fetchTos(),
      throwsA(
        isA<ApiException>()
            .having((e) => e.rateLimited, 'rateLimited', isTrue)
            .having((e) => e.retryAfterSeconds, 'retryAfterSeconds', 60),
      ),
    );
  });

  test('登录发码失败时原样显示服务端文案', () async {
    const String message = '请求参数格式错误';
    respond = (request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'ret': 0, 'msg': message}));
      await request.response.close();
    };
    await expectLater(
      api.sendLoginVerify(email: 'test@example.test'),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', message)),
    );
  });

  test('注册冲突只显示统一拒绝文案', () async {
    const String message = '无法使用该邮箱注册，请更换邮箱或使用找回密码。';
    respond = (request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'ret': 0, 'msg': message}));
      await request.response.close();
    };
    await expectLater(
      api.sendRegisterVerify(email: 'o_w.n-er@example.test'),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', message)),
    );
  });

  test('登录发码成功响应仍可完成请求', () async {
    respond = (request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'ret': 1,
          'msg': '如果该邮箱存在，验证码将发送到该邮箱，请注意查收。',
        }),
      );
      await request.response.close();
    };
    await api.sendLoginVerify(email: 'test@example.test');
  });

  for (final String encoding in <String>['length', 'chunked', 'gzip']) {
    test('面板拒绝超过 8 MiB 的 $encoding 响应', () async {
      final List<int> body = utf8.encode(
        jsonEncode(<String, dynamic>{
          'ret': 1,
          'data': <String, String>{'content': 'x' * (8 * 1024 * 1024)},
        }),
      );
      respond = (request) async {
        final HttpResponse response = request.response;
        if (encoding == 'length') response.contentLength = body.length;
        if (encoding == 'gzip') {
          response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
          response.add(gzip.encode(body));
        } else {
          response.add(body);
        }
        await response.close();
      };
      await expectLater(
        api.fetchTos().then((_) {}),
        throwsA(isA<ApiException>()),
      );
    });
  }

  test('边界内响应保持内容且连接可再次使用', () async {
    final String content = 'x' * (8 * 1024 * 1024 - 31);
    final List<int> body = utf8.encode(
      jsonEncode(<String, dynamic>{
        'ret': 1,
        'data': <String, String>{'content': content},
      }),
    );
    expect(body.length, 8 * 1024 * 1024);
    respond = (request) async {
      request.response.add(body);
      await request.response.close();
    };
    expect(await api.fetchTos(), content);
    respond = (request) async {
      request.response.write('{"ret":1,"data":{"content":"正常响应"}}');
      await request.response.close();
    };
    expect(await api.fetchTos(), '正常响应');
  });

  test('连不上面板自动重试 3 次后提示重开软件', () async {
    await server.close(force: true);
    await expectLater(
      api.fetchTos(),
      throwsA(
        isA<ApiException>().having(
          (ApiException e) => e.message,
          'message',
          contains('已自动重试 3 次仍连不上，请关闭软件后重新打开'),
        ),
      ),
    );
  });

  // 启动时 auth.restore() 第一件事就是查账户状态，界面在它返回前停在启动图上。
  // 这一条必须明显快于上面那条重试路径，否则连不上面板时开机就是长时间白屏
  test('账户状态查询不重试，用时与单次请求相当', () async {
    await server.close(force: true);

    final Stopwatch retried = Stopwatch()..start();
    await expectLater(api.fetchTos(), throwsA(isA<ApiException>()));
    retried.stop();

    final Stopwatch once = Stopwatch()..start();
    await expectLater(api.fetchAccountStatus(), throwsA(isA<ApiException>()));
    once.stop();

    expect(
      once.elapsedMilliseconds * 2,
      lessThan(retried.elapsedMilliseconds),
      reason:
          '单次 ${once.elapsedMilliseconds}ms 应远快于重试三次的 ${retried.elapsedMilliseconds}ms',
    );
  });

  test('拿到 HTTP 响应的失败不重试也不加重开提示', () async {
    int calls = 0;
    respond = (request) async {
      calls++;
      request.response.statusCode = 500;
      request.response.write('{"ret":0,"msg":"面板内部错误"}');
      await request.response.close();
    };
    await expectLater(
      api.fetchTos(),
      throwsA(
        isA<ApiException>().having(
          (ApiException e) => e.message,
          'message',
          '面板内部错误',
        ),
      ),
    );
    expect(calls, 1);
  });

  test('持续发送响应体也必须在总时限后结束', () async {
    final Completer<void> stopped = Completer<void>();
    respond = (request) async {
      final Socket socket = await request.response.detachSocket(
        writeHeaders: false,
      );
      addTearDown(socket.destroy);
      socket.listen((_) {}, onDone: () => stopped.complete());
      socket.write('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n');
      for (int i = 0; i < 125 && !stopped.isCompleted; i++) {
        socket.write('1\r\n \r\n');
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      socket.destroy();
    };
    await expectLater(api.fetchTos(), throwsA(isA<ApiException>()));
    await stopped.future.timeout(const Duration(seconds: 2));
  });

  test('附件直传按流读取文件并保留原始正文和令牌', () async {
    final File file = _StreamOnlyFile();
    final IOOverrides previous = IOOverrides.current!;
    var uploads = 0;
    readRequest = (request) async {
      if (request.uri.path != '/direct-upload') {
        await request.drain<void>();
        return;
      }
      uploads++;
      expect(request.headers.contentType?.mimeType, 'application/octet-stream');
      expect(request.headers.value('X-Files-Token'), 'upload-test-token');
      expect(request.headers.value('Authorization'), isNull);
      expect(request.contentLength, 6);
      final List<int> body = await request.fold<List<int>>(
        <int>[],
        (bytes, chunk) => bytes..addAll(chunk),
      );
      expect(body, <int>[0, 1, 2, 3, 254, 255]);
    };
    respond = (request) async {
      request.response.write(
        request.uri.path == '/direct-upload'
            ? '{"ret":1}'
            : jsonEncode(<String, dynamic>{
                'ret': 1,
                'data': <String, dynamic>{
                  'direct': 1,
                  'upload_url': 'http://127.0.0.1:${server.port}/direct-upload',
                  'token': 'upload-test-token',
                  'url': 'https://files.example.test/video',
                },
              }),
      );
      await request.response.close();
    };
    final TicketUploadResult result = await IOOverrides.runZoned(
      () => api.uploadTicketAttachment('stream-only.bin'),
      createFile: (path) =>
          path == 'stream-only.bin' ? file : previous.createFile(path),
    );
    expect(result.url, 'https://files.example.test/video');
    expect(uploads, 1);
  });

  for (final bool oversized in <bool>[false, true]) {
    test('附件上传响应大小限制 $oversized', () async {
      final Directory base = await Directory('build/security-transport')
          .create(recursive: true);
      final Directory directory = await base.createTemp('upload-');
      addTearDown(() => directory.delete(recursive: true));
      final File file = await File('${directory.path}/test.txt')
          .writeAsString('audit');
      var step = 0;
      respond = (request) async {
        if (step == 0) {
          step++;
          expect(request.headers.contentType?.mimeType, 'application/json');
          request.response.write(
            jsonEncode(<String, dynamic>{
              'ret': 1,
              'data': <String, int>{'direct': 0},
            }),
          );
          await request.response.close();
          return;
        }
        expect(request.headers.contentType?.mimeType, 'multipart/form-data');
        expect(request.headers.contentType?.parameters['boundary'], isNotEmpty);
        request.response.write(
          jsonEncode(<String, dynamic>{
            'ret': 1,
            'data': <String, String>{
              'url': oversized
                  ? 'x' * (8 * 1024 * 1024)
                  : 'https://files.example.test/a',
              'originalName': 'test.txt',
              'kind': 'file',
            },
          }),
        );
        await request.response.close();
      };
      final Future<TicketUploadResult> result = api.uploadTicketAttachment(
        file.path,
      );
      if (oversized) {
        await expectLater(result.then((_) {}), throwsA(isA<ApiException>()));
      } else {
        expect((await result).url, 'https://files.example.test/a');
      }
    });
  }
}

class _StreamOnlyFile implements File {
  @override
  Future<int> length() async => 6;

  @override
  Stream<List<int>> openRead([int? start, int? end]) async* {
    yield <int>[0, 1, 2];
    yield <int>[3, 254, 255];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('附件只能按流读取：${invocation.memberName}');
}
