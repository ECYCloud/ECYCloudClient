import 'dart:convert';
import 'dart:io';

import '../../core/app_paths.dart';
import '../../domain/platform/platform_service.dart';
import '../unix/unix_platform_service.dart';

/// 系统代理是用户会话的设置（GSettings 走会话 D-Bus），以 root 运行的 helper
/// 改不到，因此这一项不下沉到特权侧，由 GUI 自己读写并快照。
class LinuxPlatformService extends UnixPlatformService {
  LinuxPlatformService();

  static const String _proxySchema = 'org.gnome.system.proxy';
  static const List<String> _bypass = <String>[
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

  static const List<(String, String)> _snapshotKeys = <(String, String)>[
    (_proxySchema, 'mode'),
    (_proxySchema, 'ignore-hosts'),
    ('$_proxySchema.http', 'host'),
    ('$_proxySchema.http', 'port'),
    ('$_proxySchema.https', 'host'),
    ('$_proxySchema.https', 'port'),
    ('$_proxySchema.socks', 'host'),
    ('$_proxySchema.socks', 'port'),
  ];

  @override
  String get platformId => 'linux';

  @override
  String get openCommand => 'xdg-open';

  @override
  Future<void> setSystemProxy({required int port}) async {
    // 已有快照说明上一次还没还原，保留最早的原值，不要用被自己改过的值覆盖
    if (!AppPaths.proxySnapshot.existsSync()) {
      final Map<String, String> snapshot = <String, String>{};
      for (final (String schema, String key) in _snapshotKeys) {
        snapshot['$schema $key'] = await _get(schema, key);
      }
      AppPaths.proxySnapshot.writeAsStringSync(jsonEncode(snapshot));
    }

    for (final String scheme in <String>['http', 'https', 'socks']) {
      await _set('$_proxySchema.$scheme', 'host', "'127.0.0.1'");
      await _set('$_proxySchema.$scheme', 'port', '$port');
    }
    await _set(
      _proxySchema,
      'ignore-hosts',
      '[${_bypass.map((String host) => "'$host'").join(', ')}]',
    );
    await _set(_proxySchema, 'mode', "'manual'");
  }

  @override
  Future<void> restoreSystemProxy() async {
    final File file = AppPaths.proxySnapshot;
    if (!file.existsSync()) {
      return;
    }

    final Object? decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map<String, dynamic>) {
      for (final MapEntry<String, dynamic> entry in decoded.entries) {
        final List<String> parts = entry.key.split(' ');
        if (parts.length == 2 && entry.value is String) {
          await _set(parts[0], parts[1], entry.value as String);
        }
      }
    }
    file.deleteSync();
  }

  @override
  Future<SystemProxyState> systemProxyState() async {
    final String mode = await _get(_proxySchema, 'mode');
    final String host = await _get('$_proxySchema.http', 'host');
    final String port = await _get('$_proxySchema.http', 'port');

    return SystemProxyState(
      enabled: _unquote(mode) == 'manual',
      server: _unquote(host).isEmpty ? '' : '${_unquote(host)}:$port',
      snapshotPresent: AppPaths.proxySnapshot.existsSync(),
    );
  }

  @override
  Future<bool> launchAtLoginEnabled() async => _autostartEntry.existsSync();

  @override
  Future<void> setLaunchAtLogin({required bool enabled}) async {
    final File entry = _autostartEntry;
    if (!enabled) {
      if (entry.existsSync()) {
        entry.deleteSync();
      }
      return;
    }

    entry.parent.createSync(recursive: true);
    entry.writeAsStringSync('''
[Desktop Entry]
Type=Application
Name=ECY Cloud
Exec="${Platform.resolvedExecutable}"
Icon=com.ecycloud.client
Terminal=false
X-GNOME-Autostart-enabled=true
''');
  }

  File get _autostartEntry {
    final String? xdg = Platform.environment['XDG_CONFIG_HOME'];
    final String base = xdg == null || xdg.isEmpty
        ? '${Platform.environment['HOME']}/.config'
        : xdg;
    return File('$base/autostart/com.ecycloud.client.desktop');
  }

  Future<String> _get(String schema, String key) async {
    final ProcessResult result = await Process.run('gsettings', <String>[
      'get',
      schema,
      key,
    ]);
    if (result.exitCode != 0) {
      throw PlatformServiceException(
        '读取 $schema $key 失败：${(result.stderr as String).trim()}',
      );
    }
    return (result.stdout as String).trim();
  }

  Future<void> _set(String schema, String key, String value) async {
    final ProcessResult result = await Process.run('gsettings', <String>[
      'set',
      schema,
      key,
      value,
    ]);
    if (result.exitCode != 0) {
      throw PlatformServiceException(
        '写入 $schema $key 失败：${(result.stderr as String).trim()}',
      );
    }
  }

  static String _unquote(String value) =>
      value.length >= 2 && value.startsWith("'") && value.endsWith("'")
      ? value.substring(1, value.length - 1)
      : value;
}
