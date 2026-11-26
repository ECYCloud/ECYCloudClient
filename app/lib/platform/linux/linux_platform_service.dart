import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/app_paths.dart';
import '../../core/logger.dart';
import '../../data/store/settings_store.dart';
import '../../domain/config/network_bypass.dart';
import '../../domain/platform/platform_service.dart';
import '../unix/unix_platform_service.dart';

/// 系统代理走会话 D-Bus，helper（root）改不到。
class LinuxPlatformService extends UnixPlatformService {
  LinuxPlatformService({this._run = Process.run, this._start = Process.start});

  final Future<ProcessResult> Function(String, List<String>) _run;
  final Future<Process> Function(String, List<String>, {ProcessStartMode mode})
  _start;
  Process? _proxyGuard;
  int? _proxyPort;

  static const String _proxySchema = 'org.gnome.system.proxy';

  // 与 sing-tun 的 DefaultIPRoute2TableIndex 一致：配置未写 tun.iproute2-table-index 时内核用它
  static const int _defaultTunTable = 2022;

  // 普通用户的 PATH 不一定含 sbin
  static const List<String> _ipCommands = <String>[
    '/usr/sbin/ip',
    '/sbin/ip',
    '/usr/bin/ip',
    '/bin/ip',
  ];

  static final RegExp _ruleLine = RegExp(r'^\d+:\s');

  // 界面进程不论怎么退出，系统都会关闭守护 stdin 的写端：读到 release 说明已正常还原，
  // 读到 EOF 才按快照还原，且只在代理仍是本客户端写的那组值时动手
  static const String _proxyGuardScript = r'''
exec >/dev/null 2>&1
IFS= read -r line
[ "$line" = release ] && exit 0
snapshot=$1 port=$2 schema=$3
shift 3
[ -f "$snapshot" ] || exit 0
[ "$(gsettings get "$schema" mode)" = "'manual'" ] || exit 0
[ "$(gsettings get "$schema.http" host)" = "'127.0.0.1'" ] || exit 0
[ "$(gsettings get "$schema.http" port)" = "$port" ] || exit 0
while [ $# -ge 3 ]; do
  gsettings set "$1" "$2" "$3"
  shift 3
done
rm -f "$snapshot"
''';

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
    await leftoverProxyRestore;
    final File file = AppPaths.proxySnapshot;
    // 已有快照说明上一次还没还原，保留最早的原值，不要用被自己改过的值覆盖
    if (!file.existsSync()) {
      final Map<String, String> snapshot = <String, String>{};
      for (final (String schema, String key) in _snapshotKeys) {
        snapshot['$schema $key'] = await _get(schema, key);
      }
      final File temporary = File('${file.path}.tmp')
        ..writeAsStringSync(jsonEncode(snapshot), flush: true);
      temporary.renameSync(file.path);
    }
    final Map<String, dynamic>? snapshot = _readSnapshot(file);
    if (snapshot != null) {
      await _guardProxy(file, port, snapshot);
    }

    _proxyPort = port;
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
    await restoreLeftoverProxy();
  }

  @override
  Future<bool> restoreLeftoverProxy() async {
    final File file = AppPaths.proxySnapshot;
    bool owned = true;
    if (file.existsSync()) {
      final Map<String, dynamic>? snapshot = _readSnapshot(file);
      // 与守护同一条件：代理已被别的程序改走时只丢弃快照，不覆盖别人的设置
      owned = await _ownsProxy();
      if (owned) {
        if (snapshot == null) {
          await _set(_proxySchema, 'mode', "'none'");
        } else {
          for (final (String schema, String key, String value) in _entries(
            snapshot,
          )) {
            await _set(schema, key, value);
          }
        }
      }
      file.deleteSync();
    }
    _proxyPort = null;
    _releaseProxyGuard();
    return owned;
  }

  static Iterable<(String, String, String)> _entries(
    Map<String, dynamic> snapshot,
  ) sync* {
    for (final MapEntry<String, dynamic> entry in snapshot.entries) {
      final List<String> parts = entry.key.split(' ');
      if (parts.length == 2 && entry.value is String) {
        yield (parts[0], parts[1], entry.value as String);
      }
    }
  }

  // detached 会 setsid：界面被强杀时守护不随进程组退出
  Future<void> _guardProxy(
    File snapshotFile,
    int port,
    Map<String, dynamic> snapshot,
  ) async {
    _releaseProxyGuard();
    try {
      _proxyGuard = await _start('/bin/sh', <String>[
        '-c',
        _proxyGuardScript,
        'ecycloud-proxy-guard',
        snapshotFile.path,
        '$port',
        _proxySchema,
        for (final (String schema, String key, String value) in _entries(
          snapshot,
        )) ...<String>[schema, key, value],
      ], mode: ProcessStartMode.detachedWithStdio);
    } on Object catch (e) {
      Logger.instance.warn(
        UnixPlatformService.source,
        '系统代理守护进程启动失败，客户端被强杀后要等下次打开才还原: $e',
      );
    }
  }

  void _releaseProxyGuard() {
    final Process? guard = _proxyGuard;
    _proxyGuard = null;
    if (guard == null) {
      return;
    }
    guard.stdin.writeln('release');
    unawaited(guard.stdin.close().then<void>((_) {}, onError: (Object _) {}));
  }

  static Map<String, dynamic>? _readSnapshot(File file) {
    try {
      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      Logger.instance.warn(UnixPlatformService.source, '系统代理快照格式无效，已丢弃');
    } on Object catch (e) {
      Logger.instance.warn(UnixPlatformService.source, '系统代理快照损坏，已丢弃：$e');
    }
    return null;
  }

  // 被强杀后重开时本进程没写过代理，按设置里的端口认领
  Future<bool> _ownsProxy() async =>
      await _get(_proxySchema, 'mode') == "'manual'" &&
      await _get('$_proxySchema.http', 'host') == "'127.0.0.1'" &&
      await _get('$_proxySchema.http', 'port') ==
          '${_proxyPort ?? SettingsStore().load().mixedPort}';

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
  Future<bool?> tunRoutesIntact({required int? tableIndex}) async {
    final String ip = _ipCommands.firstWhere(
      (String path) => File(path).existsSync(),
      orElse: () => 'ip',
    );
    final RegExp lookup = RegExp(
      '\\blookup ${tableIndex ?? _defaultTunTable}\\b',
    );
    // 只看 IPv4：IPv6 那组规则只在内核保留了 inet6-address 时才建，而这还取决于本机有没有全局 IPv6 地址
    final ProcessResult result;
    try {
      result = await _run(ip, <String>['-4', '-N', 'rule', 'show']);
    } on Object {
      return null;
    }
    if (result.exitCode != 0 || result.stdout is! String) {
      return null;
    }
    final List<String> rules = (result.stdout as String)
        .split('\n')
        .where(_ruleLine.hasMatch)
        .toList();
    if (rules.isEmpty) {
      return null;
    }
    return rules.any(lookup.hasMatch);
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
  Future<bool> secretStoreAvailable() async =>
      await UnixPlatformService.channel.invokeMethod<bool>(
        'secret.available',
      ) ==
      true;

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
    final ProcessResult result = await _run('gsettings', <String>[
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
    final ProcessResult result = await _run('gsettings', <String>[
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
