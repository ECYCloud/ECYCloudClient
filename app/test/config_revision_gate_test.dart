import 'package:flutter_test/flutter_test.dart';

/// 与 connection_controller 中「本地有配置时先比 revision」的判定一致。
bool shouldSkipSingBoxFetch({
  required String localRevision,
  required String remoteRevision,
}) {
  if (localRevision.isEmpty || remoteRevision.isEmpty) {
    return false;
  }
  return localRevision == remoteRevision;
}

void main() {
  test('revision 未变时应跳过 /config/sing-box', () {
    expect(
      shouldSkipSingBoxFetch(
        localRevision: 'abc',
        remoteRevision: 'abc',
      ),
      isTrue,
    );
  });

  test('revision 变化或为空必须拉全量', () {
    expect(
      shouldSkipSingBoxFetch(localRevision: 'a', remoteRevision: 'b'),
      isFalse,
    );
    expect(
      shouldSkipSingBoxFetch(localRevision: '', remoteRevision: 'b'),
      isFalse,
    );
    expect(
      shouldSkipSingBoxFetch(localRevision: 'a', remoteRevision: ''),
      isFalse,
    );
  });
}
