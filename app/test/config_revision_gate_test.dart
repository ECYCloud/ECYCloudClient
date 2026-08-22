import 'package:flutter_test/flutter_test.dart';

bool shouldSkipProfileFetch({
  required String localRevision,
  required String remoteRevision,
}) {
  if (localRevision.isEmpty || remoteRevision.isEmpty) {
    return false;
  }
  return localRevision == remoteRevision;
}

void main() {
  test('revision 未变时应跳过 /config/clash', () {
    expect(
      shouldSkipProfileFetch(localRevision: 'abc', remoteRevision: 'abc'),
      isTrue,
    );
  });

  test('revision 变化或为空必须拉全量', () {
    expect(
      shouldSkipProfileFetch(localRevision: 'a', remoteRevision: 'b'),
      isFalse,
    );
    expect(
      shouldSkipProfileFetch(localRevision: '', remoteRevision: 'b'),
      isFalse,
    );
    expect(
      shouldSkipProfileFetch(localRevision: 'a', remoteRevision: ''),
      isFalse,
    );
  });
}
