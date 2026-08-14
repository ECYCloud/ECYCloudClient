import 'dart:io';

List<String> defaultSystemProxyBypass(String platformId) =>
    switch (platformId) {
      'windows' => _windowsSystemProxyBypass,
      'macos' => _macosSystemProxyBypass,
      _ => _linuxSystemProxyBypass,
    };

const List<String> _windowsSystemProxyBypass = <String>[
  'localhost',
  '127.*',
  '10.*',
  '172.16.*',
  '172.17.*',
  '172.18.*',
  '172.19.*',
  '172.20.*',
  '172.21.*',
  '172.22.*',
  '172.23.*',
  '172.24.*',
  '172.25.*',
  '172.26.*',
  '172.27.*',
  '172.28.*',
  '172.29.*',
  '172.30.*',
  '172.31.*',
  '192.168.*',
  '169.254.*',
  '<local>',
];

const List<String> _macosSystemProxyBypass = <String>[
  '127.0.0.1',
  'localhost',
  '*.local',
  '10.0.0.0/8',
  '172.16.0.0/12',
  '192.168.0.0/16',
  '169.254.0.0/16',
];

const List<String> _linuxSystemProxyBypass = <String>[
  'localhost',
  '127.0.0.0/8',
  '10.0.0.0/8',
  '172.16.0.0/12',
  '192.168.0.0/16',
  '169.254.0.0/16',
  '::1',
  'fc00::/7',
  'fe80::/10',
];

List<String> appendUnique(List<String> base, List<String> extra) {
  final List<String> result = List<String>.of(base);
  for (final String item in extra) {
    final String value = item.trim();
    if (value.isNotEmpty && !result.contains(value)) {
      result.add(value);
    }
  }
  return result;
}

List<String> resolvedSystemProxyBypass(
  String platformId,
  List<String> custom,
) => appendUnique(defaultSystemProxyBypass(platformId), custom);

List<String> splitNetworkSegments(String raw) => raw
    .split(RegExp(r'[,;\n\r]+'))
    .map((String item) => item.trim())
    .where((String item) => item.isNotEmpty)
    .toList();

bool isIpCidr(String value) {
  final int slash = value.lastIndexOf('/');
  if (slash <= 0 || slash == value.length - 1) {
    return false;
  }
  final InternetAddress? address = InternetAddress.tryParse(
    value.substring(0, slash),
  );
  final int? prefix = int.tryParse(value.substring(slash + 1));
  if (address == null || prefix == null) {
    return false;
  }
  return switch (address.type) {
    InternetAddressType.IPv4 => prefix >= 0 && prefix <= 32,
    InternetAddressType.IPv6 => prefix >= 0 && prefix <= 128,
    _ => false,
  };
}
