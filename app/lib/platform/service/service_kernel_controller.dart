import 'dart:async';
import 'dart:convert';

import '../../core/logger.dart';
import '../../domain/config/local_template.dart';
import '../../domain/kernel/clash_api_client.dart';
import '../../domain/kernel/kernel_controller.dart';
import 'service_transport.dart';

/// 内核托管在本进程之外（桌面端是特权服务，Android 是 VpnService），
/// 本类只下指令并轮询状态。四端共用，差别只在 [transport] 与 [tunProbeCommand]。
class ServiceKernelController implements KernelController {
  // 命名参数不能写成 this._field，只能在初始化列表里赋值
  // ignore_for_file: prefer_initializing_formals
  ServiceKernelController({
    required ServiceTransport transport,
    String? tunProbeCommand,
    bool upgradable = true,
    bool logFromClashApi = false,
  }) : _service = transport,
       _tunProbeCommand = tunProbeCommand,
       _upgradable = upgradable,
       _logFromClashApi = logFromClashApi;

  static const String _source = 'kernel';
  static const Duration _pollInterval = Duration(seconds: 1);

  final ServiceTransport _service;
  final String? _tunProbeCommand;
  final bool _upgradable;
  final bool _logFromClashApi;
  final StreamController<KernelStatus> _statusController =
      StreamController<KernelStatus>.broadcast();
  final StreamController<String> _logController =
      StreamController<String>.broadcast();

  Timer? _poller;
  ClashApiClient? _logClient;
  StreamSubscription<String>? _logSubscription;
  KernelStatus _status = const KernelStatus.stopped();
  ClashApiOptions? _clashApi;
  DateTime? _startedAt;
  bool _cacheReady = false;

  int _logCursor = 0;

  @override
  Stream<KernelStatus> get statusStream => _statusController.stream;

  @override
  KernelStatus get status => _status;

  @override
  ClashApiOptions? get clashApi => _clashApi;

  @override
  DateTime? get startedAt => _startedAt;

  @override
  Stream<String> get kernelLog => _logController.stream;

  @override
  bool get cacheReady => _cacheReady;

  @override
  bool get upgradable => _upgradable;

  @override
  Future<String> kernelVersion() async {
    try {
      final Map<String, dynamic> pong = await _service.request('ping');
      // 服务给的是 `mihomo -v` 的首行原文（Mihomo Meta v1.19.29 windows amd64 …）
      final String line = pong['kernel'] as String? ?? '';
      return RegExp(r'\d+(?:\.\d+)+\S*').firstMatch(line)?.group(0) ?? '';
    } on ServiceException catch (e) {
      Logger.instance.warn(_source, '取内核版本失败: $e');
      return '';
    }
  }

  @override
  Future<String> upgrade(String version) async {
    // 服务替换文件前会停内核，轮询留着只会把这次停机报成「内核异常退出」
    _stopPolling();

    try {
      final Map<String, dynamic> result = await _service.request(
        'kernel.upgrade',
        <String, dynamic>{'version': version},
      );
      _clashApi = null;
      _update(const KernelStatus.stopped());
      return result['version'] as String? ?? version;
    } on ServiceException catch (e) {
      throw KernelException('$e');
    }
  }

  @override
  Future<({String stage, int percent})> upgradeProgress() async {
    if (!_upgradable) {
      return (stage: '', percent: 0);
    }
    try {
      final Map<String, dynamic> result = await _service.request(
        'kernel.upgrade.progress',
      );
      return (
        stage: result['stage'] as String? ?? '',
        percent: (result['percent'] as num?)?.toInt() ?? 0,
      );
    } on ServiceException {
      return (stage: '', percent: 0);
    }
  }

  @override
  Future<List<String>> preflight() async {
    final List<String> problems = <String>[];

    try {
      final Map<String, dynamic> pong = await _service.request('ping');
      _cacheReady = pong['cache_ready'] == true;
    } on ServiceException catch (e) {
      problems.add('$e');
      return problems;
    }

    final String? probe = _tunProbeCommand;
    if (probe == null) {
      return problems;
    }

    try {
      final Map<String, dynamic> result = await _service.request(probe);
      if (result['ready'] != true) {
        final String reason = result['reason'] as String? ?? '未知原因';
        problems.add('TUN 模式不可用：$reason');
      }
    } on ServiceException catch (e) {
      problems.add('TUN 环境检查失败：$e');
    }

    return problems;
  }

  @override
  Future<ClashApiOptions?> attach() async {
    final Map<String, dynamic> result;
    try {
      result = await _service.request('kernel.status', <String, dynamic>{
        'log_cursor': _logCursor,
      });
    } on ServiceException catch (e) {
      Logger.instance.warn(_source, '查询内核状态失败: $e');
      return null;
    }

    if (result['running'] != true) {
      return null;
    }

    final ClashApiOptions? clashApi = await _liveClashApi();
    if (clashApi == null) {
      // 隧道还在但已经指挥不动，留着只会变成一条界面管不了的连接
      Logger.instance.warn(_source, '内核在跑但读不出它的控制面参数，停掉重来');
      await stop();
      return null;
    }

    _clashApi = clashApi;
    _drainLog(result);
    _applyRunning(result);
    _startLogStream(clashApi);
    _startPolling();
    return clashApi;
  }

  /// 控制面端口与 secret 每次装配都是新随机值，只有内核那份落盘配置里有。
  Future<ClashApiOptions?> _liveClashApi() async {
    final Object? decoded;
    try {
      // 桌面 run 目录对 GUI 不可读，必须经特权侧 kernel.read；Android 同协议。
      decoded = jsonDecode(await readRunFile('config.json'));
    } on Object {
      return null;
    }
    if (decoded is! Map<String, dynamic>) {
      return null;
    }

    final int? port = _portOf(decoded['external-controller']);
    final Object? secret = decoded['secret'];
    if (port == null || secret is! String) {
      return null;
    }

    return ClashApiOptions(port: port, secret: secret);
  }

