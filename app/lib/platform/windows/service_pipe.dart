import '../../core/logger.dart';
import '../service/service_transport.dart';
import 'named_pipe_client.dart';
import 'service_control.dart';

/// 命名管道 + 服务自恢复。
///
/// 服务进程若异常退出，SCM 要等失败恢复计时（首次 5 秒）才把它拉起来，这段窗口里
/// `\\.\pipe\ECYCloudService` 根本不存在，CreateFileW 返回 ERROR_FILE_NOT_FOUND。
/// 此时先查 SCM 状态、必要时直接把服务启动起来再重试，只有确实未安装或无权限
/// 才向上抛错，不把「请重新安装客户端」这种死路甩给用户。
class ServicePipe implements ServiceTransport {
  const ServicePipe(this._pipe, this._service);

  factory ServicePipe.production() =>
      const ServicePipe(NamedPipeClient(pipeName), ServiceControl(serviceName));

  static const String pipeName = r'\\.\pipe\ECYCloudService';
  static const String serviceName = 'ECYCloudService';
  static const String _source = 'service';

  final NamedPipeClient _pipe;
  final ServiceControl _service;

  Future<ServiceProbe> probe() => _service.probe();

  @override
  Future<Map<String, dynamic>> request(
    String command, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    try {
      return await _pipe.request(command, payload);
    } on PipeException catch (e) {
      if (!e.serviceUnavailable) {
        rethrow;
      }

      Logger.instance.warn(_source, '后台服务不可达（$e），尝试恢复');
      final ServiceProbe probed = await _service.ensureRunning();
      if (!probed.running) {
        throw PipeException(describe(probed));
      }

      Logger.instance.info(_source, '后台服务已恢复运行，重试 $command');
      try {
        return await _pipe.request(command, payload);
      } on PipeException catch (retry) {
        if (!retry.serviceUnavailable) {
          rethrow;
        }
        throw PipeException('后台服务已在运行，但命名管道仍不可用（Win32 错误 ${retry.lastError}）');
      }
    }
  }

  static String describe(ServiceProbe probed) => switch (probed.state) {
    WindowsServiceState.missing => '后台服务未安装，请重新运行安装包',
    WindowsServiceState.denied => '当前账户无权访问后台服务，请以管理员身份运行一次客户端',
    _ =>
      '后台服务${probed.label}，无法连接'
          '${probed.detail == null ? '' : '：${probed.detail}'}',
  };
}
