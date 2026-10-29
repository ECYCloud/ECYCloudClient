import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../core/logger.dart';
import '../../l10n/l10n.dart';
import '../config/local_template.dart';
import '../config/speed_probe_config.dart';

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
    this.udp,
    this.xudp,
  });

  final String name;
  final String type;

  final int delay;

  // 内核 GET /proxies 的 udp / xudp，未连接时没有
  final bool? udp;
  final bool? xudp;
}

class TrafficSample {
  const TrafficSample(this.up, this.down, [this.at]);

  final int up;
  final int down;
  final DateTime? at;
}

/// uploadTotal / downloadTotal 含直连，界面按连接自行汇总，不取。
/// Snapshot.memory 只有 /memory 会刷新，本快照本身不更新。
class ConnectionsSnapshot {
  const ConnectionsSnapshot({required this.connections, required this.memory});

  static const ConnectionsSnapshot empty = ConnectionsSnapshot(
    connections: <Map<String, dynamic>>[],
    memory: 0,
  );

  final List<Map<String, dynamic>> connections;
  final int memory;
}

/// 连接数取 /connections，内存取 /memory 流的 inuse（进程 RSS）
class KernelStats {
  const KernelStats({required this.memory, required this.connections});

  static const KernelStats empty = KernelStats(memory: 0, connections: 0);

  final int memory;
  final int connections;
}

class ClashApiException implements Exception {
  ClashApiException(this.message);

  final String message;

  @override
  String toString() => L10n.message(message);
}

class ClashApiClient {
  ClashApiClient(this.options, {http.Client? httpClient})
    : _http = httpClient ?? _directClient();

  static const String _source = 'clash-api';

  // 内核为 Global 模式合成的 Selector，面板配置里不存在
  static const String globalGroupName = 'GLOBAL';

  final ClashApiOptions options;
  final http.Client _http;
  final Map<String, String> _nodeProviders = <String, String>{};

  int _memoryInuse = 0;
  StreamSubscription<Map<String, dynamic>>? _memorySubscription;

  // 控制面在 127.0.0.1：必须直连。重启期间系统代理仍指向已停的 mixed 口时，
  // 默认 HttpClient 若走代理会导致 waitReady 空等至超时。
  static http.Client _directClient() =>
      IOClient(HttpClient()..findProxy = (Uri _) => 'DIRECT');

  Map<String, String> get _headers => <String, String>{
    'Authorization': 'Bearer ${options.secret}',
    'Accept': 'application/json',
  };

  Uri _uri(String path, [Map<String, String>? query]) =>
      options.baseUri.replace(path: path, queryParameters: query);

