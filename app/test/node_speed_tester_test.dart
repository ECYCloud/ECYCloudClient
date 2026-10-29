import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ecycloud_client/domain/config/speed_probe_config.dart';
import 'package:ecycloud_client/domain/kernel/node_speed_tester.dart';
import 'package:ecycloud_client/ui/format.dart';
import 'package:ecycloud_client/ui/node_labels.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('按下载字节和耗时算出每秒字节数', () {
    expect(
      NodeSpeedTester.bytesPerSecond(
        5 * 1024 * 1024,
        const Duration(seconds: 2),
      ),
      2621440,
    );
    expect(NodeSpeedTester.bytesPerSecond(0, const Duration(seconds: 1)), 0);
    expect(NodeSpeedTester.bytesPerSecond(1024, Duration.zero), 0);
  });

  test('窗口速度满 1 秒才出数，只保留峰值', () {
    expect(NodeSpeedTester.sampleInterval, const Duration(seconds: 1));
    expect(NodeSpeedTester.connectTimeout, const Duration(seconds: 2));
    expect(NodeSpeedTester.timeout, const Duration(seconds: 10));
    expect(NodeSpeedTester.isolateTimeout, const Duration(seconds: 15));
    expect(
      NodeSpeedTester.windowSpeed(
        1024 * 1024,
        const Duration(milliseconds: 999),
      ),
      0,
    );
    expect(
      NodeSpeedTester.windowSpeed(
        1024 * 1024,
        const Duration(milliseconds: 1000),
      ),
      (1024 * 1024 * 1000 / 1001).round(),
    );
    expect(NodeSpeedTester.peak(0, 1024), 1024);
    expect(
      NodeSpeedTester.peak(8 * 1024 * 1024, 3 * 1024 * 1024),
      8 * 1024 * 1024,
    );
    expect(
      NodeSpeedTester.httpStatus('HTTP/1.1 200 Connection established'),
      200,
    );
    expect(NodeSpeedTester.httpStatus('HTTP/1.1 403 Forbidden'), 403);
    expect(NodeSpeedTester.indexOfHeaderEnd(<int>[13, 10, 13, 10]), 0);
    expect(Format.speedSi(55900000), '55.9 MB/s');
    expect(Format.speedSi(69800000), '69.8 MB/s');
  });

  test('固定测速入站使用独立选择组并保持业务分流', () {
    expect(SpeedProbeConfig.portOf(10203), 10204);
    expect(SpeedProbeConfig.portOf(65535), 65534);

    final List<Map<String, dynamic>> proxies = <Map<String, dynamic>>[
      <String, dynamic>{'name': 'node-12', 'type': 'trojan'},
      <String, dynamic>{'name': 'node-34', 'type': 'vmess'},
    ];
    final Map<String, dynamic> businessGroup = <String, dynamic>{
      'name': '主节点',
      'type': 'select',
      'proxies': <String>['node-12', 'node-34', 'DIRECT'],
      'default-selected': 'node-34',
    };
    final List<String> rules = <String>['MATCH,主节点'];
    final Map<String, dynamic> config = <String, dynamic>{
      'mode': 'rule',
      'mixed-port': 10203,
      'proxies': proxies,
      'proxy-groups': <Map<String, dynamic>>[businessGroup],
      'rules': rules,
      'listeners': const <Map<String, dynamic>>[],
    };

    SpeedProbeConfig.applyTo(config, 10203, 'session-secret');

    expect(config['mode'], 'rule');
    expect(config['mixed-port'], 10203);
    expect(config['proxies'], same(proxies));
    expect(config['rules'], same(rules));
    final List<Object?> groups = config['proxy-groups'] as List<Object?>;
    expect(groups.first, same(businessGroup));
    expect(groups.last, <String, dynamic>{
      'name': SpeedProbeConfig.groupName,
      'type': 'select',
      'hidden': true,
      'proxies': <String>['DIRECT', 'node-12', 'node-34'],
    });
    final List<String> parts = SpeedProbeConfig.credential('session-secret')
        .split(':');
    expect(config['listeners'], <Map<String, dynamic>>[
      <String, dynamic>{
        'name': SpeedProbeConfig.listenerName,
        'type': 'mixed',
        'listen': '127.0.0.1',
        'port': 10204,
        'udp': false,
        'users': <Map<String, String>>[
          <String, String>{'username': parts.first, 'password': parts.last},
        ],
        'proxy': SpeedProbeConfig.groupName,
      },
    ]);
  });

  test('测速入站口令随控制面 secret 变化且不暴露 secret 本身', () {
    const String secret = 'a3f1c7d9e5b20418';
    final String credential = SpeedProbeConfig.credential(secret);
    final String password = credential.split(':').last;

    expect(credential, startsWith('${SpeedProbeConfig.listenerName}:'));
    // 与内核侧实测用的派生值对齐（sha256("ecy-speed\0" + secret)）
    expect(
      password,
      'd83953b64b4d198cfbff00177787a131a64a0131f5898abfb858050a491d0c83',
    );
    expect(password, isNot(contains(secret)));
    expect(SpeedProbeConfig.credential(secret), credential);
    expect(SpeedProbeConfig.credential('${secret}0'), isNot(credential));
  });

  test('CONNECT 请求带上与落盘入站一致的代理口令', () {
    const String secret = 'b7c2';
    final String credential = SpeedProbeConfig.credential(secret);
    final String request = ascii.decode(
      NodeSpeedTester.connectRequest('speed.cloudflare.com', 443, credential),
    );

    expect(
      request,
      startsWith('CONNECT speed.cloudflare.com:443 HTTP/1.1\r\n'),
    );
    expect(
      request,
      contains(
        'Proxy-Authorization: Basic '
        '${base64.encode(utf8.encode(credential))}\r\n',
      ),
    );
    expect(request, endsWith('\r\n\r\n'));

    final Map<String, dynamic> config = <String, dynamic>{
      'proxies': <Map<String, dynamic>>[
        <String, dynamic>{'name': 'node-12', 'type': 'trojan'},
      ],
      'proxy-groups': const <Map<String, dynamic>>[],
    };
    SpeedProbeConfig.applyTo(config, 10203, secret);
    final Map<String, dynamic> user =
        ((config['listeners'] as List).single as Map<String, dynamic>)['users']
                .single
            as Map<String, dynamic>;
    expect('${user['username']}:${user['password']}', credential);
  });

  test('测速入站拒绝口令时报出代理状态码，不当成测速成功', () async {
    final List<String> seenAuth = <String>[];
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final StreamSubscription<Socket> sub = server.listen((Socket socket) {
      final List<int> buffer = <int>[];
      socket.listen((List<int> chunk) {
        buffer.addAll(chunk);
        if (NodeSpeedTester.indexOfHeaderEnd(buffer) < 0) {
          return;
        }
        final String head = ascii.decode(buffer, allowInvalid: true);
        for (final String line in head.split('\r\n')) {
          if (line.toLowerCase().startsWith('proxy-authorization:')) {
            seenAuth.add(line.split(' ').last);
          }
        }
        socket.add(
          ascii.encode(
            'HTTP/1.1 407 Proxy Authentication Required\r\n'
            'Proxy-Authenticate: Basic realm="mihomo"\r\n\r\n',
          ),
        );
        socket.close();
      }, onError: (Object _, StackTrace _) => socket.close());
    });

    final String credential = SpeedProbeConfig.credential('wrong-session');
    try {
      await expectLater(
        NodeSpeedTester().download(
          proxyPort: server.port,
          credential: credential,
        ),
        throwsA(
          isA<NodeSpeedTestException>().having(
            (NodeSpeedTestException e) => e.message,
            'message',
            contains('407'),
          ),
        ),
      );
    } finally {
      await sub.cancel();
      await server.close();
    }

    expect(seenAuth, hasLength(1));
    expect(seenAuth.first, base64.encode(utf8.encode(credential)));
  });

  test('官方节点 id 只认 node-{数字}', () {
    expect(NodeLabels.officialId('node-12'), 12);
    expect(NodeLabels.officialId('DIRECT'), isNull);
    expect(NodeLabels.officialId('node-'), isNull);
    expect(NodeLabels.officialId('主节点'), isNull);
  });

  test('下载达到总时限时停止读取并返回速度，不读取已关闭的连接', () async {
    final SecurityContext serverContext = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(_testCertificate))
      ..usePrivateKeyBytes(utf8.encode(_testPrivateKey));
    final SecureServerSocket server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    final Future<RawSecureSocket> connecting = RawSecureSocket.connect(
      'localhost',
      server.port,
      context: SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(utf8.encode(_testCertificate)),
    );
    final SecureSocket peer = await server.first;
    final RawSecureSocket socket = await connecting;
    final _DownloadClock total = _DownloadClock();
    try {
      final Future<int> result = NodeSpeedTester.readDownload(
        socket,
        total,
        null,
      );
      peer.add(ascii.encode('HTTP/1.1 200 OK\r\n\r\n'));
      peer.add(Uint8List(NodeSpeedTester.minBytes * 2));
      await peer.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      total.elapsedTime = NodeSpeedTester.timeout;
      peer.add(<int>[0]);
      await peer.flush();
      expect(await result.timeout(const Duration(seconds: 1)), greaterThan(0));
    } finally {
      socket.close();
      peer.destroy();
      await server.close();
    }
  });
}

