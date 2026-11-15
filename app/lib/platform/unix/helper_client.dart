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
  // 必须短于 helper 读请求的 10 秒时限：旧版 helper 不发握手，只会干等请求直到超时断开
  static const Duration _handshakeTimeout = Duration(seconds: 5);
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

    final Map<String, dynamic> decoded;
    try {
      final StreamIterator<String> lines = StreamIterator<String>(
        utf8.decoder.bind(socket).transform(const LineSplitter()),
      );
      final Map<String, dynamic> greeting = _decode(
        await _nextLine(lines).timeout(
          _handshakeTimeout,
          onTimeout: () => throw HelperException('后台服务响应超时'),
        ),
      );
      final Object? challenge = greeting['data'];
      final Object? nonce = challenge is Map<String, dynamic>
          ? challenge['nonce']
          : null;
      if (nonce is! String) {
        final Object? error = greeting['error'];
        throw HelperException(
          error is String && error.isNotEmpty
              ? error
              : greeting['ok'] == false
              ? '后台服务版本过旧，请重新运行安装包'
              : '后台服务处理失败',
        );
      }
      // helper 只受理握手之后、由同一进程写出且带本次随机数的请求，不能在读到握手前预写
      final String requestLine = jsonEncode(<String, dynamic>{
        'command': command,
        'pid': pid,
        ...payload,
        'nonce': nonce,
      });
      socket.add(utf8.encode('$requestLine\n'));
      await socket.flush();
      decoded = _decode(await _nextLine(lines).timeout(_timeout));
    } on TimeoutException {
      throw HelperException('后台服务在超时内没有应答 $command');
    } on SocketException catch (e) {
      throw HelperException('与后台服务通信失败：${e.osError?.message ?? e.message}');
    } finally {
      socket.destroy();
    }

    if (decoded['ok'] != true) {
      throw HelperException(decoded['error'] as String? ?? '后台服务处理失败');
    }

    final Object? data = decoded['data'];
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }

  static Future<String?> _nextLine(StreamIterator<String> lines) async =>
      await lines.moveNext() ? lines.current : null;

  static Map<String, dynamic> _decode(String? line) {
    if (line == null || line.trim().isEmpty) {
      throw HelperException('后台服务未返回任何内容');
    }
    final Object? decoded = jsonDecode(line);
    if (decoded is! Map<String, dynamic>) {
      throw HelperException('后台服务返回了非预期内容');
    }
    return decoded;
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
