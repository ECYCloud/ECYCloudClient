import 'dart:convert';
import 'dart:io';

import 'package:ecycloud_client/data/store/panel_response_cache.dart';
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:ecycloud_client/domain/config/local_template.dart';
import 'package:ecycloud_client/domain/kernel/kernel_controller.dart';
import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/platform/linux/linux_platform_service.dart';
import 'package:ecycloud_client/platform/macos/macos_platform_service.dart';
import 'package:ecycloud_client/platform/unix/helper_client.dart';
import 'package:ecycloud_client/state/connection_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TUN 策略路由守护', () {
    test('规则被外部清掉时关一次再开 TUN 并恢复', () async {
      final _Kernel kernel = await _Kernel.launch();
      final _Platform platform = _Platform(<bool?>[false, true]);
      final ConnectionController connection = await _connect(kernel, platform);

      await connection.runGuards();

      expect(kernel.tunPatches, <bool>[false, true]);
      expect(platform.checks, 2);
      expect(connection.state, ConnectionPhase.connected);
    });

    test('判定不了时什么都不做', () async {
      final _Kernel kernel = await _Kernel.launch();
      final _Platform platform = _Platform(<bool?>[null]);
      final ConnectionController connection = await _connect(kernel, platform);

      await connection.runGuards();

      expect(platform.checks, 1);
      expect(kernel.tunPatches, isEmpty);
      expect(connection.state, ConnectionPhase.connected);
    });

    test('规则完好时不动', () async {
      final _Kernel kernel = await _Kernel.launch();
      final _Platform platform = _Platform(<bool?>[true]);
      final ConnectionController connection = await _connect(kernel, platform);

      await connection.runGuards();

      expect(kernel.tunPatches, isEmpty);
    });

    test('未开 TUN 时不检查', () async {
      final _Kernel kernel = await _Kernel.launch(tunEnabled: false);
      final _Platform platform = _Platform(<bool?>[false]);
      final ConnectionController connection = await _connect(
        kernel,
        platform,
        tunEnabled: false,
        takeover: true,
      );
      expect(connection.state, ConnectionPhase.connected);

      await connection.runGuards();

      expect(platform.checks, 0);
      expect(kernel.tunPatches, isEmpty);
    });

    test('未接管（常驻内核）时不检查', () async {
      final _Kernel kernel = await _Kernel.launch(tunEnabled: false);
      final _Platform platform = _Platform(<bool?>[false]);
      final ConnectionController connection = await _connect(kernel, platform);
      expect(connection.state, ConnectionPhase.disconnected);

      await connection.runGuards();

      expect(platform.checks, 0);
      expect(kernel.tunPatches, isEmpty);
    });

    test('重开后规则仍缺：交给重启调度，之后不再反复重开', () async {
      final _Kernel kernel = await _Kernel.launch();
      final _Platform platform = _Platform(<bool?>[false, false, false]);
      final ConnectionController connection = await _connect(kernel, platform);

      await connection.runGuards();
      expect(kernel.tunPatches, <bool>[false, true]);
      expect(connection.state, ConnectionPhase.connecting);
      expect(connection.error, contains('TUN'));

      await connection.runGuards();
      expect(kernel.tunPatches, <bool>[false, true]);
      expect(platform.checks, 2);
    });

    test('补回没撑到下次检查：不再关开 TUN，交给重启调度', () async {
      final _Kernel kernel = await _Kernel.launch();
      final _Platform platform = _Platform(<bool?>[false, true, false]);
      final ConnectionController connection = await _connect(kernel, platform);

      await connection.runGuards();
      expect(connection.state, ConnectionPhase.connected);

      await connection.runGuards();
      expect(kernel.tunPatches, <bool>[false, true]);
      expect(connection.state, ConnectionPhase.connecting);
      expect(connection.error, contains('TUN'));
    });

    test('重启后同一故障仍在：收手报错，不再重启', () async {
      final _Kernel kernel = await _Kernel.launch();
      final _Platform platform = _Platform(<bool?>[false, false, false, false]);
      final ConnectionController connection = await _connect(kernel, platform);

      await connection.runGuards();
      expect(connection.state, ConnectionPhase.connecting);
      // 等第一次退避（1 秒）的重启跑完，再认回仍在运行的内核，模拟重启成功后规则又缺
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await connection.adoptRunningKernel();
      expect(connection.state, ConnectionPhase.connected);

      await connection.runGuards();
      expect(kernel.tunPatches, <bool>[false, true]);
      expect(connection.state, ConnectionPhase.failed);

      await connection.runGuards();
      expect(kernel.tunPatches, hasLength(2));
      expect(platform.checks, 3);
    });

    test('重开后内核没接管：交给重启调度', () async {
      final _Kernel kernel = (await _Kernel.launch())..refuseEnable = true;
      final _Platform platform = _Platform(<bool?>[false, false]);
      final ConnectionController connection = await _connect(kernel, platform);

      await connection.runGuards();

      expect(kernel.tunPatches, <bool>[false, true]);
      expect(platform.checks, 1);
      expect(connection.state, ConnectionPhase.connecting);
    });
  });

  group('Linux 读取策略路由', () {
    const String intact4 =
        '0:\tfrom all lookup 255\n'
        '9000:\tfrom all to 198.18.0.0/30 lookup 2022\n'
        '9001:\tfrom all iif ECYCloud goto 9010\n'
        '9002:\tnot from all iif lo lookup 2022\n'
        '32766:\tfrom all lookup 254\n';
    const String wiped4 =
        '0:\tfrom all lookup 255\n'
        '9001:\tfrom all iif ECYCloud goto 9010 [unresolved]\n'
        '32766:\tfrom all lookup 254\n'
        '32767:\tfrom all lookup 253\n';

    test('有指向 TUN 路由表的规则即完好', () async {
      final _Ip ip = _Ip(<String, ProcessResult>{'-4': _ok(intact4)});
      expect(
        await LinuxPlatformService(run: ip.run)
            .tunRoutesIntact(tableIndex: null),
        isTrue,
      );
      expect(ip.calls.single.sublist(1), <String>['-4', '-N', 'rule', 'show']);
    });

    test('规则被清掉即缺失', () async {
      final _Ip ip = _Ip(<String, ProcessResult>{'-4': _ok(wiped4)});
      expect(
        await LinuxPlatformService(run: ip.run)
            .tunRoutesIntact(tableIndex: null),
        isFalse,
      );
    });

    test('按配置的路由表号判断，不把相近的表号当成命中', () async {
      final _Ip ip = _Ip(<String, ProcessResult>{
        '-4': _ok('0:\tfrom all lookup 255\n9000:\tfrom all lookup 20221\n'),
      });
      final LinuxPlatformService service = LinuxPlatformService(run: ip.run);
      expect(await service.tunRoutesIntact(tableIndex: null), isFalse);
      expect(await service.tunRoutesIntact(tableIndex: 20221), isTrue);
    });

    test('只看 IPv4 规则：IPv6 那组按本机是否有全局 IPv6 才建，不能拿来判缺失', () async {
      final _Ip ip = _Ip(<String, ProcessResult>{'-4': _ok(intact4)});
      expect(
        await LinuxPlatformService(run: ip.run)
            .tunRoutesIntact(tableIndex: null),
        isTrue,
      );
      expect(ip.calls.map((List<String> call) => call[1]), <String>['-4']);
    });

    for (final (String name, ProcessResult result) in <(String, ProcessResult)>[
      ('命令失败', ProcessResult(0, 255, '', 'Option "-N" is unknown')),
      ('输出看不懂', _ok('RTNETLINK answers: Operation not permitted\n')),
      ('输出为空', _ok('')),
    ]) {
      test('$name时判定未知', () async {
        final _Ip ip = _Ip(<String, ProcessResult>{'-4': result});
        expect(
          await LinuxPlatformService(run: ip.run)
              .tunRoutesIntact(tableIndex: null),
          isNull,
        );
      });
    }

    test('找不到 ip 命令时判定未知', () async {
      expect(
        await LinuxPlatformService(
          run: (String executable, List<String> arguments) =>
              throw ProcessException(executable, arguments, 'not found', 2),
        ).tunRoutesIntact(tableIndex: null),
        isNull,
      );
    });

    test('非 Linux 平台不执行任何命令、判定未知', () async {
      expect(
        await MacosPlatformService(
          const HelperClient('/nonexistent/helper.sock', 'test'),
        ).tunRoutesIntact(tableIndex: null),
        isNull,
      );
    });
  });
}

