import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ecycloud_client/platform/unix/helper_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _Helper {
  _Helper(this._server, this._session) {
    _server.listen((Socket socket) => unawaited(_serve(socket)));
  }

  static Future<_Helper> start(
    Future<void> Function(Socket socket, Stream<String> lines) session,
  ) async {
    final Directory dir = Directory.systemTemp.createTempSync('helper-');
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress('${dir.path}/h.sock', type: InternetAddressType.unix),
      0,
    );
    addTearDown(() async {
      await server.close();
      dir.deleteSync(recursive: true);
    });
    return _Helper(server, session);
  }

  final ServerSocket _server;
  final Future<void> Function(Socket socket, Stream<String> lines) _session;
  final List<int> early = <int>[];

  String get path => _server.address.address;

  Future<void> _serve(Socket socket) async {
    final StreamController<String> lines = StreamController<String>();
    bool greeted = false;
    socket
        .map((List<int> chunk) {
          if (!greeted) {
            early.addAll(chunk);
          }
          return chunk;
        })
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(lines.add, onDone: lines.close, onError: (Object _) {});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    greeted = true;
    try {
      await _session(socket, lines.stream);
    } finally {
      socket.destroy();
    }
  }
}

void main() {
  final bool unsupported = Platform.isWindows;

  test('先读到握手再发出带随机数的请求', () async {
    Map<String, dynamic>? received;
    final _Helper helper = await _Helper.start((socket, lines) async {
      socket.write(
        '${jsonEncode(<String, Object>{
          'ok': false,
          'error': '后台服务已更新，请重新打开客户端',
          'data': <String, String>{'nonce': 'n-1'},
        })}\n',
      );
      received = jsonDecode(await lines.first) as Map<String, dynamic>;
      socket.write('{"ok":true,"data":{"version":"1"}}\n');
      await socket.flush();
    });
    final Map<String, dynamic> data = await HelperClient(
      helper.path,
      'missing',
    ).request('kernel.status', <String, dynamic>{'log_cursor': 3});
    expect(data, <String, dynamic>{'version': '1'});
    expect(helper.early, isEmpty, reason: '收到握手前不能预写请求');
    expect(received, containsPair('command', 'kernel.status'));
    expect(received, containsPair('log_cursor', 3));
    expect(received, containsPair('nonce', 'n-1'));
  }, skip: unsupported);

  test('握手前被拒绝时不发请求并给出原因', () async {
    final _Helper helper = await _Helper.start((socket, lines) async {
      socket.write('{"ok":false,"error":"拒绝来自非官方客户端的指令: x"}\n');
      await socket.flush();
    });
    await expectLater(
      HelperClient(helper.path, 'missing').request('ping'),
      throwsA(
        isA<HelperException>().having(
          (HelperException e) => e.message,
          'message',
          '拒绝来自非官方客户端的指令: x',
        ),
      ),
    );
    expect(helper.early, isEmpty);
  }, skip: unsupported);

  test('helper 不发握手时提示响应超时且不预写请求', () async {
    final _Helper helper = await _Helper.start((socket, lines) async {
      await lines.drain<void>();
    });
    await expectLater(
      HelperClient(helper.path, 'missing').request('ping'),
      throwsA(
        isA<HelperException>().having(
          (HelperException e) => e.message,
          'message',
          '后台服务响应超时',
        ),
      ),
    );
    expect(helper.early, isEmpty);
  }, skip: unsupported);

  test('首行 ok:false 且不带随机数与原因时提示后台服务版本过旧', () async {
    final _Helper helper = await _Helper.start((socket, lines) async {
      socket.write('{"ok":false}\n');
      await socket.flush();
      await lines.drain<void>();
    });
    await expectLater(
      HelperClient(helper.path, 'missing').request('ping'),
      throwsA(
        isA<HelperException>().having(
          (HelperException e) => e.message,
          'message',
          '后台服务版本过旧，请重新运行安装包',
        ),
      ),
    );
    expect(helper.early, isEmpty);
  }, skip: unsupported);
}
