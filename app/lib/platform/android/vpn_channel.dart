import 'package:flutter/services.dart';

import '../service/service_transport.dart';

/// 指令与桌面特权服务一致。
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
