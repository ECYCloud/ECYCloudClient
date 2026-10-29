import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ecycloud_client/domain/config/local_template.dart';
import 'package:ecycloud_client/domain/kernel/clash_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final String? executable = Platform.environment['ECYCLOUD_MIHOMO'];
  test('真实内核独立更新节点保留 TCP、UDP、连接 ID 和 Fake-IP 映射', () async {
    final Directory run = await Directory.systemTemp.createTemp(
      'ecy-node-core-',
    );
    addTearDown(() => run.delete(recursive: true));
    final ServerSocket echo = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(echo.close);
    echo.listen((Socket socket) {
      addTearDown(socket.destroy);
      socket.listen(socket.add);
    });
    final RawDatagramSocket udpEcho = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(udpEcho.close);
    udpEcho.listen((RawSocketEvent event) {
      final Datagram? packet = udpEcho.receive();
      if (packet != null) {
        udpEcho.send(packet.data, packet.address, packet.port);
      }
    });
    final HttpServer probe = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => probe.close(force: true));
    probe.listen((HttpRequest request) async {
      request.response.statusCode = 204;
      await request.response.close();
    });
    Future<int> port() async {
      final ServerSocket socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final int value = socket.port;
      await socket.close();
      return value;
    }

    final int mixed = await port();
    final int dns = await port();
    final ClashApiOptions options = ClashApiOptions(
      port: await port(),
      secret: 'isolated-test',
    );
    final ClashApiClient api = ClashApiClient(options);
    addTearDown(api.close);
    const String provider = 'ecy-panel-nodes';
    void writeNodes(String name, {bool tfo = false, String type = 'direct'}) {
      final File next = File('${run.path}/nodes.next');
      next.writeAsStringSync(
        jsonEncode(<String, Object>{
          'proxies': <Object>[
            <String, Object>{'name': name, 'type': type, 'tfo': tfo},
          ],
        }),
      );
      next.renameSync('${run.path}/$provider.json');
    }

    writeNodes('node-1');
    final File config = File('${run.path}/config.json')
      ..writeAsStringSync(
        jsonEncode(<String, Object>{
          'mixed-port': mixed,
          'allow-lan': false,
          'mode': 'rule',
          'log-level': 'warning',
          'external-controller': '127.0.0.1:${options.port}',
          'secret': options.secret,
          'profile': <String, bool>{'store-fake-ip': true},
          'tun': <String, bool>{'enable': false},
          'dns': <String, Object>{
            'enable': true,
            'listen': '127.0.0.1:$dns',
            'enhanced-mode': 'fake-ip',
            'fake-ip-range': '198.18.0.1/16',
            'nameserver': <String>['192.0.2.1'],
          },
          'proxies': <Object>[],
          'proxy-providers': <String, Object>{
            provider: <String, Object>{
              'type': 'file',
              'path': '$provider.json',
            },
          },
          'proxy-groups': <Object>[
            <String, Object>{
              'name': 'group',
              'type': 'fallback',
              'proxies': <String>['REJECT'],
              'filter': r'^(?!REJECT$).*`^REJECT$',
              'url': 'http://127.0.0.1:${probe.port}/',
              'use': <String>[provider],
              'exclude-filter': '^ecy-panel-empty\$',
            },
            <String, Object>{
              'name': 'node-only',
              'type': 'select',
              'use': <String>[provider],
              'exclude-filter': '^ecy-panel-empty\$',
              'empty-fallback': 'REJECT',
            },
          ],
          'rules': <String>['MATCH,group'],
        }),
      );
    final Process core = await Process.start(executable!, <String>[
      '-d',
      run.path,
      '-f',
      config.path,
    ]);
    core.stdout.drain<void>();
    core.stderr.drain<void>();
    addTearDown(() async {
      core.kill();
      await core.exitCode.timeout(const Duration(seconds: 5));
    });
    await api.waitReady(timeout: const Duration(seconds: 10));
    expect(
      (await api.fetchProxies()).$1
          .firstWhere((ProxyGroup group) => group.name == 'group')
          .members,
      <String>['node-1', 'REJECT'],
    );
    final Socket tcp = await Socket.connect(
      InternetAddress.loopbackIPv4,
      mixed,
    );
    addTearDown(tcp.destroy);
    final _Reader reader = _Reader(tcp);
    tcp.add(<int>[5, 1, 0]);
    expect(await reader.read(2), <int>[5, 0]);
    tcp.add(<int>[5, 1, 0, 1, 127, 0, 0, 1, echo.port >> 8, echo.port & 255]);
    expect((await reader.read(10))[1], 0);
    Future<void> tcpEcho(String value) async {
      tcp.add(utf8.encode(value));
      expect(utf8.decode(await reader.read(value.length)), value);
    }

    await tcpEcho('before');
    final Socket association = await Socket.connect(
      InternetAddress.loopbackIPv4,
      mixed,
    );
    addTearDown(association.destroy);
    final _Reader udpReader = _Reader(association);
    association.add(<int>[5, 1, 0]);
    expect(await udpReader.read(2), <int>[5, 0]);
    association.add(<int>[5, 3, 0, 1, 0, 0, 0, 0, 0, 0]);
    final List<int> relay = await udpReader.read(10);
    expect(relay[1], 0);
    final int relayPort = relay[8] * 256 + relay[9];
    final RawDatagramSocket udp = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(udp.close);
    final StreamIterator<RawSocketEvent> udpEvents =
        StreamIterator<RawSocketEvent>(udp);
    Future<void> udpRoundTrip(String value) async {
      udp.send(
        <int>[
          0,
          0,
          0,
          1,
          127,
          0,
          0,
          1,
          udpEcho.port >> 8,
          udpEcho.port & 255,
          ...utf8.encode(value),
        ],
        InternetAddress.loopbackIPv4,
        relayPort,
      );
      Datagram? packet;
      while (packet == null) {
        await udpEvents.moveNext().timeout(const Duration(seconds: 5));
        packet = udp.receive();
      }
      expect(utf8.decode(packet.data.sublist(10)), value);
    }

    await udpRoundTrip('before');
    final String alpha = await _dns(dns, 'alpha.example.test');
    final String beta = await _dns(dns, 'beta.example.test');
    final List<String> ids = (await api.fetchStats()).$2
        .map((Map connection) => connection['id'] as String)
        .toList();
    expect(ids, hasLength(2));
    writeNodes('ecy-panel-empty', type: 'reject');
    await api.updateProxyProviders(<String>[provider]);
    expect(
      (await api.fetchProxies()).$1
          .firstWhere((ProxyGroup group) => group.name == 'node-only')
          .members,
      <String>['REJECT'],
    );
    await tcpEcho('empty');
    await udpRoundTrip('empty');
    writeNodes('node-2', tfo: true);
    await api.updateProxyProviders(<String>[provider]);
    await tcpEcho('after');
    await udpRoundTrip('after');
    final List<String> afterIds = (await api.fetchStats()).$2
        .map((Map connection) => connection['id'] as String)
        .toList();
    expect(afterIds, containsAll(ids));
    final String gamma = await _dns(dns, 'gamma.example.test');
    expect(<String>[alpha, beta], isNot(contains(gamma)));
    expect(await _dns(dns, 'alpha.example.test'), alpha);
    expect(await _dns(dns, 'beta.example.test'), beta);
    final (List<ProxyGroup> groups, List<ProxyNode> nodes) = await api
        .fetchProxies();
    expect(
      groups.firstWhere((ProxyGroup group) => group.name == 'group').members,
      <String>['node-2', 'REJECT'],
    );
    expect(nodes.any((ProxyNode node) => node.name == 'node-2'), isTrue);
    expect(
      await api.testDelay('node-2', url: 'http://127.0.0.1:${probe.port}/'),
      greaterThanOrEqualTo(0),
    );
  }, skip: executable == null ? '设置 ECYCLOUD_MIHOMO 指向官方内核后运行' : false);
}