Future<ConnectionController> _connect(
  _Kernel kernel,
  _Platform platform, {
  bool tunEnabled = true,
  bool takeover = false,
}) async {
  final ConnectionController connection = ConnectionController(
    platform: platform,
    kernel: kernel,
    settingsStore: _Settings(tunEnabled),
    panelCache: PanelResponseCache(),
  );
  addTearDown(connection.dispose);
  await connection.adoptRunningKernel(takeover: takeover);
  return connection;
}

ProcessResult _ok(String stdout) => ProcessResult(0, 0, stdout, '');

class _Ip {
  _Ip(this.byFamily);

  final Map<String, ProcessResult> byFamily;
  final List<List<String>> calls = <List<String>>[];

  Future<ProcessResult> run(String executable, List<String> arguments) async {
    calls.add(<String>[executable, ...arguments]);
    return byFamily[arguments.first]!;
  }
}

class _Settings extends SettingsStore {
  _Settings(this.tunEnabled);

  final bool tunEnabled;

  @override
  AppSettings load() => const AppSettings.defaults().copyWith(
    tunEnabled: tunEnabled,
    systemProxyEnabled: false,
  );

  @override
  void save(AppSettings settings) {}
}

class _Kernel implements KernelController {
  _Kernel._(this._server, {required bool tunEnabled}) : _tun = tunEnabled {
    _server.listen(_handle);
  }

