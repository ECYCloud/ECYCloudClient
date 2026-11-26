import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ecycloud_client/domain/kernel/kernel_controller.dart';
import 'package:ecycloud_client/domain/config/local_template.dart';
import 'package:ecycloud_client/platform/service/service_kernel_controller.dart';
import 'package:ecycloud_client/platform/service/service_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final bool failed in <bool>[false, true]) {
    test('专用清理命令必须传播失败：失败=$failed', () async {
      final _Transport transport = _Transport()..clearFails = failed;
      final ServiceKernelController kernel = ServiceKernelController(
        transport: transport,
      );
      addTearDown(kernel.dispose);
      await kernel.start(configJson: '{}', clashApi: _options);
      if (failed) {
        await expectLater(
          kernel.clearSession(_key),
          throwsA(isA<KernelException>()),
        );
        expect(kernel.status.state, KernelState.failed);
      } else {
        await kernel.clearSession(_key);
        expect(transport.clearedKey, _key, reason: '特权侧据此删掉该账号目录里带节点凭据的配置');
        expect(kernel.status.state, KernelState.stopped);
        expect(kernel.clashApi, isNull);
        expect(kernel.cacheReady, isFalse);
      }
      transport.status.complete(_running);
      await Future<void>.delayed(Duration.zero);
      expect(kernel.status.running, isFalse);
    });
  }

  test('后台服务暂不可用时配置校验抛出可重试错误而非配置错误', () async {
    final _Transport transport = _Transport()..checkFails = true;
    final ServiceKernelController kernel = ServiceKernelController(
      transport: transport,
    );
    addTearDown(kernel.dispose);
    await expectLater(
      kernel.validate('{}'),
      throwsA(
        isA<KernelException>().having(
          (KernelException e) => e.message,
          'message',
          allOf(contains('后台服务暂不可用'), isNot(contains('配置校验未通过'))),
        ),
      ),
    );
  });

  for (final bool failed in <bool>[false, true]) {
    test('停止后丢弃旧状态请求：失败=$failed', () async {
      final _Transport transport = _Transport();
      final ServiceKernelController kernel = ServiceKernelController(
        transport: transport,
      );
      addTearDown(kernel.dispose);
      final List<String> logs = <String>[];
      final StreamSubscription<String> subscription = kernel.kernelLog.listen(
        logs.add,
      );
      addTearDown(subscription.cancel);
      await kernel.start(configJson: '{}', clashApi: _options);
      await kernel.stop();
      if (failed) {
        transport.status.completeError(ServiceException('旧请求失败'));
      } else {
        transport.status.complete(_running);
      }
      await Future<void>.delayed(Duration.zero);
      expect(kernel.status.state, KernelState.stopped);
      expect(logs, <String>[_bound]);
    });
  }

  for (final bool readingConfig in <bool>[false, true]) {
    test('停止后不能完成旧内核接管：已读状态=$readingConfig', () async {
      final _Transport transport = _Transport();
      final ServiceKernelController kernel = ServiceKernelController(
        transport: transport,
      );
      addTearDown(kernel.dispose);
      if (readingConfig) transport.status.complete(_running);
      final Future<ClashApiOptions?> attach = kernel.attach();
      if (readingConfig) await transport.readStarted.future;
      await kernel.stop();
      if (!readingConfig) transport.status.complete(_running);
      transport.config.complete(<String, dynamic>{
        'content': jsonEncode(<String, dynamic>{
          'external-controller': '127.0.0.1:4567',
          'secret': 'old-test-secret',
        }),
      });
      expect(await attach, isNull);
      expect(kernel.clashApi, isNull);
      expect(kernel.status.state, KernelState.stopped);
    });
  }

  // 修复前：开机自启、磁贴等原生入口正在拉起隧道时状态是「未运行」，认回直接放弃
  test('原生入口正在拉起隧道时等它起来再认回', () async {
    final _Transport transport = _Transport()
      ..statusReplies.addAll(<Map<String, dynamic>>[
        <String, dynamic>{'running': false, 'starting': true, 'log_cursor': 0},
        <String, dynamic>{'running': false, 'starting': true, 'log_cursor': 0},
      ]);
    transport.status.complete(_running);
    transport.config.complete(<String, dynamic>{
      'content': jsonEncode(<String, dynamic>{
        'external-controller': '127.0.0.1:4567',
        'secret': 'native-test-secret',
      }),
    });
    final ServiceKernelController kernel = ServiceKernelController(
      transport: transport,
    );
    addTearDown(kernel.dispose);
    final ClashApiOptions? live = await kernel.attach().timeout(
      const Duration(seconds: 5),
    );
    expect(live?.port, 4567);
    expect(live?.secret, 'native-test-secret');
    expect(kernel.status.state, KernelState.running);
  });

  test('新会话启动后旧轮询错误不能将其标记失败', () async {
    final _Transport transport = _Transport();
    final ServiceKernelController kernel = ServiceKernelController(
      transport: transport,
    );
    addTearDown(kernel.dispose);
    await kernel.start(configJson: '{}', clashApi: _options);
    final Completer<Map<String, dynamic>> old = transport.status;
    await kernel.stop();
    transport.status = Completer<Map<String, dynamic>>();
    await kernel.start(configJson: '{}', clashApi: _options);
    old.completeError(ServiceException('旧轮询失败'));
    await Future<void>.delayed(Duration.zero);
    expect(kernel.status.state, KernelState.starting);
    expect(kernel.clashApi, same(_options));
    transport.status.complete(_running);
  });

  test('状态查询偶发失败不得立刻拆掉在跑的内核', () async {
    final _Transport transport = _Transport();
    final ServiceKernelController kernel = ServiceKernelController(
      transport: transport,
    );
    addTearDown(kernel.dispose);
    await kernel.start(configJson: '{}', clashApi: _options);
    transport.status.completeError(ServiceException('套接字暂时不可达'));

    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(kernel.status.state, KernelState.starting);

    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(kernel.status.state, KernelState.failed);
  });

  test('状态查询恢复后失败计数归零', () async {
    final _Transport transport = _Transport();
    final ServiceKernelController kernel = ServiceKernelController(
      transport: transport,
    );
    addTearDown(kernel.dispose);
    await kernel.start(configJson: '{}', clashApi: _options);
    transport.status.completeError(ServiceException('套接字暂时不可达'));

    await Future<void>.delayed(const Duration(milliseconds: 1200));
    transport.status = Completer<Map<String, dynamic>>()..complete(_running);

    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(kernel.status.state, KernelState.running);
  });

  test('停止命令失败不能伪装成已停止，也不能推成崩溃触发自动重启', () async {
    final _Transport transport = _Transport()..stopFails = true;
    final ServiceKernelController kernel = ServiceKernelController(
      transport: transport,
    );
    addTearDown(kernel.dispose);
    await kernel.start(configJson: '{}', clashApi: _options);
    final KernelState before = kernel.status.state;

    await expectLater(kernel.stop(), throwsA(isA<KernelException>()));
    expect(kernel.status.state, before);
    expect(kernel.status.state, isNot(KernelState.failed));
    expect(kernel.status.state, isNot(KernelState.stopped));
  });

  test('与后台服务失联后停止失败不再推一遍 failed', () async {
    final _Transport transport = _Transport()..stopFails = true;
    final ServiceKernelController kernel = ServiceKernelController(
      transport: transport,
    );
    addTearDown(kernel.dispose);
    final List<KernelState> states = <KernelState>[];
    final StreamSubscription<KernelStatus> subscription = kernel.statusStream
        .listen((KernelStatus status) => states.add(status.state));
    addTearDown(subscription.cancel);
    await kernel.start(configJson: '{}', clashApi: _options);
    transport.status.completeError(ServiceException('套接字暂时不可达'));
    await Future<void>.delayed(const Duration(milliseconds: 3700));
    expect(kernel.status.state, KernelState.failed);

    await expectLater(kernel.stop(), throwsA(isA<KernelException>()));
    await Future<void>.delayed(Duration.zero);
    expect(kernel.status.state, KernelState.failed);
    expect(
      states.where((KernelState state) => state == KernelState.failed),
      hasLength(1),
      reason: '上层放弃重试后的拆除会调 stop()，再收到 failed 就又进一次重启调度',
    );
  });

  test('停止后迟到的启动响应不能恢复控制面和轮询', () async {
    final _Transport transport = _Transport()
      ..startWait = Completer<Map<String, dynamic>>();
    final ServiceKernelController kernel = ServiceKernelController(
      transport: transport,
    );
    addTearDown(kernel.dispose);
    final Future<void> start = kernel.start(
      configJson: '{}',
      clashApi: _options,
    );
    await transport.startRequested.future;
    await kernel.stop();
    transport.startWait!.complete(<String, dynamic>{});
    await start;
    expect(kernel.status.state, KernelState.stopped);
    expect(kernel.clashApi, isNull);
    expect(transport.statusCalls, 0);
  });

  test('正常启动仍接收运行状态和日志', () async {
    final _Transport transport = _Transport();
    final ServiceKernelController kernel = ServiceKernelController(
      transport: transport,
    );
    addTearDown(kernel.dispose);
    final List<String> logs = <String>[];
    final StreamSubscription<String> subscription = kernel.kernelLog.listen(
      logs.add,
    );
    addTearDown(subscription.cancel);
    await kernel.start(configJson: '{}', clashApi: _options);
    transport.status.complete(_running);
    await Future<void>.delayed(Duration.zero);
    expect(kernel.status.state, KernelState.running);
    expect(logs, <String>[_bound, 'INFO old-private.test']);
    await kernel.stop();
  });

  // 端口被本机其它进程抢先占住时内核照常运行，只有它自己的输出能说明控制面没起来；
  // 此时不能返回成功，否则随后带 secret 的请求与热载的整份配置都会发给占位者
  test('控制面端口被抢占时启动失败且不进入轮询', () async {
    final _Transport transport = _Transport()
      ..bindLines = <String>[
        'time="2026-10-30T12:00:00.000000000+08:00" level=error msg="External controller listen error: listen tcp 127.0.0.1:4567: bind: address already in use"',
      ];
    final ServiceKernelController kernel = ServiceKernelController(
      transport: transport,
    );
    addTearDown(kernel.dispose);
    await expectLater(
      kernel.start(configJson: '{}', clashApi: _options),
      throwsA(
        isA<KernelException>().having(
          (KernelException e) => e.message,
          'message',
          contains('4567'),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(transport.statusCalls, 0);
  });

  test('其它端口或连接日志里的监听字样不算控制面就绪', () async {
    final _Transport transport = _Transport()
      ..bindLines = <String>[
        'time="2026-10-30T12:00:00.000000000+08:00" level=info msg="RESTful API listening at: 127.0.0.1:45670"',
        'time="2026-10-30T12:00:00.000000000+08:00" level=info msg="[TCP] 127.0.0.1:50000 --> RESTful API listening at: 127.0.0.1:4567 match Match using DIRECT"',
      ]
      ..bindRunning = false;
    final ServiceKernelController kernel = ServiceKernelController(
      transport: transport,
    );
    addTearDown(kernel.dispose);
    await expectLater(
      kernel.start(configJson: '{}', clashApi: _options),
      throwsA(isA<KernelException>()),
    );
    expect(kernel.status.state, KernelState.failed);
    expect(transport.statusCalls, 0);
  });

  for (final bool failed in <bool>[false, true]) {
    test('界面不向控制面发关 TUN 请求，升级失败后恢复轮询：失败=$failed', () async {
      final HttpOverrides? overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = overrides);
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      final List<String> controlRequests = <String>[];
      server.listen((HttpRequest request) async {
        controlRequests.add('${request.method} ${request.uri.path}');
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      });
      final _Transport transport = _Transport()
        ..upgradeWait = Completer<Map<String, dynamic>>()
        ..bindLines = <String>[
          'level=info msg="RESTful API listening at: 127.0.0.1:${server.port}"',
        ];
      final ServiceKernelController kernel = ServiceKernelController(
        transport: transport,
      );
      addTearDown(kernel.dispose);
      final ClashApiOptions options = ClashApiOptions(
        port: server.port,
        secret: 'test-secret',
      );
      await kernel.start(configJson: '{}', clashApi: options);
      transport.status.complete(_running);
      await Future<void>.delayed(Duration.zero);
      expect(kernel.status.state, KernelState.running);
      final int polls = transport.statusCalls;

      final Future<String> upgrade = kernel.upgrade('1.2.3', proxyPort: 7890);
      await transport.upgradeRequested.future;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(controlRequests, isEmpty, reason: '下载期间 TUN 必须保持接管');
      expect(transport.commands, isNot(contains('kernel.stop')));

      if (failed) {
        transport.upgradeWait!.completeError(ServiceException('下载内核失败'));
        await expectLater(upgrade, throwsA(isA<KernelException>()));
        await Future<void>.delayed(Duration.zero);
        expect(kernel.status.state, KernelState.running);
        expect(kernel.clashApi, isNotNull);
        expect(transport.statusCalls, greaterThan(polls));
      } else {
        transport.upgradeWait!.complete(<String, dynamic>{'version': '1.2.3'});
        expect(await upgrade, '1.2.3');
        expect(kernel.status.state, KernelState.stopped);
        expect(transport.statusCalls, polls);
      }
      expect(transport.commands, isNot(contains('kernel.stop')));

      await kernel.start(configJson: '{}', clashApi: options);
      await kernel.stop();
      await kernel.clearSession(_key);
      expect(controlRequests, isEmpty, reason: '关 TUN 由特权服务在停内核前统一处理');
    });
  }

  test('Android 同进程内核由封装模块确认控制面，不等特权侧日志', () async {
    final _Transport transport = _Transport()..bindLines = <String>[];
    final ServiceKernelController kernel = ServiceKernelController(
      transport: transport,
      logFromClashApi: true,
    );
    addTearDown(kernel.dispose);
    await kernel
        .start(configJson: '{}', clashApi: _options)
        .timeout(const Duration(seconds: 2));
    expect(kernel.clashApi, same(_options));
    await kernel.stop();
  });
}

const String _bound =
    'time="2026-10-30T12:00:00.000000000+08:00" level=info msg="RESTful API listening at: 127.0.0.1:4567"';

const ClashApiOptions _options = ClashApiOptions(
  port: 4567,
  secret: 'test-secret',
);
const Map<String, dynamic> _running = <String, dynamic>{
  'running': true,
  'pid': 12,
  'log_lines': <String>['INFO old-private.test'],
  'log_cursor': 1,
};

final String _key = 'a' * 64;

class _Transport implements ServiceTransport {
  Completer<Map<String, dynamic>> status = Completer<Map<String, dynamic>>();
  final Completer<Map<String, dynamic>> config =
      Completer<Map<String, dynamic>>();
  final Completer<void> readStarted = Completer<void>();
  final Completer<void> startRequested = Completer<void>();
  Completer<Map<String, dynamic>>? startWait;
  final List<Map<String, dynamic>> statusReplies = <Map<String, dynamic>>[];
  int statusCalls = 0;
  int bindChecks = 0;
  bool binding = false;
  bool bindRunning = true;
  List<String> bindLines = <String>[_bound];
  bool clearFails = false;
  String? clearedKey;
  bool stopFails = false;
  bool checkFails = false;
  Completer<Map<String, dynamic>>? upgradeWait;
  final Completer<void> upgradeRequested = Completer<void>();
  final List<String> commands = <String>[];

  @override
  Future<Map<String, dynamic>> request(
    String command, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    commands.add(command);
    switch (command) {
      case 'kernel.upgrade':
        upgradeRequested.complete();
        return upgradeWait!.future;
      case 'kernel.stop':
        if (stopFails) throw ServiceException('测试停止失败');
        return <String, dynamic>{};
      case 'kernel.clear':
        clearedKey = payload['cache_key'] as String?;
        if (clearFails) throw ServiceException('测试清理失败');
        return <String, dynamic>{};
      case 'kernel.check':
        if (checkFails) throw ServiceException('测试服务未运行');
        return <String, dynamic>{'valid': true};
      case 'kernel.status':
        if (binding) {
          binding = false;
          bindChecks++;
          return <String, dynamic>{
            'running': bindRunning,
            'log_lines': bindLines,
            'log_cursor': bindLines.length,
          };
        }
        statusCalls++;
        if (statusReplies.isNotEmpty) return statusReplies.removeAt(0);
        return status.future;
      case 'kernel.read':
        if (!readStarted.isCompleted) readStarted.complete();
        return config.future;
      case 'kernel.start':
        if (!startRequested.isCompleted) startRequested.complete();
        binding = true;
        return startWait?.future ?? <String, dynamic>{};
      default:
        return <String, dynamic>{};
    }
  }
}