class _Reader {
  _Reader(Socket socket) : stream = StreamIterator<Uint8List>(socket);
  final StreamIterator<Uint8List> stream;
  final List<int> bytes = <int>[];
  Future<List<int>> read(int count) async {
    while (bytes.length < count) {
      if (!await stream.moveNext().timeout(const Duration(seconds: 5))) {
        throw StateError('连接被关闭');
      }
      bytes.addAll(stream.current);
    }
    final List<int> result = bytes.sublist(0, count);
    bytes.removeRange(0, count);
    return result;
  }
}

Future<String> _dns(int port, String domain) async {
  final RawDatagramSocket socket = await RawDatagramSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  try {
    socket.send(
      <int>[
        0,
        1,
        1,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        for (final String part in domain.split('.')) ...<int>[
          part.length,
          ...ascii.encode(part),
        ],
        0,
        0,
        1,
        0,
        1,
      ],
      InternetAddress.loopbackIPv4,
      port,
    );
    await for (final RawSocketEvent _ in socket.timeout(
      const Duration(seconds: 5),
    )) {
      final Datagram? packet = socket.receive();
      if (packet != null) {
        return packet.data.sublist(packet.data.length - 4).join('.');
      }
    }
    throw StateError('DNS 未响应');
  } finally {
    socket.close();
  }
}