  Future<void> waitReady({
    int? proxyPort,
    Duration timeout = const Duration(seconds: 60),
    bool Function()? isCancelled,
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      if (isCancelled?.call() ?? false) {
        throw ClashApiException('连接已取消');
      }
      try {
        final http.Response response = await _request(
          'GET',
          '/version',
          timeout: const Duration(seconds: 2),
        );
        if (response.statusCode == 200 && !(isCancelled?.call() ?? false)) {
          if (proxyPort == null) {
            return;
          }
          await selectProxy(SpeedProbeConfig.groupName, 'DIRECT');
          final http.Client probe = IOClient(
            HttpClient()..findProxy = (Uri _) => 'PROXY 127.0.0.1:$proxyPort',
          );
          try {
            // /version 先于转发就绪；经入站转发至本机 API 的 401 才能确认放行。
            // 探测不发送控制密钥，防止初始化期间的旧选中项将它转发出本机。
            final http.Request request = http.Request('GET', _uri('/version'))
              ..followRedirects = false
              ..headers['Proxy-Authorization'] =
                  'Basic ${base64Encode(utf8.encode(SpeedProbeConfig.credential(options.secret)))}';
            final http.Response forwarded = await probe
                .send(request)
                .then(http.Response.fromStream)
                .timeout(const Duration(seconds: 2));
            if (forwarded.statusCode == 401 &&
                !(isCancelled?.call() ?? false)) {
              return;
            }
          } finally {
            probe.close();
          }
        }
      } on Exception catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    throw ClashApiException(
      '内核${proxyPort == null ? '控制面' : '转发'}在 ${timeout.inSeconds} 秒内未就绪',
    );
  }

  Future<(List<ProxyGroup>, List<ProxyNode>)> fetchProxies() async {
    final Map<String, dynamic> payload = await _getJson('/proxies');
    final Object? proxies = payload['proxies'];
    if (proxies is! Map<String, dynamic>) {
      return (const <ProxyGroup>[], const <ProxyNode>[]);
    }

    final List<ProxyGroup> groups = <ProxyGroup>[];
    final List<ProxyNode> nodes = <ProxyNode>[];
    final bool hasProviderNodes = proxies.values.whereType<Map>().any(
      (Map value) =>
          value['all'] is List &&
          (value['all'] as List).any(
            (Object? name) =>
                name != 'DIRECT' &&
                name != 'REJECT' &&
                !proxies.containsKey(name),
          ),
    );
    final Map<String, dynamic> providerPayload = hasProviderNodes
        ? await _getJson('/providers/proxies')
        : const <String, dynamic>{};
    _nodeProviders.clear();
    final Object? providers = providerPayload['providers'];
    final Object? panel = providers is Map
        ? providers['ecy-panel-nodes']
        : null;
    if (panel is Map && panel['proxies'] is List) {
      for (final Map value in (panel['proxies'] as List).whereType<Map>()) {
        final String name = value['name'] as String;
        _nodeProviders[name] = 'ecy-panel-nodes';
        nodes.add(
          ProxyNode(
            name: name,
            type: value['type'] as String,
            delay: _latestDelay(Map<String, dynamic>.from(value)),
            udp: value['udp'] as bool?,
            xudp: value['xudp'] as bool?,
          ),
        );
      }
    }

    for (final MapEntry<String, dynamic> entry in proxies.entries) {
      if (entry.key == SpeedProbeConfig.groupName) {
        continue;
      }
      final Object? value = entry.value;
      if (value is! Map<String, dynamic>) {
        continue;
      }
      if (value['hidden'] == true) {
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
            members: members
                .whereType<String>()
                .where(
                  (String name) =>
                      entry.key != globalGroupName ||
                      name != SpeedProbeConfig.groupName,
                )
                .toList(growable: false),
          ),
        );
      } else {
        nodes.add(
          ProxyNode(
            name: entry.key,
            type: type,
            delay: _latestDelay(value),
            udp: value['udp'] as bool?,
            xudp: value['xudp'] as bool?,
          ),
        );
      }
    }

