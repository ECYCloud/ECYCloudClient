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

  // 内核缓存是否已建立，false 表示本机尚未成功跑过内核、远程规则集需现下载
  bool get cacheReady;

  // 内核能否就地换版本。内嵌形态（Android 的 libmihomo）随客户端一起编译，只能整包更新
  bool get upgradable;

  // 内核自报版本，取不到时为空字符串
  Future<String> kernelVersion();

  // 换成指定版本的官方发布内核，返回实际装上的版本。下载、校验与替换都在
  // 特权侧完成，替换前内核会被停掉，重连由调用方决定
  Future<String> upgrade(String version);

  // 正在进行的内核升级进度；无任务时 stage 为空
  Future<({String stage, int percent})> upgradeProgress();

  // 返回环境问题描述，空列表表示可用
  Future<List<String>> preflight();

  /// 内核可能比界面活得久：Android 的 VpnService 在 Activity 销毁后继续跑隧道。
  /// 已在运行则接管它并返回其控制面参数（取自启动时落盘的配置），否则返回 null。
  Future<ClashApiOptions?> attach();

  /// 内核起来的时刻，由托管方上报。界面比内核起得晚时只有它知道连接建于何时；
  /// 内核不在或托管方不上报则为 null。
  DateTime? get startedAt;

  Future<void> start({
    required String configJson,
    required ClashApiOptions clashApi,
  });

  Future<void> stop();

  /// 只把配置写入运行目录的 `config.json`，不启停进程。
  /// 桌面端热载前必须落盘，保证 Android/桌面「界面晚于内核」接管时读到的仍是当前配置。
  Future<void> persistConfig(String configJson);

  /// Android 面板配置热载：保留 VpnService TUN fd，就地 ApplyConfig，不重建控制面。
  /// 桌面端请用 [ClashApiClient.applyConfigPayload]，不要调这个。
  Future<void> reloadConfig(String configJson);

  /// 读取运行目录下的相对路径文件（如 `config.json`、`ECYCloud-Rules/Google.yaml`）。
  /// 桌面 run 目录对 GUI 不可读，必须经特权侧代读；禁止 `..` 与绝对路径。
  Future<String> readRunFile(String relativePath);

  // 返回配置错误描述，null 表示通过
  Future<String?> validate(String configJson);

  Stream<String> get kernelLog;

  Future<void> dispose();
}
