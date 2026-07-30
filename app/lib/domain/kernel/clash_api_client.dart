import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/logger.dart';
import '../config/local_template.dart';

class ProxyGroup {
  const ProxyGroup({
    required this.name,
    required this.type,
    required this.now,
    required this.members,
  });

  final String name;
  final String type;
  final String now;
  final List<String> members;

  bool get selectable => type == 'Selector';
}

class ProxyNode {
  const ProxyNode({
    required this.name,
    required this.type,
    required this.delay,
  });

  final String name;
  final String type;

  // 毫秒，0 表示未测过延迟或不可用
  final int delay;
}

class TrafficSample {
  const TrafficSample(this.up, this.down);

  final int up;
  final int down;
}

/// `GET /connections` 的完整快照。内核在这里一并给出内存占用
/// （trafficontrol/manager.go 的 Snapshot.MarshalJSON），一次请求够用。
/// 快照里的 uploadTotal / downloadTotal 是含直连的全量，界面按连接自行汇总，不取。
class ConnectionsSnapshot {
  const ConnectionsSnapshot({required this.connections, required this.memory});

  static const ConnectionsSnapshot empty = ConnectionsSnapshot(
    connections: <Map<String, dynamic>>[],
    memory: 0,
  );

  final List<Map<String, dynamic>> connections;
  final int memory;
}

/// 内核运行状态。内存与连接数取自 `/connections` 快照，goroutine 数只能从
/// experimental.debug 的独立监听口拿（Clash API 没有这个字段）。
class KernelStats {
  const KernelStats({
    required this.memory,
    required this.connections,
    required this.goroutines,
  });

  static const KernelStats empty = KernelStats(
    memory: 0,
    connections: 0,
    goroutines: null,
  );

  final int memory;
  final int connections;
  final int? goroutines;
}

