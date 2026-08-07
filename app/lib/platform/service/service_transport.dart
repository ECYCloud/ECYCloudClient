/// 特权服务的请求通道。Windows 走命名管道，macOS / Linux 走 Unix 域套接字，
/// 两端的指令名、请求体与 `{ok, error, data}` 应答结构完全一致。
abstract class ServiceTransport {
  Future<Map<String, dynamic>> request(
    String command, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]);
}

class ServiceException implements Exception {
  ServiceException(this.message);

  final String message;

  /// 服务进程不在，重试或拉起服务后可能恢复；与「服务在但拒绝了指令」区分开
  bool get serviceUnavailable => false;

  @override
  String toString() => message;
}
