import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ecycloud_client/data/api/api_exception.dart';
import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:ecycloud_client/data/store/json_file_store.dart';
import 'package:ecycloud_client/data/store/panel_response_cache.dart';
import 'package:ecycloud_client/domain/config/node_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final String hk = 'ecy-panel-${'a' * 64}';
  final String vip = 'ecy-panel-${'b' * 64}';
  final String empty = 'ecy-panel-${'c' * 64}';
  final String fixed = 'ecy-panel-${'d' * 64}';
  Map<String, Object> node(String name) => <String, Object>{
    'name': name,
    'type': 'trojan',
    'server': '$name.example.test',
    'port': 443,
  };
  Map<String, Object> file(String name, List<Object> payload) =>
      <String, Object>{
        'type': 'file',
        'path': '$name.json',
        'payload': payload,
      };
  CatalogNode entry(String name, int rank, List<String> keys) => CatalogNode(
    name: name,
    rank: rank,
    label: '显示名 $name',
    providers: keys,
    proxy: node(name),
  );
  List<String> names(Map<String, dynamic> config, String provider) => <String>[
    for (final Object? item
        in ((config['proxy-providers'] as Map)[provider] as Map)['payload']
            as List)
      (item as Map)['name'] as String,
  ];

  // 序号：node-10=10、node-20=20、node-40=40；模板里写死的节点没有序号
  final NodeCatalog catalog = NodeCatalog(
    stamp: 's1',
    providers: <String, CatalogProvider>{
      'ecy-panel-nodes': (key: 'ecy-panel-nodes', total: 900, head: 2),
      hk: (key: hk, total: 300, head: 1),
      // 与 hk 同条件、因固定成员不同而另建的节点文件：共用 hk 的键
      vip: (key: hk, total: 300, head: 1),
      empty: (key: empty, total: 5, head: 0),
    },
    ranks: const <String, int>{'node-10': 10, 'node-20': 20, 'node-40': 40},
  );
  Map<String, dynamic> config() => jsonDecode(
    jsonEncode(<String, Object>{
      'proxy-providers': <String, Object>{
        'ecy-panel-nodes': file('ecy-panel-nodes', <Object>[
          node('node-10'),
          node('node-20'),
          node('node-40'),
          node('模板节点'),
        ]),
        hk: file(hk, <Object>[node('node-20')]),
        vip: file(vip, <Object>[
          node('模板节点'),
          node('node-20'),
          node('node-40'),
          node('尾部模板节点'),
        ]),
        empty: file(empty, <Object>[
          <String, String>{'name': 'ecy-panel-empty', 'type': 'reject'},
        ]),
        fixed: file(fixed, <Object>[node('模板节点')]),
        'remote': <String, Object>{'type': 'http', 'url': 'https://x'},
      },
      'proxy-groups': <Object>[],
      'rules': <String>['MATCH,DIRECT'],
    }),
  ) as Map<String, dynamic>;

  test('并入的节点按序号插在带序号成员之间，写死的节点位置不动', () {
    final ({Map<String, dynamic> config, NodeCatalog catalog}) merged = catalog
        .merge(config(), <CatalogNode>[
          entry('node-50', 50, <String>['ecy-panel-nodes', hk]),
          entry('node-5', 5, <String>['ecy-panel-nodes', hk]),
          entry('node-30', 30, <String>['ecy-panel-nodes']),
        ]);
    expect(names(merged.config, 'ecy-panel-nodes'), <String>[
      'node-5',
      'node-10',
      'node-20',
      'node-30',
      'node-40',
      'node-50',
      '模板节点',
    ]);
    expect(names(merged.config, hk), <String>['node-5', 'node-20', 'node-50']);
    expect(names(merged.config, vip), <String>[
      '模板节点',
      'node-5',
      'node-20',
      'node-40',
      'node-50',
      '尾部模板节点',
    ]);
    expect(merged.catalog.ranks, <String, int>{
      'node-10': 10,
      'node-20': 20,
      'node-40': 40,
      'node-5': 5,
      'node-30': 30,
      'node-50': 50,
    });
    expect(merged.catalog.stamp, 's1');
  });

  test('只写进键在节点 providers 里的节点文件，其余节点文件原样保留', () {
    final Map<String, dynamic> before = config();
    final ({Map<String, dynamic> config, NodeCatalog catalog}) merged = catalog
        .merge(before, <CatalogNode>[
          entry('node-30', 30, <String>['ecy-panel-nodes']),
        ]);
    final Map<dynamic, dynamic> files = merged.config['proxy-providers'] as Map;
    for (final String untouched in <String>[hk, vip, empty, fixed, 'remote']) {
      expect(
        identical(
          files[untouched],
          (before['proxy-providers'] as Map)[untouched],
        ),
        isTrue,
        reason: untouched,
      );
    }
    expect(names(merged.config, 'ecy-panel-nodes'), contains('node-30'));
  });

  test('占位节点在并入真实节点后去掉，没有带序号成员的列表放末尾', () {
    final ({Map<String, dynamic> config, NodeCatalog catalog}) merged = catalog
        .merge(config(), <CatalogNode>[
          entry('node-70', 70, <String>['ecy-panel-nodes', empty]),
          entry('node-60', 60, <String>['ecy-panel-nodes', empty]),
        ]);
    expect(names(merged.config, empty), <String>['node-60', 'node-70']);
  });

  test('已在节点文件里的节点不重复并入，各节点文件各持一份副本', () {
    final ({Map<String, dynamic> config, NodeCatalog catalog}) merged = catalog
        .merge(config(), <CatalogNode>[
          entry('node-20', 20, <String>['ecy-panel-nodes', hk]),
          entry('node-30', 30, <String>['ecy-panel-nodes', hk]),
        ]);
    expect(names(merged.config, hk), <String>['node-20', 'node-30']);
    final Map<dynamic, dynamic> files = merged.config['proxy-providers'] as Map;
    final Object? first = ((files['ecy-panel-nodes'] as Map)['payload'] as List)
        .firstWhere((Object? item) => (item as Map)['name'] == 'node-30');
    final Object? second = ((files[hk] as Map)['payload'] as List).firstWhere(
      (Object? item) => (item as Map)['name'] == 'node-30',
    );
    expect(first, second);
    expect(identical(first, second), isFalse);
    expect(catalog.merge(config(), const <CatalogNode>[]).catalog, catalog);
  });

  test('目录与节点条目只接受完整的字段', () {
    final NodeCatalog? parsed = NodeCatalog.fromJson(
      jsonDecode(jsonEncode(catalog.toJson())),
    );
    expect(parsed!.stamp, 's1');
    expect(parsed.providers[vip], (key: hk, total: 300, head: 1));
    expect(parsed.ranks, catalog.ranks);
    expect(NodeCatalog.fromJson(null), isNull);
    expect(NodeCatalog.fromJson(<String, Object>{'providers': 1}), isNull);
    expect(
      NodeCatalog.fromJson(<String, Object>{
        'stamp': 's',
        'providers': <String, Object>{
          'a': <String, Object>{'key': 'a', 'total': '9', 'head': 0},
        },
      })!.providers,
      isEmpty,
    );

    final Map<String, Object> valid = <String, Object>{
      'name': 'node-1',
      'rank': 3,
      'label': '香港 01',
      'providers': <String>['ecy-panel-nodes'],
      'proxy': node('node-1'),
    };
    expect(CatalogNode.fromJson(valid)!.label, '香港 01');
    for (final MapEntry<String, Object> broken in <String, Object>{
      'name': 1,
      'rank': '3',
      'label': 1,
      'providers': 'ecy-panel-nodes',
      'proxy': node('node-2'),
    }.entries) {
      expect(
        CatalogNode.fromJson(<String, Object>{
          ...valid,
          broken.key: broken.value,
        }),
        isNull,
        reason: broken.key,
      );
    }
  });

  group('面板接口', () {
    late HttpServer server;
    late PanelApiClient api;
    final List<(String, Map<String, String?>, Object?)> requests =
        <(String, Map<String, String?>, Object?)>[];
    Object? nodesReply;

    setUp(() async {
      requests.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        final String body = await utf8.decoder.bind(request).join();
        requests.add((
          '${request.method} ${request.uri.path}',
          <String, String?>{
            'catalog': request.headers.value('X-ECY-Node-Catalog'),
            'providers': request.headers.value('X-ECY-Node-Providers'),
            'members': request.headers.value('X-ECY-Node-Members'),
            'type': request.headers.contentType?.mimeType,
          },
          body.isEmpty ? null : jsonDecode(body),
        ));
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path.endsWith('/config/nodes')) {
          if (nodesReply == null) {
            request.response.statusCode = 400;
          }
          request.response.write(
            jsonEncode(
              nodesReply == null
                  ? <String, Object>{'ret': 0, 'msg': '参数无效'}
                  : <String, Object?>{'ret': 1, 'data': nodesReply},
            ),
          );
        } else {
          request.response.write(
            jsonEncode(<String, Object>{
              'ret': 1,
              'data': <String, Object>{
                'config': <String, Object>{
                  'proxy-providers': <String, Object>{
                    'ecy-panel-nodes': file('ecy-panel-nodes', <Object>[
                      node('node-10'),
                    ]),
                    hk: <String, Object>{
                      'type': 'file',
                      'path': '$hk.json',
                      'members': <String>['node-10'],
                    },
                  },
                  'proxy-groups': <Object>[],
                  'rules': <String>['MATCH,DIRECT'],
                },
                'node_labels': <String, String>{'node-10': '香港 10'},
                'catalog': <String, Object>{
                  'stamp': 's1',
                  'providers': <String, Object>{
                    'ecy-panel-nodes': <String, Object>{
                      'key': 'ecy-panel-nodes',
                      'total': 900,
                      'head': 1,
                    },
                    hk: <String, Object>{'key': hk, 'total': 300, 'head': 1},
                  },
                  'ranks': <String, int>{'node-10': 10},
                },
              },
            }),
          );
        }
        await request.response.close();
      });
      final String origin = 'http://127.0.0.1:${server.port}';
      api = PanelApiClient(
        baseUrl: origin,
        configBaseUrl: origin,
        device: const DeviceInfo(
          platform: 'windows',
          deviceId: 'fixture',
          deviceName: '',
          deviceModel: '',
          osVersion: '',
          appVersion: '',
        ),
      )..token = 'fixture-token';
    });
    tearDown(() async {
      api.close();
      await server.close(force: true);
    });

    test('取配置声明节点副本上限并读出节点目录，并入的节点连同显示名进缓存', () async {
      final RemoteProfile remote = await api.fetchClashProfile();
      expect(requests.single.$2, <String, String?>{
        'catalog': '5000',
        'providers': '1',
        'members': '1',
        'type': null,
      });
      expect(remote.catalog!.providers[hk], (key: hk, total: 300, head: 1));
      expect(remote.catalog!.ranks, <String, int>{'node-10': 10});

      final RemoteProfile merged = remote.withNodes(<CatalogNode>[
        entry('node-5', 5, <String>['ecy-panel-nodes', hk]),
      ]);
      expect(names(merged.config, hk), <String>['node-5', 'node-10']);
      expect(merged.nodeLabels, <String, String>{
        'node-10': '香港 10',
        'node-5': '显示名 node-5',
      });
      expect(merged.revision, remote.revision);

      final Directory temp = Directory.systemTemp.createTempSync(
        'ecy-catalog-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final PanelResponseCache cache = PanelResponseCache(
        profileStore: JsonFileStore(File('${temp.path}/profile.json'), 't'),
        remoteStore: JsonFileStore(File('${temp.path}/remote.json'), 't'),
      );
      final Uint8List key = Uint8List.fromList(List<int>.filled(32, 7));
      cache.saveRemote('a@example.test', merged, key);
      final RemoteProfile restored = cache.loadRemote('a@example.test', key)!;
      expect(restored.catalog!.stamp, 's1');
      expect(restored.catalog!.ranks, <String, int>{
        'node-10': 10,
        'node-5': 5,
      });
      expect(names(restored.config, hk), <String>['node-5', 'node-10']);
      expect(restored.nodeLabels['node-5'], '显示名 node-5');
    });

    test('按页、按搜索词、按名取节点的请求体与应答解析', () async {
      nodesReply = <String, Object>{
        'stamp': 's1',
        'more': true,
        'nodes': <Object>[
          <String, Object>{
            'name': 'node-30',
            'rank': 30,
            'label': '香港 30',
            'providers': <String>['ecy-panel-nodes', hk],
            'proxy': node('node-30'),
          },
          // 名称与出站对不上的条目丢弃
          <String, Object>{
            'name': 'node-31',
            'rank': 31,
            'label': '香港 31',
            'providers': <String>['ecy-panel-nodes'],
            'proxy': node('node-99'),
          },
        ],
      };
      final NodePage page = await api.fetchNodes(provider: hk, offset: 100);
      expect(page.stamp, 's1');
      expect(page.more, isTrue);
      expect(page.nodes.single.name, 'node-30');
      expect(page.nodes.single.providers, <String>['ecy-panel-nodes', hk]);
      await api.fetchNodes(provider: hk, limit: 50, search: '香港');
      await api.fetchNodes(names: <String>['node-1', 'node-2']);
      expect(
        requests.map(((String, Map<String, String?>, Object?) r) => r.$1),
        <String>[
          'POST /api/client/v1/config/nodes',
          'POST /api/client/v1/config/nodes',
          'POST /api/client/v1/config/nodes',
        ],
      );
      expect(requests.first.$2['type'], 'application/json');
      expect(
        requests.map(((String, Map<String, String?>, Object?) r) => r.$3),
        <Object>[
          <String, Object>{'provider': hk, 'offset': 100, 'limit': 100},
          <String, Object>{
            'provider': hk,
            'offset': 0,
            'limit': 50,
            'search': '香港',
          },
          <String, Object>{
            'names': <String>['node-1', 'node-2'],
          },
        ],
      );
    });

    test('面板拒绝时抛出接口错误', () async {
      nodesReply = null;
      await expectLater(
        api.fetchNodes(provider: 'ecy-panel-unknown'),
        throwsA(
          isA<ApiException>().having(
            (ApiException e) => e.message,
            'message',
            '参数无效',
          ),
        ),
      );
    });
  });
}
