class SpeedProbeConfig {
  static const String listenerName = 'ecy-speed';
  static const String groupName = 'ecy-speed';

  static int portOf(int mixedPort) =>
      mixedPort < 65535 ? mixedPort + 1 : mixedPort - 1;

  static void applyTo(Map<String, dynamic> config, int mixedPort) {
    config['proxy-groups'] = <Object?>[
      ...config['proxy-groups'] as List,
      <String, dynamic>{
        'name': groupName,
        'type': 'select',
        'hidden': true,
        'proxies': <String>[
          for (final Map proxy in (config['proxies'] as List).cast<Map>())
            proxy['name'] as String,
        ],
      },
    ];
    config['listeners'] = <Map<String, dynamic>>[
      <String, dynamic>{
        'name': listenerName,
        'type': 'mixed',
        'listen': '127.0.0.1',
        'port': portOf(mixedPort),
        'udp': false,
        'users': const <Map<String, String>>[],
        'proxy': groupName,
      },
    ];
  }
}
