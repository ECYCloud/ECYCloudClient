import '../config/local_template.dart';

enum KernelState { stopped, starting, running, stopping, failed }

class KernelStatus {
  const KernelStatus({
    required this.state,
    this.pid,
    this.exitCode,
    this.message,
  });

  const KernelStatus.stopped() : this(state: KernelState.stopped);

  final KernelState state;
  final int? pid;
  final int? exitCode;
  final String? message;

  bool get running => state == KernelState.running;
}

class KernelException implements Exception {
  KernelException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract class KernelController {
  Stream<KernelStatus> get statusStream;

  KernelStatus get status;

  ClashApiOptions? get clashApi;

  // 内核缓存是否已建立，false 表示本机尚未成功跑过内核、远程规则集需现下载
  bool get cacheReady;

  // 内核自报版本，取不到时为空字符串
  Future<String> kernelVersion();

  // 换成指定版本的官方发布内核，返回实际装上的版本。下载、校验与替换都在
  // 特权侧完成，替换前内核会被停掉，重连由调用方决定
  Future<String> upgrade(String version);

  // 返回环境问题描述，空列表表示可用
  Future<List<String>> preflight();

  Future<void> start({
    required String configJson,
    required ClashApiOptions clashApi,
  });

  Future<void> stop();

  // 返回配置错误描述，null 表示通过
  Future<String?> validate(String configJson);

  Stream<String> get kernelLog;

  Future<void> dispose();
}
