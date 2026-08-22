import '../config/local_template.dart';

enum KernelState { stopped, starting, running, stopping, failed }

class KernelStatus {
  const KernelStatus({
    required this.state,
    this.pid,
    this.exitCode,
    this.message,
    this.retriable = true,
    this.stoppedByUser = false,
  });

  const KernelStatus.stopped() : this(state: KernelState.stopped);

  final KernelState state;
  final int? pid;
  final int? exitCode;
  final String? message;

  // failed 时是否值得自动重启。被系统主动终止（Android 的 VPN 授权被别的应用
  // 接管）与内核崩溃要求的行为相反，重试等于去抢回槽位
  final bool retriable;

  // 用户在界面之外停掉了内核（Android 通知栏磁贴）。既不是崩溃也不是本进程
  // 下的指令，界面要跟着收回连接状态，自动重连则等于不让人关
  final bool stoppedByUser;

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

  bool get cacheReady;

  bool get upgradable;

  Future<String> kernelVersion();

  Future<String> upgrade(String version, {int? proxyPort});

  Future<({String stage, int percent})> upgradeProgress();

  Future<List<String>> preflight();

  Future<ClashApiOptions?> attach();

  DateTime? get startedAt;

  Future<void> start({
    required String configJson,
    required ClashApiOptions clashApi,
  });

  Future<void> stop();

  Future<void> persistConfig(String configJson);

  Future<void> reloadConfig(String configJson);

  /// 桌面 run 目录对 GUI 不可读，须经特权侧代读；禁止 `..` 与绝对路径
  Future<String> readRunFile(String relativePath);

  Future<String?> validate(String configJson);

  Stream<String> get kernelLog;

  Future<void> dispose();
}
