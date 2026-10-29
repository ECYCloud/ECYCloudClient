import '../../l10n/l10n.dart';

/// 指令名、请求体与 `{ok, error, data}` 应答四端一致。
abstract class ServiceTransport {
  Future<Map<String, dynamic>> request(
    String command, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]);
}

class ServiceException implements Exception {
  ServiceException(this.message);

  final String message;

  /// 进程不在（可拉起重试），与「在但拒绝指令」区分。
  bool get serviceUnavailable => false;

  @override
  String toString() => L10n.message(message);
}