  static Future<_Kernel> launch({bool tunEnabled = true}) async {
    final HttpOverrides? overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    return _Kernel._(server, tunEnabled: tunEnabled);
  }

  final HttpServer _server;
  final List<bool> tunPatches = <bool>[];
  bool refuseEnable = false;
  bool _tun;

  Future<void> _handle(HttpRequest request) async {
    if (request.method == 'PATCH' && request.uri.path == '/configs') {
      final Object? body = jsonDecode(await utf8.decodeStream(request));
      final Object? tun = body is Map ? body['tun'] : null;
      if (tun is Map && tun['enable'] is bool) {
        final bool enable = tun['enable'] as bool;
        tunPatches.add(enable);
        _tun = enable && !refuseEnable;
      }
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }
    request.response.write(
      jsonEncode(switch (request.uri.path) {
        '/configs' => <String, Object>{
          'mode': 'rule',
          'tun': <String, bool>{'enable': _tun},
          'mixed-port': 10203,
        },
        '/proxies' => <String, Object>{'proxies': <String, Object>{}},
        _ => <String, Object>{'version': 'test'},
      }),
    );
    await request.response.close();
  }

  @override
  Future<ClashApiOptions?> attach() async =>
      ClashApiOptions(port: _server.port, secret: 'test');
  @override
  Future<void> bindSession(String cacheKey) async {}
  @override
  Stream<KernelStatus> get statusStream => const Stream<KernelStatus>.empty();
  @override
  Stream<String> get kernelLog => const Stream<String>.empty();
  @override
  DateTime? get startedAt => null;
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<void> clearSession(String cacheKey) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Platform implements PlatformService {
  _Platform(this._results);

  final List<bool?> _results;
  int checks = 0;

  @override
  Future<bool?> tunRoutesIntact({required int? tableIndex}) async =>
      _results[checks++];

  @override
  String get platformId => 'linux';
  @override
  bool get supportsLaunchAtLogin => false;
  @override
  String get tunInterfaceName => 'ECYCloud';
  @override
  bool get tunSetsSystemDns => false;
  @override
  bool get strictRouteNeedsTunIPv6 => false;
  @override
  bool get lanNamesViaSystemDns => false;
  @override
  bool get supportsSystemProxy => false;
  @override
  bool get supportsTray => false;
  @override
  bool get requiresTun => false;
  @override
  Stream<TrayAction> get trayActions => const Stream<TrayAction>.empty();
  @override
  Future<void> restoreSystemProxy() async {}
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
