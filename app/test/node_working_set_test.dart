import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:ecycloud_client/domain/config/node_working_set.dart';
import 'package:ecycloud_client/domain/config/profile_inspector.dart';
import 'package:ecycloud_client/domain/config/speed_probe_config.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> node(int id) => <String, dynamic>{
  'name': 'node-$id',
  'type': 'ss',
  'server': '192.0.2.${id % 250 + 1}',
  'port': 8000 + id,
  'cipher': 'aes-128-gcm',
  'password': 'test',
};

Map<String, dynamic> provider(String name, Iterable<int> ids) =>
    <String, dynamic>{
      'type': 'file',
      'path': '$name.json',
      'payload': ids.isEmpty
          ? <Object?>[
              <String, String>{'name': 'ecy-panel-empty', 'type': 'reject'},
            ]
          : <Object?>[for (final int id in ids) node(id)],
    };

String shared(String key) => 'ecy-panel-${sha256.convert(utf8.encode(key))}';

// 面板的实际形态：总节点文件、按匹配条件共用的节点文件、空分组的占位、指向单个节点的规则分组
Map<String, dynamic> catalog(int count) {
  final String tail = shared('tail');
  final String empty = shared('empty');
  return <String, dynamic>{
    'proxies': <Object?>[],
    'proxy-providers': <String, dynamic>{
      'ecy-panel-nodes': provider('ecy-panel-nodes', <int>[
        for (int id = 1; id <= count; id++) id,
      ]),
      tail: provider(tail, <int>[
        for (int id = count ~/ 2 + 1; id <= count; id++) id,
      ]),
      empty: provider(empty, const <int>[]),
    },
    'proxy-groups': <Object?>[
      <String, dynamic>{
        'name': 'all',
        'type': 'select',
        'proxies': <String>['DIRECT'],
        'use': <String>['ecy-panel-nodes'],
        'default-selected': 'node-${count - 1}',
      },
      <String, dynamic>{
        'name': 'tail',
        'type': 'url-test',
        'proxies': <String>[],
        'use': <String>[tail],
        'exclude-filter': r'^ecy-panel-empty$',
        'empty-fallback': 'REJECT',
      },
      <String, dynamic>{
        'name': 'empty',
        'type': 'select',
        'proxies': <String>['DIRECT'],
        'use': <String>[empty],
        'exclude-filter': r'^ecy-panel-empty$',
      },
      <String, dynamic>{
        'name': 'ecy-panel-target-x',
        'type': 'select',
        'hidden': true,
        'use': <String>['ecy-panel-nodes'],
        'filter': '^node\\-${count - 3}\$',
      },
    ],
    'rules': <String>['DOMAIN,pinned.test,ecy-panel-target-x', 'MATCH,all'],
  };
}

List<String> namesOf(Map<String, dynamic> config, String name) => <String>[
  for (final Object? item
      in ((config['proxy-providers'] as Map)[name] as Map)['payload'] as List)
    (item as Map)['name'] as String,
];

void main() {
  test('副本数没超过上限时全部装入，节点文件原样保留', () {
    final Map<String, dynamic> config = catalog(40);
    expect(NodeWorkingSet.select(config, budget: 60), isNull);

    final Map<String, dynamic> kept = NodeWorkingSet.restrict(config, null);
    final Map<String, dynamic> providers =
        kept['proxy-providers'] as Map<String, dynamic>;
    expect(
      providers['ecy-panel-nodes'],
      same((config['proxy-providers'] as Map)['ecy-panel-nodes']),
    );
    expect(namesOf(kept, NodeWorkingSet.probeProvider), <String>[
      'ecy-panel-empty',
    ]);
    expect(() => ProfileInspector.ensureValid(kept), returnsNormally);
  });

  test('超过上限时只装在用的节点，副本数不超过上限', () {
    final Map<String, dynamic> config = catalog(1000);
    final Set<String> loaded = NodeWorkingSet.select(
      config,
      budget: 100,
      pinned: <String>['node-777', '不是节点'],
    )!;
    final Map<String, dynamic> kept = NodeWorkingSet.restrict(config, loaded);
    final String tail = shared('tail');

    final int copies =
        namesOf(kept, 'ecy-panel-nodes').length + namesOf(kept, tail).length;
    expect(copies, lessThanOrEqualTo(101));
    expect(copies, greaterThanOrEqualTo(99));
    expect(namesOf(kept, 'ecy-panel-nodes').toSet(), loaded);
    expect(namesOf(kept, tail), everyElement(isIn(loaded)));
    expect(namesOf(kept, shared('empty')), <String>['ecy-panel-empty']);
    expect(() => ProfileInspector.ensureValid(kept), returnsNormally);
  });

  test('用户选中的、分组默认选中的、规则直接指向的节点一定装入', () {
    final Set<String> loaded = NodeWorkingSet.select(
      catalog(1000),
      budget: 100,
      pinned: <String>['node-777'],
    )!;
    expect(loaded, containsAll(<String>['node-777', 'node-999', 'node-997']));
  });

  test('每个有成员的节点文件至少留一个节点，顺序与面板一致', () {
    final Map<String, dynamic> config = catalog(1000);
    final Map<String, dynamic> kept = NodeWorkingSet.restrict(
      config,
      NodeWorkingSet.select(config, budget: 8)!,
    );
    final List<String> tail = namesOf(kept, shared('tail'));
    expect(tail, isNot(contains('ecy-panel-empty')));
    expect(tail.first, 'node-501');

    final List<String> all = namesOf(kept, 'ecy-panel-nodes');
    final List<int> ids = <int>[
      for (final String name in all) int.parse(name.substring(5)),
    ];
    expect(ids, List<int>.of(ids)..sort());
  });

  test('选取结果只取决于面板配置与固定项，重复计算一致', () {
    final Map<String, dynamic> config = catalog(3000);
    expect(
      NodeWorkingSet.select(config, budget: 500, pinned: <String>['node-9']),
      NodeWorkingSet.select(config, budget: 500, pinned: <String>['node-9']),
    );
  });

  test('旧格式配置没有节点文件，不做裁剪也不加探测文件', () {
    final Map<String, dynamic> config = <String, dynamic>{
      'proxies': <Object?>[node(1)],
      'proxy-groups': <Object?>[],
    };
    expect(NodeWorkingSet.select(config, budget: 0), isNull);
    expect(NodeWorkingSet.restrict(config, null), same(config));
  });

  test('探测节点文件里的节点可被测速分组选用', () {
    final Map<String, dynamic> config = NodeWorkingSet.restrict(
      catalog(10),
      null,
      <Object?>[node(5000)],
    );
    expect(namesOf(config, NodeWorkingSet.probeProvider), <String>[
      'node-5000',
    ]);
    expect(
      RegExp(r'^ecy-panel-[a-f0-9]{64}$')
          .hasMatch(NodeWorkingSet.probeProvider),
      isTrue,
    );

    SpeedProbeConfig.applyTo(config, 7890, 'secret');
    final Map<dynamic, dynamic> probe = (config['proxy-groups'] as List).last;
    expect(probe['use'], <String>[
      'ecy-panel-nodes',
      NodeWorkingSet.probeProvider,
    ]);
  });
}
