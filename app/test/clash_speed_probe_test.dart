import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ecycloud_client/domain/config/local_template.dart';
import 'package:ecycloud_client/domain/config/speed_probe_config.dart';
import 'package:ecycloud_client/domain/kernel/clash_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const ClashApiOptions options = ClashApiOptions(port: 19090, secret: 'test');

  test('普通连接仅等待控制接口，不触发测速入口探测', () async {
    final ClashApiClient clash = ClashApiClient(
      options,
      httpClient: MockClient((http.Request request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/version');
        return http.Response('{"version":"test"}', 200);
      }),
    );
    addTearDown(clash.close);
    await clash.waitReady();
  });

  test('控制接口已启动但转发未就绪时继续等待，探测不携带控制密钥', () async {
    final HttpServer proxy = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => proxy.close(force: true));
    final Completer<void> attempted = Completer<void>();
    bool forwarding = false;
    bool ready = false;
    int selected = 0;
    proxy.listen((HttpRequest request) async {
      expect(request.uri, options.baseUri.resolve('/version'));
      expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
      expect(
        request.headers.value(HttpHeaders.proxyAuthorizationHeader),
        'Basic ${base64Encode(utf8.encode(SpeedProbeConfig.credential(options.secret)))}',
      );
      request.response.statusCode = forwarding
          ? HttpStatus.unauthorized
          : HttpStatus.badGateway;
      await request.response.close();
      if (!attempted.isCompleted) attempted.complete();
    });
    final ClashApiClient clash = ClashApiClient(
      options,
      httpClient: MockClient((http.Request request) async {
        expect(request.headers['Authorization'], 'Bearer test');
        if (request.method == 'PUT') {
          expect(request.url.path, '/proxies/${SpeedProbeConfig.groupName}');
          expect(jsonDecode(request.body), <String, String>{'name': 'DIRECT'});
          selected++;
          return http.Response('', 204);
        }
        expect(request.url.path, '/version');
        return http.Response('{"version":"test"}', 200);
      }),
    );
    addTearDown(clash.close);
    final Future<void> pending = clash
        .waitReady(proxyPort: proxy.port)
        .then((_) => ready = true);
    await Future.any(<Future<void>>[attempted.future, pending]);
    expect(ready, isFalse);
    forwarding = true;
    await pending;
    expect(ready, isTrue);
    expect(selected, greaterThanOrEqualTo(2));
  });

  test('控制接口可用但转发持续失败时按启动时限结束', () async {
    final HttpServer proxy = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => proxy.close(force: true));
    proxy.listen((HttpRequest request) async {
      request.response.statusCode = HttpStatus.badGateway;
      await request.response.close();
    });
    final ClashApiClient clash = ClashApiClient(
      options,
      httpClient: MockClient(
        (http.Request request) async =>
            http.Response('', request.method == 'PUT' ? 204 : 200),
      ),
    );
    addTearDown(clash.close);
    await expectLater(
      clash.waitReady(
        proxyPort: proxy.port,
        timeout: const Duration(milliseconds: 300),
      ),
      throwsA(
        isA<ClashApiException>().having(
          (ClashApiException e) => e.message,
          'message',
          contains('转发'),
        ),
      ),
    );
  });

  test('启动被取消后，迟到的转发响应不能报告就绪', () async {
    final HttpServer proxy = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => proxy.close(force: true));
    bool cancelled = false;
    proxy.listen((HttpRequest request) async {
      cancelled = true;
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
    });
    final ClashApiClient clash = ClashApiClient(
      options,
      httpClient: MockClient(
        (http.Request request) async =>
            http.Response('', request.method == 'PUT' ? 204 : 200),
      ),
    );
    addTearDown(clash.close);
    await expectLater(
      clash.waitReady(proxyPort: proxy.port, isCancelled: () => cancelled),
      throwsA(
        isA<ClashApiException>().having(
          (ClashApiException e) => e.message,
          'message',
          '连接已取消',
        ),
      ),
    );
  });

  test('内部测速组不会进入普通分组与 GLOBAL 成员', () async {
    final ClashApiClient clash = ClashApiClient(
      options,
      httpClient: MockClient((http.Request request) async {
        expect(request.url.path, '/proxies');
        return http.Response(
          jsonEncode(<String, dynamic>{
            'proxies': <String, dynamic>{
              'GLOBAL': <String, dynamic>{
                'type': 'Selector',
                'now': '主节点',
                'all': <String>[
                  'DIRECT',
                  '主节点',
                  SpeedProbeConfig.groupName,
                  'node-12',
                ],
              },
              '主节点': <String, dynamic>{
                'type': 'Selector',
                'now': 'node-12',
                'all': <String>['node-12', 'DIRECT'],
              },
              SpeedProbeConfig.groupName: <String, dynamic>{
                'type': 'Selector',
                'now': 'node-12',
                'all': <String>['node-12'],
              },
              'node-12': <String, dynamic>{'type': 'Trojan'},
            },
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(clash.close);

    final (List<ProxyGroup> groups, List<ProxyNode> nodes) = await clash
        .fetchProxies();

    expect(groups.map((ProxyGroup group) => group.name), <String>[
      'GLOBAL',
      '主节点',
    ]);
    expect(groups.first.members, <String>['DIRECT', '主节点', 'node-12']);
    expect(groups.first.now, '主节点');
    expect(groups.last.members, <String>['node-12', 'DIRECT']);
    expect(groups.last.now, 'node-12');
    expect(nodes.single.name, 'node-12');
  });

  test('切换测速节点只更新内部组并仅清理测速连接', () async {
    final List<String> requests = <String>[];
    final ClashApiClient clash = ClashApiClient(
      options,
      httpClient: MockClient((http.Request request) async {
        requests.add('${request.method} ${request.url.path}');
        switch (request.url.path) {
          case '/proxies/${SpeedProbeConfig.groupName}':
            expect(request.method, 'PUT');
            expect(jsonDecode(request.body), <String, String>{
              'name': 'node-12',
            });
            return http.Response('', 204);
          case '/connections':
            return http.Response(
              jsonEncode(<String, dynamic>{
                'connections': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'business',
                    'chains': <String>['node-12', '主节点'],
                  },
                  <String, dynamic>{
                    'id': 'probe',
                    'chains': <String>['node-12', SpeedProbeConfig.groupName],
                  },
                ],
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          case '/connections/probe':
            expect(request.method, 'DELETE');
            return http.Response('', 204);
          default:
            fail('测速不得请求 ${request.method} ${request.url.path}');
        }
      }),
    );
    addTearDown(clash.close);

    await clash.selectProxy(SpeedProbeConfig.groupName, 'node-12');
    await clash.closeConnectionsVia(<String>{SpeedProbeConfig.groupName});

    expect(requests, <String>[
      'PUT /proxies/${SpeedProbeConfig.groupName}',
      'GET /connections',
      'DELETE /connections/probe',
    ]);
  });
}
