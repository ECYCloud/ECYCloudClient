class ApiException implements Exception {
  ApiException(
    this.message, {
    this.statusCode,
    this.ret,
    this.retryAfterSeconds,
  });

  final String message;
  final int? statusCode;
  final int? ret;

  /// 面板 429 的 Retry-After（秒）；客户端按此退避，避免瞎重试
  final int? retryAfterSeconds;

  bool get unauthorized => statusCode == 401 && ret != 2;

  bool get needsTwoFactor => ret == 2;

  bool get rateLimited => statusCode == 429;

  @override
  String toString() => message;
}
