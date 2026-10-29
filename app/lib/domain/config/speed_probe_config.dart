import 'dart:convert';

import 'package:crypto/crypto.dart';

class SpeedProbeConfig {
  static const String listenerName = 'ecy-speed';
  static const String groupName = 'ecy-speed';

  static int portOf(int mixedPort) =>
      mixedPort < 65535 ? mixedPort + 1 : mixedPort - 1;

  // 派生方式必须与 NodeSpeedTester 发出的 Proxy-Authorization 保持一致，
  // 两侧只许经此函数取值
  static String credential(String secret) =>
      '$listenerName:${sha256.convert(utf8.encode('$listenerName\u0000$secret')).toString()}';

  static void applyTo(
    Map<String, dynamic> config,
    int mixedPort,
    String secret,
  ) {
    config['proxy-groups'] = <Object?>[
      ...config['proxy-groups'] as List,
      <String, dynamic>{
        'name': groupName,
        'type': 'select',
        'hidden': true,
        'proxies': <String>[
          'DIRECT',
          for (final Map proxy in (config['proxies'] as List).cast<Map>())
            proxy['name'] as String,
        ],
        if (config['proxy-providers'] is Map &&
            (config['proxy-providers'] as Map).containsKey('ecy-panel-nodes'))
          'use': <String>['ecy-panel-nodes'],
      },
    ];
    final List<String> parts = credential(secret).split(':');
    config['listeners'] = <Map<String, dynamic>>[
      <String, dynamic>{
        'name': listenerName,
        'type': 'mixed',
        'listen': '127.0.0.1',
        'port': portOf(mixedPort),
        'udp': false,
        // 这个入站界面上不存在却常驻回环，且 proxy 字段绕开 rules 与路由模式：
        // 桌面同机其它账号、Android 任一已安装应用都能连上，必须自带口令
        'users': <Map<String, String>>[
          <String, String>{'username': parts.first, 'password': parts.last},
        ],
        'proxy': groupName,
      },
    ];
  }
}