class ClashApiException implements Exception {
  ClashApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ClashApiClient {
  ClashApiClient(this.options, {http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  static const String _source = 'clash-api';

  // 内核为 Global 模式合成的分组，面板配置里不存在，不该出现在节点列表
  static const String _globalGroup = 'GLOBAL';

  final ClashApiOptions options;
  final http.Client _http;

  Map<String, String> get _headers => <String, String>{
    'Authorization': 'Bearer ${options.secret}',
    'Accept': 'application/json',
  };

  Uri _uri(String path, [Map<String, String>? query]) =>
      options.baseUri.replace(path: path, queryParameters: query);

  // 首次启动要下载并编译面板下发的全部远程规则集，实测冷缓存下 6~27 秒才开始监听
  Future<void> waitReady({
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      try {
        final http.Response response = await _http
            .get(_uri('/version'), headers: _headers)
            .timeout(const Duration(seconds: 2));
        if (response.statusCode == 200) {
          return;
        }
      } on Exception {
        // 内核尚未监听，继续等待
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    throw ClashApiException('内核控制面在 ${timeout.inSeconds} 秒内未就绪');
  }

  Future<(List<ProxyGroup>, List<ProxyNode>)> fetchProxies() async {
    final Map<String, dynamic> payload = await _getJson('/proxies');
    final Object? proxies = payload['proxies'];
    if (proxies is! Map<String, dynamic>) {
      return (const <ProxyGroup>[], const <ProxyNode>[]);
    }

    final List<ProxyGroup> groups = <ProxyGroup>[];
    final List<ProxyNode> nodes = <ProxyNode>[];

    for (final MapEntry<String, dynamic> entry in proxies.entries) {
      final Object? value = entry.value;
      if (value is! Map<String, dynamic> || entry.key == _globalGroup) {
        continue;
      }

      final String type = value['type'] as String? ?? '';
      final Object? members = value['all'];

      if (members is List) {
        groups.add(
          ProxyGroup(
            name: entry.key,
            type: type,
            now: value['now'] as String? ?? '',
            members: members.whereType<String>().toList(growable: false),
          ),
        );
      } else {
        nodes.add(
          ProxyNode(name: entry.key, type: type, delay: _latestDelay(value)),
        );
      }
    }

    return (groups, nodes);
  }

  Future<void> selectProxy(String group, String member) async {
    final http.Response response = await _http.put(
      _uri('/proxies/${Uri.encodeComponent(group)}'),
      headers: <String, String>{
        ..._headers,
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, String>{'name': member}),
    );

    if (response.statusCode != 204 && response.statusCode != 200) {
      throw ClashApiException('切换节点失败（HTTP ${response.statusCode}）');
    }
  }

  // 内核测的是「拨号 + 到目标站的 TLS 握手（仅 https）+ 一次 HTTP HEAD」，
  // 用明文 HTTP 能省掉 TLS 握手那一个往返，这是能砍掉的最大一块开销。
  //
  // 但两个 delay 端点都有 strings.HasPrefix(url, "http://") 就丢弃并回退到内置
  // https 地址的逻辑。该判断区分大小写，而 url.Parse 与 http.NewRequest 都会把
  // scheme 转小写，所以 scheme 写成大写即可原样传到内核的探测逻辑里。
  // 已用真内核实测：url=http://127.0.0.1:1/ 返回 238ms（说明被换成了默认地址），
  // url=HTTP://127.0.0.1:1/ 25ms 内直接报错（说明按传入地址拨号）。
  // 若上游改成大小写不敏感，这里只是退回 https 默认地址、延迟数字变大，不会坏。
  static const String _delayTestUrl = 'HTTP://cp.cloudflare.com/generate_204';

  Future<int> testDelay(
    String name, {
    String url = _delayTestUrl,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final Map<String, dynamic> payload = await _getJson(
      '/proxies/${Uri.encodeComponent(name)}/delay',
      <String, String>{'url': url, 'timeout': '${timeout.inMilliseconds}'},
    );

    final Object? delay = payload['delay'];
    if (delay is! num) {
      throw ClashApiException('节点 $name 不可用');
    }
    return delay.toInt();
  }

  // urltest 分组的选中项由内核算，只在它自己的 interval 到点或被显式触发时重算。
  // 逐个探测虽然把延迟写进了内核的历史（两处共用同一个 HistoryStorage，见
  // clashapi/server.go 的 urlTestHistory 与 protocol/group/urltest.go 的 history），
  // 但不会触发重选，界面上「当前」会停在旧节点。
  //
  // 这里补一次整组端点：刚测过的成员都在 interval 内，urlTest 会全部跳过、
  // 立刻走到 performUpdateCheck，于是几乎零开销地让内核按新延迟重选。
  Future<void> reselectGroup(String group) async {
    const Duration timeout = Duration(seconds: 5);
    await _getJson(
      '/group/${Uri.encodeComponent(group)}/delay',
      <String, String>{
        'url': _delayTestUrl,
        'timeout': '${timeout.inMilliseconds}',
      },
      timeout + const Duration(seconds: 3),
    );
  }

  Future<String> fetchMode() async =>
      (await _getJson('/configs'))['mode'] as String? ?? 'rule';

  Future<void> setMode(String mode) async {
    final http.Response response = await _http.patch(
      _uri('/configs'),
      headers: <String, String>{
        ..._headers,
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, String>{'mode': mode}),
    );

    if (response.statusCode != 204 && response.statusCode != 200) {
      throw ClashApiException('切换模式失败（HTTP ${response.statusCode}）');
    }
  }

  Future<void> closeAllConnections() async {
    final http.Response response = await _http.delete(
      _uri('/connections'),
      headers: _headers,
    );

    if (response.statusCode != 204 && response.statusCode != 200) {
      throw ClashApiException('关闭存量连接失败（HTTP ${response.statusCode}）');
    }
  }

  // 非 websocket 请求时该端点是一次性快照（clashapi/connections.go），可以直接轮询
  Future<ConnectionsSnapshot> _fetchConnections() async {
    final Map<String, dynamic> payload = await _getJson('/connections');
    final Object? connections = payload['connections'];

    return ConnectionsSnapshot(
      connections: connections is List
          ? connections.whereType<Map<String, dynamic>>().toList(
              growable: false,
            )
          : const <Map<String, dynamic>>[],
      memory: (payload['memory'] as num?)?.toInt() ?? 0,
    );
  }

  // 连接列表与内核状态同源，一次轮询取全
  Future<(KernelStats, List<Map<String, dynamic>>)> fetchStats() async {
    final (ConnectionsSnapshot, int?) result = await (
      _fetchConnections(),
      _fetchGoroutines(),
    ).wait;

    return (
      KernelStats(
        memory: result.$1.memory,
        connections: result.$1.connections.length,
        goroutines: result.$2,
      ),
      result.$1.connections,
    );
  }

  // Clash API 没有 goroutine 数量，只有 experimental.debug 那个独立监听口的
  // GET /debug/memory 有（box 的 debug_http.go）。堆栈占用在那里是格式化后的字符串，
  // 数值口径又和 /connections 的 memory 不同，所以只取 goroutines。
  Future<int?> _fetchGoroutines() async {
    final Uri? uri = options.debugUri;
    if (uri == null) {
      return null;
    }

    try {
      final http.Response response = await _http
          .get(uri.replace(path: '/debug/memory'))
          .timeout(const Duration(seconds: 3));
      if (response.statusCode != 200) {
        return null;
      }
      final Object? decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic>
          ? (decoded['goroutines'] as num?)?.toInt()
          : null;
    } on Object {
      return null;
    }
  }

  Stream<String> logStream(String level) =>
      _ndjsonStream('/logs', <String, String>{'level': level}).map(
        (Map<String, dynamic> event) =>
            '[${event['type'] ?? ''}] ${event['payload'] ?? ''}',
      );

  Stream<Map<String, dynamic>> _ndjsonStream(
    String path, [
    Map<String, String>? query,
  ]) {
    late StreamController<Map<String, dynamic>> controller;
    http.Client? streamClient;

    Future<void> start() async {
      streamClient = http.Client();
      try {
        final http.Request request = http.Request('GET', _uri(path, query))
          ..headers.addAll(_headers);
        final http.StreamedResponse response = await streamClient!.send(
          request,
        );

        await for (final String line
            in response.stream
                .transform(utf8.decoder)
                .transform(const LineSplitter())) {
          if (line.trim().isEmpty) {
            continue;
          }
          final Object? decoded = jsonDecode(line);
          if (decoded is Map<String, dynamic>) {
            controller.add(decoded);
          }
        }
      } on Object catch (e) {
        Logger.instance.debug(_source, '$path 流中断: $e');
      } finally {
        streamClient?.close();
        if (!controller.isClosed) {
          await controller.close();
        }
      }
    }

    controller = StreamController<Map<String, dynamic>>(
      onListen: () => unawaited(start()),
      onCancel: () => streamClient?.close(),
    );

    return controller.stream;
  }

  Future<Map<String, dynamic>> _getJson(
    String path, [
    Map<String, String>? query,
    Duration httpTimeout = const Duration(seconds: 10),
  ]) async {
    final http.Response response = await _http
        .get(_uri(path, query), headers: _headers)
        .timeout(httpTimeout);

    if (response.statusCode != 200) {
      throw ClashApiException('$path 请求失败（HTTP ${response.statusCode}）');
    }

    final Object? decoded = jsonDecode(utf8.decode(response.bodyBytes));
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  static int _latestDelay(Map<String, dynamic> proxy) {
    final Object? history = proxy['history'];
    if (history is! List || history.isEmpty) {
      return 0;
    }
    final Object? last = history.last;
    return last is Map<String, dynamic>
        ? (last['delay'] as num?)?.toInt() ?? 0
        : 0;
  }

  void close() => _http.close();
}
