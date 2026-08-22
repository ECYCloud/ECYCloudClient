import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/logger.dart';
import '../service/service_transport.dart';

/// 一条连接一问一答，客户端以 EOF 判定结束。
class HelperClient implements ServiceTransport {
  const HelperClient(this.socketPath, this.missingHint);

  static const String defaultSocketPath = '/var/run/ecycloud/helper.sock';
  static const Duration _timeout = Duration(minutes: 15);
  static const Duration _restartWindow = Duration(seconds: 3);
  static const String _source = 'service';

  final String socketPath;

  final String missingHint;

  @override
  Future<Map<String, dynamic>> request(
    String command, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    try {
      return await _transact(command, payload);
    } on HelperException catch (e) {
      if (!e.serviceUnavailable) {
        rethrow;
      }
      Logger.instance.warn(_source, '后台服务不可达（$e），等待其自行拉起后重试');
      await Future<void>.delayed(_restartWindow);
      try {
        return await _transact(command, payload);
      } on HelperException catch (retry) {
        throw retry.serviceUnavailable ? HelperException(missingHint) : retry;
      }
    }
  }

  Future<Map<String, dynamic>> _transact(
    String command,
    Map<String, dynamic> payload,
  ) async {
    final String requestLine = jsonEncode(<String, dynamic>{
      'command': command,
      'pid': pid,
      ...payload,
    });

    final Socket socket;
    try {
      socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
    } on SocketException catch (e) {
      throw HelperException(
        '无法连接后台服务：${e.osError?.message ?? e.message}',
        unavailable: true,
      );
    }

    final String responseLine;
    try {
      socket.add(utf8.encode('$requestLine\n'));
      await socket.flush();
      responseLine = (await utf8.decoder.bind(socket).join().timeout(_timeout))
          .trim();
    } on TimeoutException {
      throw HelperException('后台服务在超时内没有应答 $command');
    } on SocketException catch (e) {
      throw HelperException('与后台服务通信失败：${e.osError?.message ?? e.message}');
    } finally {
      socket.destroy();
    }

    if (responseLine.isEmpty) {
      throw HelperException('后台服务未返回任何内容');
    }

    final Object? decoded = jsonDecode(responseLine);
    if (decoded is! Map<String, dynamic>) {
      throw HelperException('后台服务返回了非预期内容');
    }
    if (decoded['ok'] != true) {
      throw HelperException(decoded['error'] as String? ?? '后台服务处理失败');
    }

    final Object? data = decoded['data'];
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }
}

class HelperException extends ServiceException {
  // 命名参数不能写成 this._field，只能在初始化列表里赋值
  // ignore_for_file: prefer_initializing_formals
  HelperException(super.message, {bool unavailable = false})
    : _unavailable = unavailable;

  final bool _unavailable;

  @override
  bool get serviceUnavailable => _unavailable;
}
