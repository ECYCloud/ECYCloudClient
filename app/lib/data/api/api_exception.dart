class ApiException implements Exception {
  ApiException(
    this.message, {
    this.statusCode,
    this.ret,
    this.retryAfterSeconds,
    this.connectFailed = false,
  });

  final String message;
  final int? statusCode;
  final int? ret;

  /// 连接就没建起来，请求肯定没到服务端。非幂等请求只有在这种失败下才敢换条路重发
  final bool connectFailed;

  /// 面板 429 的 Retry-After（秒）；客户端按此退避，避免瞎重试
  final int? retryAfterSeconds;

  bool get unauthorized => statusCode == 401 && ret != 2;

  bool get needsTwoFactor => ret == 2;

  bool get rateLimited => statusCode == 429;

  @override
  String toString() => message;
}
