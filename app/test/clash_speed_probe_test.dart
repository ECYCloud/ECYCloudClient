import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ecycloud_client/domain/config/local_template.dart';
import 'package:ecycloud_client/domain/config/speed_probe_config.dart';
import 'package:ecycloud_client/domain/kernel/clash_api_client.dart';
import 'package:ecycloud_client/state/connection_controller.dart';
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

  test('节点文件加载完成前不报告就绪，也不读取分组与节点文件总表', () async {
    int loads = 0;
    final List<String> paths = <String>[];
    final ClashApiClient clash = ClashApiClient(
      options,
      httpClient: MockClient((http.Request request) async {
        paths.add(request.url.path);
        if (request.url.path == '/providers/proxies/ecy-panel-nodes') {
          loads++;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'proxies': <Object>[
                if (loads > 2)
                  <String, String>{'name': 'node-1', 'type': 'Shadowsocks'},
              ],
            }),
            200,
          );
        }
        return http.Response('{"proxies":{}}', 200);
      }),
    )..panelProviders = <String>['ecy-panel-nodes'];
    addTearDown(clash.close);
    await expectLater(clash.fetchProxies(), throwsA(isA<ClashApiException>()));
    await clash.waitReady();
    expect(loads, 3);
    expect(paths, isNot(contains('/proxies')));
    expect(paths, isNot(contains('/providers/proxies')));
    await clash.fetchProxies();
    expect(paths.last, '/proxies');
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

  test('运行配置展示不含控制密钥与测速入站口令', () {
    final Map<String, dynamic> config = <String, dynamic>{
      'secret': 'control-secret-value',
      'proxies': <Object?>[
        <String, dynamic>{
          'name': 'node-1',
          'type': 'vless',
          'server': 'node.example.test',
          'uuid': 'device-uuid-in-proxies',
        },
      ],
      'proxy-groups': <Object?>[],
      'proxy-providers': <String, dynamic>{
        'ecy-panel-nodes': <String, dynamic>{
          'type': 'file',
          'path': 'ecy-panel-nodes.json',
          'payload': <Object?>[
            <String, dynamic>{
              'name': 'node-2',
              'type': 'ss',
              'password': 'device-password-in-payload',
              'plugin-opts': <String, dynamic>{'password': 'nested-secret'},
            },
            <String, dynamic>{
              'name': 'node-3',
              'type': 'hysteria2',
              'auth': 'device-auth-in-payload',
            },
          ],
        },
      },
    };
    SpeedProbeConfig.applyTo(config, 10203, 'control-secret-value');
    final String password = SpeedProbeConfig.credential('control-secret-value')
        .split(':')
        .last;
    final String shown = ConnectionController.maskRuntimeSecrets(
      jsonEncode(config),
    );
    expect(shown, isNot(contains('control-secret-value')));
    expect(shown, isNot(contains(password)));
    for (final String credential in <String>[
      'device-uuid-in-proxies',
      'device-password-in-payload',
      'nested-secret',
      'device-auth-in-payload',
    ]) {
      expect(shown, isNot(contains(credential)));
    }
    expect(shown, contains('node.example.test'));
    expect(shown, contains('ecy-panel-nodes.json'));
    final Map<String, dynamic> parsed =
        jsonDecode(shown) as Map<String, dynamic>;
    expect(parsed['secret'], '******');
    expect(parsed['listeners'][0]['port'], SpeedProbeConfig.portOf(10203));
    expect(
      () => ConnectionController.maskRuntimeSecrets('not-json'),
      throwsFormatException,
    );
  });

  test('运行配置查看时从节点文件补回全部节点，各组不重复列出，凭据仍打码', () {
    final String group = 'ecy-panel-${'a' * 64}';
    final String raw = jsonEncode(<String, Object>{
      'proxy-providers': <String, Object>{
        'ecy-panel-nodes': <String, String>{
          'type': 'file',
          'path': 'ecy-panel-nodes.json',
        },
        group: <String, Object>{
          'type': 'file',
          'path': '$group.json',
          'payload': <Object>[
            <String, String>{'name': 'node-1', 'uuid': 'stale-group-copy'},
          ],
        },
      },
    });
    final Map<String, dynamic> shown = jsonDecode(
      ConnectionController.maskRuntimeSecrets(
        raw,
        nodes: <Object?>[
          <String, Object>{
            'name': 'node-1',
            'server': 'node.example.test',
            'uuid': 'node-credential',
            'reality-opts': <String, String>{
              'public-key': 'reality-public-key',
              'short-id': '0123abcd',
            },
          },
        ],
      ),
    ) as Map<String, dynamic>;
    final Map<String, dynamic> providers =
        shown['proxy-providers'] as Map<String, dynamic>;
    expect(
      providers['ecy-panel-nodes']['payload'][0]['server'],
      'node.example.test',
    );
    expect(providers['ecy-panel-nodes']['payload'][0]['uuid'], '******');
    expect((providers[group] as Map).containsKey('payload'), isFalse);
    expect(jsonEncode(shown), isNot(contains('node-credential')));
    expect(jsonEncode(shown), isNot(contains('reality-public-key')));
    expect(jsonEncode(shown), isNot(contains('0123abcd')));
    expect(
      providers['ecy-panel-nodes']['payload'][0]['reality-opts']['public-key'],
      '******',
    );
  });
}
