import 'dart:io';

import 'package:ecycloud_client/data/store/json_file_store.dart';
import 'package:ecycloud_client/data/store/speed_test_quota_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late File file;
  late DateTime now;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ecycloud-speed-test-quota-');
    file = File('${dir.path}/speed-test-quota.json');
    if (file.existsSync()) {
      file.deleteSync();
    }
    now = DateTime(2026, 9, 9, 12);
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  SpeedTestQuotaStore store() => SpeedTestQuotaStore(
    store: JsonFileStore(file, 'speed-test-quota-test'),
    clock: () => now,
  );

  test('同一账号同一节点 1 小时 5 次', () {
    final SpeedTestQuotaStore quota = store()..bindAccount('a@example.com');
    expect(quota.remaining('node-1'), 5);
    for (int i = 0; i < 5; i++) {
      quota.record('node-1');
    }
    expect(quota.canTest('node-1'), isFalse);
    expect(quota.canTest('node-2'), isTrue);
  });

  test('窗口滑过最早一次后恢复次数', () {
    final SpeedTestQuotaStore quota = store()..bindAccount('a@example.com');
    quota.record('node-1');
    now = now.add(const Duration(minutes: 10));
    for (int i = 0; i < 4; i++) {
      quota.record('node-1');
    }
    expect(quota.canTest('node-1'), isFalse);
    now = now.add(const Duration(minutes: 51));
    expect(quota.remaining('node-1'), 1);
  });

  test('换账号不沿用上一账号的次数', () {
    final SpeedTestQuotaStore quota = store()..bindAccount('a@example.com');
    for (int i = 0; i < 5; i++) {
      quota.record('node-1');
    }
    quota.bindAccount('b@example.com');
    expect(quota.canTest('node-1'), isTrue);
  });
}
