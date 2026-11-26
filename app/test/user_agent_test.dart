import 'dart:io';

import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS 的 UA 标明 Flutter 实现，其余平台保持原样', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final List<String?> agents = <String?>[];
    server.listen((HttpRequest request) async {
      agents.add(request.headers.value(HttpHeaders.userAgentHeader));
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"ret":1,"data":{"content":""}}');
      await request.response.close();
    });
    final String origin = 'http://127.0.0.1:${server.port}';
    try {
      for (final String platform in <String>['macos', 'windows', 'android']) {
        await PanelApiClient(
          baseUrl: origin,
          configBaseUrl: origin,
          device: DeviceInfo(
            platform: platform,
            deviceId: 'test',
            deviceName: 'test',
            deviceModel: 'test',
            osVersion: 'test',
            appVersion: '0.1.12',
          ),
        ).fetchTos();
      }
      expect(agents, <String>[
        'ECYCloud/0.1.12 (macOS; Flutter)',
        'ECYCloud/0.1.12 (Windows)',
        'ECYCloud/0.1.12 (Android)',
      ]);
    } finally {
      await server.close(force: true);
    }
  });
}