    return (groups, nodes);
  }

  Future<void> selectProxy(String group, String member) async {
    final http.Response response = await _request(
      'PUT',
      '/proxies/${Uri.encodeComponent(group)}',
      body: <String, String>{'name': member},
    );

    if (response.statusCode != 204 && response.statusCode != 200) {
      throw ClashApiException('切换节点失败（HTTP ${response.statusCode}）');
    }
  }

  // unified-delay 下内核连打两次 HEAD 并从第二次计时，TLS 握手不进窗口；明文 HTTP 会被内核警告劫持，用 https。
  static const String _delayTestUrl = 'https://cp.cloudflare.com/generate_204';

  Future<int> testDelay(
    String name, {
    String url = _delayTestUrl,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final Map<String, dynamic> payload = await _getJson(
      _nodeProviders.containsKey(name)
          ? '/providers/proxies/${Uri.encodeComponent(_nodeProviders[name]!)}/${Uri.encodeComponent(name)}/healthcheck'
          : '/proxies/${Uri.encodeComponent(name)}/delay',
      <String, String>{'url': url, 'timeout': '${timeout.inMilliseconds}'},
    );

    final Object? delay = payload['delay'];
    if (delay is! num) {
      throw ClashApiException('节点 $name 不可用');
    }
    return delay.toInt();
  }

  // url-test 按成员自己那个 url 的历史挑最快；须走 /group/{name}/delay 才会按 group.url 写历史并重挑。
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

  /// 内核常驻时 tun.enable 是唯一能读回本轮是否接管出口的字段
  Future<({String mode, bool tunEnabled})> fetchRuntime() async {
    final Map<String, dynamic> config = await _getJson('/configs');
    final Object? tun = config['tun'];
    return (
      mode: config['mode'] as String? ?? 'rule',
      tunEnabled: tun is Map<String, dynamic> && tun['enable'] == true,
    );
  }

  Future<void> setMode(String mode) async {
    final http.Response response = await _request(
      'PATCH',
      '/configs',
      body: <String, String>{'mode': mode},
    );

    if (response.statusCode != 204 && response.statusCode != 200) {
      throw ClashApiException('切换模式失败（HTTP ${response.statusCode}）');
    }
  }

  /// PATCH 只改 tun.enable，其余字段沿用 LastTunConf（pointerOrDefaultTun）。
  Future<void> setTunEnabled(
    bool enabled, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final http.Response response = await _request(
      'PATCH',
      '/configs',
      body: <String, dynamic>{
        'tun': <String, dynamic>{'enable': enabled},
      },
      timeout: timeout,
    );

    if (response.statusCode != 204 && response.statusCode != 200) {
      throw ClashApiException(
        enabled
            ? '开启 TUN 失败（HTTP ${response.statusCode}）'
            : '关闭 TUN 失败（HTTP ${response.statusCode}）',
      );
    }
  }

  Future<void> disableTun() =>
      setTunEnabled(false, timeout: const Duration(seconds: 1));

  // ApplyConfig / 热载不绕过 interval；规则内容变而 url 未变必须 PUT /providers/rules/{name}
  Future<void> updateRuleProviders(Iterable<String> names) =>
      _updateProviders('rules', names);

  Future<void> updateProxyProviders(Iterable<String> names) =>
      _updateProviders('proxies', names);

  Future<void> _updateProviders(String kind, Iterable<String> names) async {
    await Future.wait(
      names.map((String name) async {
        final http.Response response = await _request(
          'PUT',
          '/providers/$kind/${Uri.encodeComponent(name)}',
          timeout: const Duration(seconds: 120),
        );
        if (response.statusCode != 204 && response.statusCode != 200) {
          throw ClashApiException(
            '更新 $kind/$name 失败（HTTP ${response.statusCode}）',
          );
        }
      }),
    );
  }

  // 禁止另写 geodata 下载器；走内核 updater.UpdateGeoDatabases，结束才回 204 / 500
  Future<void> updateGeoDatabases() async {
    final http.Response response = await _request(
      'POST',
      '/configs/geo',
      timeout: const Duration(seconds: 180),
    );

    if (response.statusCode != 204 && response.statusCode != 200) {
      throw ClashApiException(_errorDetail(response));
    }
  }

  static String _errorDetail(http.Response response) {
    final String body = response.body.trim();
    if (body.isEmpty) {
      return 'HTTP ${response.statusCode}';
    }
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final Object? message = decoded['message'];
        if (message is String && message.isNotEmpty) {
          return message;
        }
      }
    } on Object catch (_) {}
    return body.length > 200 ? body.substring(0, 200) : body;
  }

  /// PUT /configs?force=true + payload 走 ApplyConfig，不重建 external-controller
  Future<void> applyConfigPayload(
    String configJson, {
    bool force = true,
  }) async {
    final http.Response response = await _request(
      'PUT',
      '/configs',
      query: <String, String>{'force': '$force'},
      body: <String, String>{'payload': configJson},
      timeout: const Duration(seconds: 120),
    );

    if (response.statusCode != 204 && response.statusCode != 200) {
      final String body = response.body.trim();
      throw ClashApiException(
        body.isEmpty
            ? '热载配置失败（HTTP ${response.statusCode}）'
            : '热载配置失败：${body.length > 200 ? body.substring(0, 200) : body}',
      );
    }
  }

  /// PUT /proxies/{name} 只改选中项，存量连接仍走旧出站；按 chains 筛，勿用全量 DELETE /connections
  Future<void> closeConnectionsVia(Set<String> outbounds) async {
    try {
      final ConnectionsSnapshot snapshot = await _fetchConnections();

      final List<Future<void>> closing = <Future<void>>[];
      for (final Map<String, dynamic> item in snapshot.connections) {
        final Object? chains = item['chains'];
        if (chains is List && chains.any(outbounds.contains)) {
          closing.add(closeConnection('${item['id']}'));
        }
      }
      await Future.wait(closing);
    } on Object catch (e) {
      Logger.instance.warn(_source, '清理旧出站上的存量连接失败: $e');
    }
  }

  // 内核对不存在的 id 回 204
  Future<void> closeConnection(String id) async {
    final http.Response response = await _request(
      'DELETE',
      '/connections/${Uri.encodeComponent(id)}',
    );

    if (response.statusCode != 204 && response.statusCode != 200) {
      throw ClashApiException('关闭存量连接失败（HTTP ${response.statusCode}）');
    }
  }

  // 不带 Upgrade: websocket 时 /connections 是一次性快照，可轮询
  Future<ConnectionsSnapshot> _fetchConnections() async {
    final Map<String, dynamic> payload = await _getJson('/connections');
    // Connections 字段没有 omitempty，一条连接都没有时内核给的是 null 而不是 []
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

  // Snapshot.memory 只读缓存；updateMemory 只在 /memory 调用，不订阅永远是 0
  Future<(KernelStats, List<Map<String, dynamic>>)> fetchStats() async {
    _ensureMemoryProbe();
    final ConnectionsSnapshot snapshot = await _fetchConnections();

    return (
      KernelStats(
        memory: _memoryInuse > 0 ? _memoryInuse : snapshot.memory,
        connections: snapshot.connections.length,
      ),
      snapshot.connections,
    );
  }

  // 首帧被内核故意写成 0，之后每秒推真实 RSS
  void _ensureMemoryProbe() {
    if (_memorySubscription != null) {
      return;
    }
    _memorySubscription = _ndjsonStream('/memory').listen(
      (Map<String, dynamic> event) {
        final int inuse = (event['inuse'] as num?)?.toInt() ?? 0;
        if (inuse > 0) {
          _memoryInuse = inuse;
        }
      },
      onDone: () {
        _memorySubscription = null;
      },
      onError: (_) {
        _memorySubscription = null;
      },
      cancelOnError: true,
    );
  }

  // 级别必须大写：/logs 只给类型与正文，Logger.kernelLevel 靠行首这个大写词识别级别
  Stream<String> logStream(
    String level,
  ) => _ndjsonStream('/logs', <String, String>{'level': level}).map(
    (Map<String, dynamic> event) =>
        '${(event['type'] as String? ?? '').toUpperCase()} ${event['payload'] ?? ''}',
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
    final http.Response response = await _request(
      'GET',
      path,
      query: query,
      timeout: httpTimeout,
    );

    if (response.statusCode != 200) {
      throw ClashApiException('$path 请求失败（HTTP ${response.statusCode}）');
    }

    final Object? decoded = jsonDecode(utf8.decode(response.bodyBytes));
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  Future<http.Response> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final Completer<void> abort = Completer<void>();
    final http.AbortableRequest request = http.AbortableRequest(
      method,
      _uri(path, query),
      abortTrigger: abort.future,
    )..headers.addAll(_headers);
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      return await _http
          .send(request)
          .then(http.Response.fromStream)
          .timeout(
            timeout,
            onTimeout: () {
              abort.complete();
              throw TimeoutException('内核请求超时', timeout);
            },
          );
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
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

  void close() {
    final StreamSubscription<Map<String, dynamic>>? memory =
        _memorySubscription;
    _memorySubscription = null;
    _memoryInuse = 0;
    unawaited(memory?.cancel());
    _http.close();
  }
}
