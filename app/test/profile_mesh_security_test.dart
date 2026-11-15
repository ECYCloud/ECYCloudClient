import 'package:ecycloud_client/domain/config/profile_inspector.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _remote(List<Map<String, Object>> proxies) =>
    <String, dynamic>{
      'proxies': proxies,
      'proxy-groups': <Object>[
        <String, Object>{
          'name': 'group',
          'type': 'select',
          'proxies': <String>['node'],
        },
      ],
      'rules': <String>['MATCH,group'],
    };

void main() {
  test('面板下发的组网类出站一律拒绝，含节点订阅载荷', () {
    for (final String type in <String>['easytier', 'ZeroTier', ' tailscale ']) {
      final List<String> issues = ProfileInspector.inspect(
        _remote(<Map<String, Object>>[
          <String, Object>{'name': 'node', 'type': 'ss'},
          <String, Object>{'name': 'mesh', 'type': type},
        ]),
      );
      expect(issues.any((String issue) => issue.contains('mesh')), isTrue, reason: type);
    }
    final Map<String, dynamic> provided = _remote(<Map<String, Object>>[
      <String, Object>{'name': 'node', 'type': 'ss'},
    ]);
    provided['proxy-providers'] = <String, Object>{
      'ecy-panel-nodes': <String, Object>{
        'type': 'file',
        'path': 'ecy-panel-nodes.json',
        'payload': <Object>[
          <String, Object>{'name': 'node', 'type': 'ss'},
          <String, Object>{'name': 'hidden', 'type': 'easytier'},
        ],
      },
    };
    expect(
      ProfileInspector.inspect(provided).any((String issue) => issue.contains('hidden')),
      isTrue,
    );
    expect(
      ProfileInspector.inspect(
        _remote(<Map<String, Object>>[<String, Object>{'name': 'node', 'type': 'vless'}]),
      ),
      isEmpty,
    );
  });
}
