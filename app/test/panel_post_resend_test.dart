import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ecycloud_client/data/api/api_exception.dart';
import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

// 只有 SocketException 才算「没连上」而允许重发；服务端读完请求后连接被重置或关闭，
// 对客户端必须表现为普通传输失败，否则下单、提现这类请求会被执行两次
void main() {
  for (final bool reset in <bool>[true, false]) {
    test('服务端读完非幂等请求后断开不重发：${reset ? 'RST' : 'FIN'}', () async {
      final ServerSocket server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(server.close);
      int received = 0;
      server.listen((Socket socket) {
        final BytesBuilder buffer = BytesBuilder();
        late final StreamSubscription<List<int>> subscription;
        subscription = socket.listen((List<int> chunk) {
          buffer.add(chunk);
          final String text = latin1.decode(buffer.toBytes());
          final int end = text.indexOf('\r\n\r\n');
          final RegExpMatch? length = RegExp(
            r'content-length:\s*(\d+)',
            caseSensitive: false,
          ).firstMatch(end < 0 ? '' : text.substring(0, end));
          if (end < 0 ||
              text.length < end + 4 + int.parse(length?.group(1) ?? '0')) {
            return;
          }
          received++;
          subscription.pause();
          if (reset) {
            final ByteData linger = ByteData(8)..setInt32(0, 1, Endian.host);
            socket.setRawOption(
              RawSocketOption(
                RawSocketOption.levelSocket,
                Platform.isLinux ? 13 : 0x0080,
                linger.buffer.asUint8List(),
              ),
            );
          }
          socket.destroy();
        });
      });
      final String origin = 'http://127.0.0.1:${server.port}';
      final PanelApiClient api = PanelApiClient(
        baseUrl: origin,
        configBaseUrl: origin,
        device: const DeviceInfo(
          platform: 'windows',
          deviceId: 'fixture',
          deviceName: 'fixture',
          deviceModel: 'Windows 11',
          osVersion: '26H2',
          appVersion: '0.1.1',
        ),
      )..token = 'fixture-token';
      addTearDown(api.close);

      await expectLater(
        api.buyPlan(
          shop: 1,
          coupon: '',
          autoRenew: false,
          disableOthers: false,
        ),
        throwsA(
          isA<ApiException>().having(
            (ApiException e) => e.connectFailed,
            'connectFailed',
            isFalse,
          ),
        ),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(received, 1);
    });
  }
}
