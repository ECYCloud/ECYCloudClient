class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.ret});

  final String message;
  final int? statusCode;
  final int? ret;

  bool get unauthorized => statusCode == 401 && ret != 2;

  bool get needsTwoFactor => ret == 2;

  @override
  String toString() => message;
}
