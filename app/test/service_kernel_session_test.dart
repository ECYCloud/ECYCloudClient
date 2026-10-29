import 'dart:async';
import 'dart:convert';

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
          kernel.clearSession(),
          throwsA(isA<KernelException>()),
        );
        expect(kernel.status.state, KernelState.failed);
      } else {
        await kernel.clearSession();
        expect(kernel.status.state, KernelState.stopped);
        expect(kernel.clashApi, isNull);
        expect(kernel.cacheReady, isFalse);
      }
      transport.status.complete(_running);
      await Future<void>.delayed(Duration.zero);
      expect(kernel.status.running, isFalse);
    });
  }

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
      expect(logs, isEmpty);
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

  test('停止命令失败不能伪装成已停止', () async {
    final _Transport transport = _Transport()..stopFails = true;
    final ServiceKernelController kernel = ServiceKernelController(
      transport: transport,
    );
    addTearDown(kernel.dispose);
    await kernel.start(configJson: '{}', clashApi: _options);

    await expectLater(kernel.stop(), throwsA(isA<KernelException>()));
    expect(kernel.status.state, KernelState.failed);
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
    expect(logs, <String>['INFO old-private.test']);
    await kernel.stop();
  });
}

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

class _Transport implements ServiceTransport {
  Completer<Map<String, dynamic>> status = Completer<Map<String, dynamic>>();
  final Completer<Map<String, dynamic>> config =
      Completer<Map<String, dynamic>>();
  final Completer<void> readStarted = Completer<void>();
  final Completer<void> startRequested = Completer<void>();
  Completer<Map<String, dynamic>>? startWait;
  int statusCalls = 0;
  bool clearFails = false;
  bool stopFails = false;

  @override
  Future<Map<String, dynamic>> request(
    String command, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    switch (command) {
      case 'kernel.stop':
        if (stopFails) throw ServiceException('测试停止失败');
        return <String, dynamic>{};
      case 'kernel.clear':
        if (clearFails) throw ServiceException('测试清理失败');
        return <String, dynamic>{};
      case 'kernel.status':
        statusCalls++;
        return status.future;
      case 'kernel.read':
        if (!readStarted.isCompleted) readStarted.complete();
        return config.future;
      case 'kernel.start':
        if (!startRequested.isCompleted) startRequested.complete();
        return startWait?.future ?? <String, dynamic>{};
      default:
        return <String, dynamic>{};
    }
  }
}
