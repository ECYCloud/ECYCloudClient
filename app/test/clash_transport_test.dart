import 'dart:async';
import 'dart:io';

import 'package:ecycloud_client/domain/config/local_template.dart';
import 'package:ecycloud_client/domain/kernel/clash_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final bool headersSent in <bool>[false, true]) {
    test('内核请求超时会断开连接：已返回响应头 $headersSent', () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      final ClashApiClient api = ClashApiClient(
        ClashApiOptions(port: server.port, secret: 'test'),
      );
      addTearDown(api.close);
      final Completer<void> disconnected = Completer<void>();
      server.listen((HttpRequest request) async {
        await request.drain<void>();
        expect(request.headers.value('Authorization'), 'Bearer test');
        final Socket socket = await request.response.detachSocket(
          writeHeaders: false,
        );
        addTearDown(socket.destroy);
        socket.listen((_) {}, onDone: disconnected.complete);
        if (headersSent) {
          socket.write('HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n{');
          await socket.flush();
        }
      });

      await expectLater(
        api.setTunEnabled(true, timeout: const Duration(milliseconds: 300)),
        throwsA(isA<Exception>()),
      );
      await disconnected.future.timeout(const Duration(seconds: 2));
    });
  }
}
