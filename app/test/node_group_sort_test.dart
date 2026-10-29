import 'package:ecycloud_client/domain/nodes/node_group_sort.dart';
import 'package:ecycloud_client/ui/node_labels.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    NodeLabels.configure('', <String, String>{
      'node-1': '德国 Ⅱ · A1',
      'node-2': '香港 Ⅱ · A1',
      'node-3': '美国 X · A1',
    });
  });

  test('默认名称序保持传入顺序', () {
    final List<String> members = <String>['DIRECT', 'node-2', 'node-1'];
    expect(
      NodeGroupSortLogic.apply(
        members: members,
        mode: NodeGroupSort.name,
        delayOf: (_) => 0,
        speedOf: (_) => 0,
      ),
      members,
    );
  });

  test('最低延迟只重排 node-* 槽位，DIRECT 不动', () {
    final List<String> sorted = NodeGroupSortLogic.apply(
      members: <String>['DIRECT', 'node-1', 'node-2', 'node-3'],
      mode: NodeGroupSort.latency,
      delayOf: (String name) => switch (name) {
        'node-2' => 40,
        'node-1' => 80,
        _ => 0,
      },
      speedOf: (_) => 0,
    );
    expect(sorted.first, 'DIRECT');
    expect(sorted.sublist(1), <String>['node-2', 'node-1', 'node-3']);
  });

  test('最高网速把无数据的节点放后面', () {
    final List<String> sorted = NodeGroupSortLogic.apply(
      members: <String>['node-1', 'node-2', 'node-3'],
      mode: NodeGroupSort.speed,
      delayOf: (_) => 0,
      speedOf: (String name) => switch (name) {
        'node-3' => 100,
        'node-1' => 50,
        _ => 0,
      },
    );
    expect(sorted, <String>['node-3', 'node-1', 'node-2']);
  });

  test('排序按钮按 名称 → 延迟 → 网速 循环', () {
    expect(NodeGroupSortLogic.next(NodeGroupSort.name), NodeGroupSort.latency);
    expect(NodeGroupSortLogic.next(NodeGroupSort.latency), NodeGroupSort.speed);
    expect(NodeGroupSortLogic.next(NodeGroupSort.speed), NodeGroupSort.name);
  });
}
