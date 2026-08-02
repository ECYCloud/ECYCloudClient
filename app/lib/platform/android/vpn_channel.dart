import 'package:flutter/services.dart';

import '../service/service_transport.dart';

/// VpnService 与 libbox 都在同一个进程里，指令走 Platform Channel 而不是套接字，
/// 指令名、请求体与应答字段与桌面端特权服务完全一致。
class VpnChannel implements ServiceTransport {
  const VpnChannel();

  static const MethodChannel _channel = MethodChannel('ecycloud/vpn');

  @override
  Future<Map<String, dynamic>> request(
    String command, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    try {
      final Map<Object?, Object?>? result = await _channel
          .invokeMethod<Map<Object?, Object?>>(command, payload);
      return result == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(result);
    } on PlatformException catch (e) {
      throw ServiceException(e.message ?? '后台服务处理失败');
    } on MissingPluginException {
      throw ServiceException('后台服务未注册指令 $command');
    }
  }
}
