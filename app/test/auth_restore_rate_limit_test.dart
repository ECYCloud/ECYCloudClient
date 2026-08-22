import 'package:flutter_test/flutter_test.dart';

import 'package:ecycloud_client/data/api/api_exception.dart';

void main() {
  test('429 必须带 statusCode，供 restore 区分限流与鉴权失败', () {
    final ApiException limited = ApiException(
      '请求过于频繁，请稍后再试',
      statusCode: 429,
      retryAfterSeconds: 12,
    );
    expect(limited.statusCode, 429);
    expect(limited.rateLimited, isTrue);
    expect(limited.unauthorized, isFalse);
    expect(limited.retryAfterSeconds, 12);

    final ApiException expired = ApiException('登录已失效', statusCode: 401, ret: 0);
    expect(expired.unauthorized, isTrue);
    expect(expired.rateLimited, isFalse);
  });

  test('鉴权失败与限流不得混用同一处理分支', () {
    const List<int> statuses = <int>[401, 429];
    final Map<int, bool> keepSession = <int, bool>{
      for (final int code in statuses)
        code: !ApiException('x', statusCode: code).unauthorized,
    };
    expect(keepSession[401], isFalse);
    expect(keepSession[429], isTrue);
  });
}
