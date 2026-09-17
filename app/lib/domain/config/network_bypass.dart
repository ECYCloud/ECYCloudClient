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

bool isIpAddress(String value) => InternetAddress.tryParse(value) != null;

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

final RegExp _hostLabel = RegExp(
  r'^(?:\*|[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)$',
);

bool isWildcardIpv4(String value) {
  final List<String> parts = value.split('.');
  if (parts.length < 2 || parts.length > 4) {
    return false;
  }
  bool star = false;
  for (final String part in parts) {
    if (part == '*') {
      star = true;
      continue;
    }
    final int? octet = int.tryParse(part);
    if (octet == null || octet < 0 || octet > 255) {
      return false;
    }
  }
  return star;
}

bool isHostnamePattern(String value) {
  if (value.isEmpty || value.length > 253) {
    return false;
  }
  final List<String> labels = value.split('.');
  // 至少两段：abc / 666 这种单词不是主机名或通配，*.local、example.com 才算
  return labels.length >= 2 &&
      labels.every(
        (String label) => label.isNotEmpty && _hostLabel.hasMatch(label),
      );
}

bool isSystemProxyBypass(String platformId, String value) {
  final String item = value.trim();
  if (item.isEmpty) {
    return false;
  }
  if (platformId == 'windows' && item == '<local>') {
    return true;
  }
  return isIpAddress(item) ||
      isIpCidr(item) ||
      isWildcardIpv4(item) ||
      isHostnamePattern(item);
}
