import '../../ui/node_labels.dart';

enum NodeGroupSort { name, latency, speed }

class NodeGroupSortLogic {
  NodeGroupSortLogic._();

  static NodeGroupSort next(NodeGroupSort current) => switch (current) {
    NodeGroupSort.name => NodeGroupSort.latency,
    NodeGroupSort.latency => NodeGroupSort.speed,
    NodeGroupSort.speed => NodeGroupSort.name,
  };

  static List<String> apply({
    required List<String> members,
    required NodeGroupSort mode,
    required int Function(String name) delayOf,
    required int Function(String name) speedOf,
  }) {
    if (mode == NodeGroupSort.name) {
      return members;
    }

    final List<int> slots = <int>[];
    final List<String> nodes = <String>[];
    for (int i = 0; i < members.length; i++) {
      if (NodeLabels.officialId(members[i]) == null) {
        continue;
      }
      slots.add(i);
      nodes.add(members[i]);
    }
    if (nodes.length < 2) {
      return members;
    }

    nodes.sort((String a, String b) {
      final int ranked = mode == NodeGroupSort.latency
          ? _byLatency(delayOf(a), delayOf(b))
          : _bySpeed(speedOf(a), speedOf(b));
      return ranked != 0 ? ranked : NodeLabels.compareName(a, b);
    });

    final List<String> out = List<String>.of(members);
    for (int i = 0; i < slots.length; i++) {
      out[slots[i]] = nodes[i];
    }
    return List<String>.unmodifiable(out);
  }

  static int _byLatency(int a, int b) {
    final bool aOk = a > 0;
    final bool bOk = b > 0;
    if (aOk != bOk) {
      return aOk ? -1 : 1;
    }
    if (!aOk) {
      return 0;
    }
    return a.compareTo(b);
  }

  static int _bySpeed(int a, int b) {
    final bool aOk = a > 0;
    final bool bOk = b > 0;
    if (aOk != bOk) {
      return aOk ? -1 : 1;
    }
    if (!aOk) {
      return 0;
    }
    return b.compareTo(a);
  }
}
