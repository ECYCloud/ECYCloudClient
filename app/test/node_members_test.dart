import 'dart:convert';

import 'package:ecycloud_client/data/api/api_exception.dart';
import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final String group = 'ecy-panel-${'a' * 64}';
  final String empty = 'ecy-panel-${'b' * 64}';
  final List<Map<String, Object>> nodes = <Map<String, Object>>[
    <String, Object>{'name': 'node-1', 'type': 'vless', 'port': 443},
    <String, Object>{'name': 'node-2', 'type': 'vless', 'port': 8443},
  ];
  Map<String, dynamic> config(Map<String, Object> groupProvider) => jsonDecode(
    jsonEncode(<String, Object>{
      'mode': 'rule',
      'proxy-providers': <String, Object>{
        'ecy-panel-nodes': <String, Object>{
          'type': 'file',
          'path': 'ecy-panel-nodes.json',
          'payload': nodes,
        },
        group: groupProvider,
        empty: <String, Object>{
          'type': 'file',
          'path': '$empty.json',
          'payload': <Object>[
            <String, String>{'name': 'ecy-panel-empty', 'type': 'reject'},
          ],
        },
      },
      'rules': <String>['MATCH,DIRECT'],
    }),
  ) as Map<String, dynamic>;

  test('成员名单按 ecy-panel-nodes 还原后与完整格式逐字段一致', () {
    final Map<String, dynamic> full = config(<String, Object>{
      'type': 'file',
      'path': '$group.json',
      'payload': <Object>[nodes[1], nodes[0]],
    });
    final Map<String, dynamic> compact = config(<String, Object>{
      'type': 'file',
      'path': '$group.json',
      'members': <String>['node-2', 'node-1'],
    });
    final Map<String, dynamic> restored = PanelApiClient.withNodePayloads(
      compact,
    );
    expect(jsonEncode(restored), jsonEncode(full));
    expect(jsonEncode(PanelApiClient.withNodePayloads(full)), jsonEncode(full));
  });

  test('成员名单引用未下发的节点或与 payload 并存时拒绝整份配置', () {
    for (final Map<String, Object> provider in <Map<String, Object>>[
      <String, Object>{
        'type': 'file',
        'path': '$group.json',
        'members': <String>['node-9'],
      },
      <String, Object>{
        'type': 'file',
        'path': '$group.json',
        'members': <String>['node-1'],
        'payload': nodes,
      },
      <String, Object>{
        'type': 'file',
        'path': '$group.json',
        'members': <Object>[],
      },
    ]) {
      expect(
        () => PanelApiClient.withNodePayloads(config(provider)),
        throwsA(isA<ApiException>()),
      );
    }
  });
}
