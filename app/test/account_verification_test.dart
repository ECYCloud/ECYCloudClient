import 'dart:convert';
import 'dart:io';

import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('修改邮箱和注销不携带密码，邮箱验证码按原流程提交', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];
    server.listen((HttpRequest request) async {
      requests.add(
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>,
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"ret":1,"msg":"成功","data":{"enable":-1}}');
      await request.response.close();
    });
    final String origin = 'http://127.0.0.1:${server.port}';
    final PanelApiClient api = PanelApiClient(
      baseUrl: origin,
      configBaseUrl: origin,
      device: const DeviceInfo(
        platform: 'windows',
        deviceId: 'test',
        deviceName: 'test',
        deviceModel: 'test',
        osVersion: 'test',
        appVersion: '0.0.0',
      ),
    );
    try {
      await api.sendNewEmailVerify(
        email: 'new@example.test',
        oldEmailcode: '123456',
      );
      await api.updateEmail(
        newemail: 'new@example.test',
        oldEmailcode: '123456',
        newEmailcode: '654321',
      );
      expect(requests[0]['old_emailcode'], '123456');
      expect(requests[1].containsKey('passwd'), isFalse);
      expect(requests[1]['old_emailcode'], '123456');
      expect(requests[1]['new_emailcode'], '654321');
      await api.updateEmail(newemail: 'new@example.test');
      expect(requests[2], <String, dynamic>{'newemail': 'new@example.test'});
      await api.killAccount(emailCode: '123456');
      expect(requests[3], <String, dynamic>{'email_code': '123456'});
      await api.killAccount();
      expect(requests[4], isEmpty);
    } finally {
      api.close();
      await server.close(force: true);
    }
  });
}