class _DownloadClock extends Stopwatch {
  Duration elapsedTime = Duration.zero;

  @override
  Duration get elapsed => elapsedTime;
}

const String _testCertificate = '''
-----BEGIN CERTIFICATE-----
MIIBSDCB76ADAgECAgh2VAJXQ7NgHDAKBggqhkjOPQQDAjAUMRIwEAYDVQQDEwls
b2NhbGhvc3QwIBcNMjAwMTAxMDAwMDAwWhgPMjEwMDAxMDEwMDAwMDBaMBQxEjAQ
BgNVBAMTCWxvY2FsaG9zdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABNTmWpHj
PzA1GEeKrKpgrjlgBP4mAm1rmgiT2lf+h2GwB5s2bdl5NM2C3TgsC6qDqVoYGsBA
eVA7urKMbMdaXu+jKTAnMBQGA1UdEQQNMAuCCWxvY2FsaG9zdDAPBgNVHRMBAf8E
BTADAQH/MAoGCCqGSM49BAMCA0gAMEUCIQDIiuCEpuZJ+5W6u5PLbzGUPYvJFRwM
lGShIhARJXElyQIgTsuuOwFn5Uxcabry/gZucunxQt0rJCcOG/cVPx6O+GY=
-----END CERTIFICATE-----
''';

const String _testPrivateKey = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgZ7z1HQQ5Midh8QrH
4Z6rBvgDgh4FHFWX49r/+/I7raGhRANCAATU5lqR4z8wNRhHiqyqYK45YAT+JgJt
a5oIk9pX/odhsAebNm3ZeTTNgt04LAuqg6laGBrAQHlQO7qyjGzHWl7v
-----END PRIVATE KEY-----
''';
