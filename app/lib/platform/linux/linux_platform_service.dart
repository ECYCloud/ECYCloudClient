import 'dart:convert';
import 'dart:io';

import '../../core/app_paths.dart';
import '../../domain/config/network_bypass.dart';
import '../../domain/platform/platform_service.dart';
import '../unix/unix_platform_service.dart';

/// 系统代理走会话 D-Bus，helper（root）改不到。
class LinuxPlatformService extends UnixPlatformService {
  LinuxPlatformService();

  static const String _proxySchema = 'org.gnome.system.proxy';

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
  Future<void> setSystemProxy({
    required int port,
    required List<String> bypass,
  }) async {
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
    final List<String> hosts = bypass.isEmpty
        ? defaultSystemProxyBypass(platformId)
        : bypass;
    await _set(
      _proxySchema,
      'ignore-hosts',
      '[${hosts.map(_gsettingsString).join(', ')}]',
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
  Future<({String model, String os})> deviceProfile() async {
    final File release = File('/etc/os-release');
    if (!release.existsSync()) {
      return (model: 'Linux', os: '');
    }

    final Map<String, String> fields = <String, String>{};
    for (final String line in release.readAsLinesSync()) {
      final int split = line.indexOf('=');
      if (split > 0) {
        fields[line.substring(0, split)] = _unquoteRelease(
          line.substring(split + 1),
        );
      }
    }
    return (model: fields['NAME'] ?? 'Linux', os: fields['VERSION_ID'] ?? '');
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

  // gsettings 按 GVariant 解析，反斜杠与单引号各自加反斜杠，不能用 shell 的 '\''
  static String _gsettingsString(String value) =>
      "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";

  static String _unquoteRelease(String value) =>
      value.length >= 2 && value.startsWith('"') && value.endsWith('"')
      ? value.substring(1, value.length - 1)
      : value;

  static String _unquote(String value) =>
      value.length >= 2 && value.startsWith("'") && value.endsWith("'")
      ? value.substring(1, value.length - 1)
      : value;
}