  static int? _portOf(Object? listen) => listen is String
      ? int.tryParse(listen.substring(listen.lastIndexOf(':') + 1))
      : null;

  @override
  Future<void> start({
    required String configJson,
    required ClashApiOptions clashApi,
  }) async {
    _clashApi = clashApi;
    _update(const KernelStatus(state: KernelState.starting));

    try {
      await _service.request('kernel.start', <String, dynamic>{
        'config': configJson,
      });
    } on ServiceException catch (e) {
      _update(KernelStatus(state: KernelState.failed, message: e.toString()));
      throw KernelException('内核启动失败：$e');
    }

    _startLogStream(clashApi);
    _startPolling();
  }

  // 内核与 GUI 同进程时没有可捕获的 stdout，日志只能从控制面取
  void _startLogStream(ClashApiOptions clashApi) {
    // 重启内核不再经过 stop()，上一轮的流还挂着，不先收掉就漏一个订阅
    _stopLogStream();
    if (!_logFromClashApi) {
      return;
    }
    final ClashApiClient client = ClashApiClient(clashApi);
    _logClient = client;
    // 取最啰嗦的级别，界面自己按级别过滤；mihomo 不认 trace
    _logSubscription = client
        .logStream(LogLevel.debug.label)
        .listen(_logController.add);
  }

  @override
  Future<void> stop() async {
    _update(const KernelStatus(state: KernelState.stopping));

    try {
      await _service.request('kernel.stop');
    } on ServiceException catch (e) {
      Logger.instance.warn(_source, '停止内核失败: $e');
    }

    _stopPolling();
    _clashApi = null;
    _startedAt = null;
    _update(const KernelStatus.stopped());
  }

  @override
  Future<void> persistConfig(String configJson) async {
    try {
      await _service.request('kernel.write', <String, dynamic>{
        'config': configJson,
      });
    } on ServiceException catch (e) {
      throw KernelException('写入配置失败：$e');
    }
  }

  @override
  Future<void> reloadConfig(String configJson) async {
    try {
      await _service.request('kernel.reload', <String, dynamic>{
        'config': configJson,
      });
    } on ServiceException catch (e) {
      throw KernelException('热载配置失败：$e');
    }
  }

  @override
  Future<String> readRunFile(String relativePath) async {
    try {
      final Map<String, dynamic> result = await _service.request(
        'kernel.read',
        <String, dynamic>{'path': relativePath},
      );
      final Object? content = result['content'];
      if (content is! String) {
        throw KernelException('读取失败：应答无内容');
      }
      return content;
    } on ServiceException catch (e) {
      throw KernelException('$e');
    }
  }

  @override
  Future<String?> validate(String configJson) async {
    try {
      final Map<String, dynamic> result = await _service.request(
        'kernel.check',
        <String, dynamic>{'config': configJson},
      );
      return result['valid'] == true ? null : result['error'] as String?;
    } on ServiceException catch (e) {
      return '无法校验配置：$e';
    }
  }

  void _startPolling() {
    _poller?.cancel();
    _poller = Timer.periodic(_pollInterval, (_) => unawaited(_poll()));
    unawaited(_poll());
  }

  void _stopPolling() {
    _poller?.cancel();
    _poller = null;
    _stopLogStream();
  }

  void _stopLogStream() {
    unawaited(_logSubscription?.cancel());
    _logSubscription = null;
    _logClient?.close();
    _logClient = null;
  }

  Future<void> _poll() async {
    late Map<String, dynamic> result;
    try {
      result = await _service.request('kernel.status', <String, dynamic>{
        'log_cursor': _logCursor,
      });
    } on ServiceException catch (e) {
      _stopPolling();
      _update(KernelStatus(state: KernelState.failed, message: '与后台服务失联：$e'));
      return;
    }

    _drainLog(result);

    if (result['running'] == true) {
      _applyRunning(result);
      return;
    }

    // 服务侧内核已不在，交由上层状态机决定是否重启
    _stopPolling();
    final bool stoppedByUser = result['stopped_by_user'] == true;
    _update(
      KernelStatus(
        state: stoppedByUser || _status.state == KernelState.stopping
            ? KernelState.stopped
            : KernelState.failed,
        exitCode: (result['exit_code'] as num?)?.toInt(),
        message: result['error'] as String?,
        retriable: result['revoked'] != true,
        stoppedByUser: stoppedByUser,
      ),
    );
  }

  // 内核跑起来过，说明缓存目录已经建好
  void _applyRunning(Map<String, dynamic> result) {
    _cacheReady = true;
    final int startedAt = (result['started_at'] as num?)?.toInt() ?? 0;
    _startedAt = startedAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(startedAt)
        : null;
    _update(
      KernelStatus(
        state: KernelState.running,
        pid: (result['pid'] as num?)?.toInt(),
      ),
    );
  }

  void _drainLog(Map<String, dynamic> result) {
    final Object? lines = result['log_lines'];
    if (lines is List) {
      for (final Object? line in lines) {
        if (line is String) {
          _logController.add(line);
        }
      }
    }
    _logCursor = (result['log_cursor'] as num?)?.toInt() ?? _logCursor;
  }

  void _update(KernelStatus status) {
    _status = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }

  @override
  Future<void> dispose() async {
    _stopPolling();
    await _statusController.close();
    await _logController.close();
  }
}
