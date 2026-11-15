import 'dart:convert';
import 'dart:io';

import 'package:ecycloud_client/data/store/json_file_store.dart';
import 'package:ecycloud_client/data/store/traffic_rank_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late File file;
  late DateTime now;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ecycloud-traffic-rank-');
    file = File('${dir.path}/traffic-rank.json');
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

  TrafficRankStore store() => TrafficRankStore(
    store: JsonFileStore(file, 'traffic-rank-test'),
    clock: () => now,
  )..bindAccount('account-a@test');

  test('按策略组和域名累计并只留 Top10', () {
    final TrafficRankStore rank = store();
    for (int i = 0; i < 12; i++) {
      rank.add(
        groups: <String>['组$i'],
        host: 'h$i.example',
        bytes: (i + 1) * 10,
      );
    }

    final List<TrafficRankRow> groups = rank.topGroups(TrafficRankDay.today);
    expect(groups, hasLength(10));
    expect(groups.first.name, '组11');
    expect(groups.first.bytes, 120);
    expect(groups.last.name, '组2');

    final List<TrafficRankRow> hosts = rank.topHosts(TrafficRankDay.today);
    expect(hosts.first.name, 'h11.example');
    expect(hosts, hasLength(10));
  });

  test('域名排行可排除节点地址', () {
    final TrafficRankStore rank = store();
    rank.add(groups: <String>['美国'], host: 'dashanren.ecydns.com', bytes: 100);
    rank.add(groups: <String>['美国'], host: 'example.com', bytes: 40);

    expect(
      rank.topHosts(
        TrafficRankDay.today,
        exclude: <String>{'dashanren.ecydns.com'},
      ),
      hasLength(1),
    );
    expect(
      rank
          .topHosts(
            TrafficRankDay.today,
            exclude: <String>{'dashanren.ecydns.com'},
          )
          .single
          .name,
      'example.com',
    );
  });

  test('采样合并保存不延迟内存排行，满 30 秒保存最新数据', () {
    final TrafficRankStore rank = store();
    rank.add(groups: <String>['组'], host: 'live.test', bytes: 100);
    rank.flush(force: false);
    final String saved = file.readAsStringSync();
    for (int i = 0; i < 29; i++) {
      now = now.add(const Duration(seconds: 1));
      rank.add(groups: <String>['组'], host: 'live.test', bytes: 10);
      rank.flush(force: false);
      expect(rank.topHosts(TrafficRankDay.today).single.bytes, 110 + i * 10);
      expect(file.readAsStringSync(), saved);
    }
    now = now.add(const Duration(seconds: 1));
    rank.flush(force: false);
    expect(store().topHosts(TrafficRankDay.today).single.bytes, 390);
    expect(store().topGroups(TrafficRankDay.today).single.bytes, 390);
  });

  test('强制保存和切号不受保存间隔限制，也不混入另一账户', () {
    final TrafficRankStore rank = store();
    rank.add(groups: <String>['组'], host: 'saved.test', bytes: 100);
    rank.flush(force: false);
    rank.add(groups: <String>['组'], host: 'saved.test', bytes: 20);
    rank.flush();
    expect(store().topHosts(TrafficRankDay.today).single.bytes, 120);
    rank.add(groups: <String>['组'], host: 'saved.test', bytes: 30);
    rank.bindAccount('account-b@test');
    expect(store().topHosts(TrafficRankDay.today).single.bytes, 150);
    rank.add(groups: <String>['组'], host: 'other.test', bytes: 40);
    rank.flush(force: false);
    final TrafficRankStore reopened = store()..bindAccount('account-b@test');
    expect(reopened.topHosts(TrafficRankDay.today).single.bytes, 40);
    expect(reopened.topHosts(TrafficRankDay.today).single.name, 'other.test');
  });

  test('保存失败保留待保存数据，恢复后可以重试', () {
    final TrafficRankStore rank = store();
    rank.add(groups: <String>['组'], host: 'retry.test', bytes: 100);
    final Directory blocked = Directory('${file.path}.tmp')..createSync();
    expect(() => rank.flush(force: false), returnsNormally);
    expect(rank.topHosts(TrafficRankDay.today).single.bytes, 100);
    expect(file.existsSync(), isFalse);
    blocked.deleteSync();
    rank.flush(force: false);
    expect(store().topHosts(TrafficRankDay.today).single.bytes, 100);
  });

  test('跨日只保留今天和昨天，更早的丢掉', () {
    final TrafficRankStore first = store();
    first.add(groups: <String>['美国'], host: 'a.test', bytes: 100);

    now = DateTime(2026, 9, 10, 9);
    first.add(groups: <String>['日本'], host: 'b.test', bytes: 50);
    first.flush();

    now = DateTime(2026, 9, 11, 9);
    final TrafficRankStore loaded = store();
    expect(loaded.topGroups(TrafficRankDay.today), isEmpty);
    expect(loaded.topHosts(TrafficRankDay.yesterday).single.name, 'b.test');
  });

  test('重启、切换账户和登出保留各账户排行并隔离展示', () {
    final TrafficRankStore rank = store();
    rank.add(groups: <String>['private-a'], host: 'private-a.test', bytes: 100);
    rank.flush();
    final TrafficRankStore loaded = store();
    expect(loaded.topHosts(TrafficRankDay.today).single.name, 'private-a.test');
    loaded.bindAccount('account-b@test');
    expect(loaded.topGroups(TrafficRankDay.today), isEmpty);
    expect(loaded.topHosts(TrafficRankDay.today), isEmpty);
    loaded.add(
      groups: <String>['private-b'],
      host: 'private-b.test',
      bytes: 20,
    );
    loaded.bindAccount('');
    loaded.add(groups: <String>['stale'], host: 'stale.test', bytes: 30);
    loaded.flush();
    expect(loaded.topHosts(TrafficRankDay.today), isEmpty);
    expect(file.readAsStringSync(), isNot(contains('stale')));
    loaded.bindAccount('account-a@test');
    expect(loaded.topHosts(TrafficRankDay.today).single.name, 'private-a.test');
    expect(loaded.topHosts(TrafficRankDay.today).single.bytes, 100);
    loaded.bindAccount('account-b@test');
    expect(loaded.topHosts(TrafficRankDay.today).single.name, 'private-b.test');
    expect(loaded.topHosts(TrafficRankDay.today).single.bytes, 20);
  });

  test('启动时未绑定账户不能覆盖已保存的排行', () {
    final TrafficRankStore rank = store();
    rank.add(groups: <String>['美国'], host: 'saved.test', bytes: 100);
    rank.flush();
    final String saved = file.readAsStringSync();
    TrafficRankStore(
      store: JsonFileStore(file, 'traffic-rank-test'),
      clock: () => now,
    ).flush();
    expect(file.readAsStringSync(), saved);
    final TrafficRankStore loaded = store();
    loaded.bindAccount('');
    loaded.bindAccount('account-a@test');
    expect(loaded.topHosts(TrafficRankDay.today).single.bytes, 100);
  });

  test('旧版单账户文件在新账户使用后仍能恢复原账户排行', () {
    file.writeAsStringSync(
      jsonEncode(<String, Object>{
        'account': 'account-b@test',
        'days': <String, Object>{
          TrafficRankStore.dayKey(now): <String, Object>{
            'groups': <String, int>{'日本': 200},
            'hosts': <String, int>{'legacy.test': 200},
          },
        },
      }),
    );
    final TrafficRankStore rank = store();
    expect(rank.topHosts(TrafficRankDay.today), isEmpty);
    rank.add(groups: <String>['美国'], host: 'new.test', bytes: 100);
    rank.flush();
    rank.bindAccount('account-b@test');
    expect(rank.topGroups(TrafficRankDay.today).single.bytes, 200);
    expect(rank.topHosts(TrafficRankDay.today).single.name, 'legacy.test');
    rank.bindAccount('account-a@test');
    expect(rank.topHosts(TrafficRankDay.today).single.bytes, 100);
  });

  test('清除应用数据后重新启动不再有旧排行', () {
    final TrafficRankStore rank = store();
    rank.add(groups: <String>['美国'], host: 'saved.test', bytes: 100);
    rank.flush();
    file.deleteSync();
    final TrafficRankStore loaded = store();
    expect(loaded.topGroups(TrafficRankDay.today), isEmpty);
    expect(loaded.topHosts(TrafficRankDay.today), isEmpty);
  });

  // 与 OpenWrt 同一口径：超长主机名不计入，内存键数有上限，落盘每类只留前 100
  test('超长主机名不计入，内存键数受上限约束', () {
    final TrafficRankStore rank = store();
    rank.add(groups: <String>['组'], host: '${'a' * 249}.com', bytes: 5);
    rank.add(groups: <String>['组'], host: '${'b' * 250}.com', bytes: 900);
    expect(rank.topHosts(TrafficRankDay.today).single.name, '${'a' * 249}.com');
    for (int i = 0; i < 10001; i++) {
      rank.add(groups: <String>['组$i'], host: 'h$i.test', bytes: 1);
    }
    rank.add(groups: <String>['迟到组'], host: 'late.test', bytes: 1000);
    expect(rank.topGroups(TrafficRankDay.today).first.name, isNot('迟到组'));
    expect(rank.topHosts(TrafficRankDay.today).first.name, isNot('late.test'));
    rank.add(groups: <String>['组0'], host: 'h0.test', bytes: 1000);
    expect(rank.topGroups(TrafficRankDay.today).first.name, '组0');
    expect(rank.topHosts(TrafficRankDay.today).first.name, 'h0.test');
  });

  test('落盘只留每类前 100，当天内存保留完整计数', () {
    final TrafficRankStore rank = store();
    for (int i = 0; i < 150; i++) {
      rank.add(groups: <String>['组$i'], host: 'h$i.test', bytes: 1000 + i);
    }
    rank.flush();
    final Map<String, dynamic> saved =
        (jsonDecode(file.readAsStringSync())['accounts']
            as Map<String, dynamic>)['account-a@test'][TrafficRankStore.dayKey(
          now,
        )];
    expect((saved['groups'] as Map<String, dynamic>).length, 100);
    expect((saved['hosts'] as Map<String, dynamic>).length, 100);
    expect(saved['hosts'], contains('h149.test'));
    expect(saved['hosts'], isNot(contains('h0.test')));
    rank.add(groups: <String>['组0'], host: 'h0.test', bytes: 5000);
    expect(rank.topHosts(TrafficRankDay.today).first.name, 'h0.test');
    expect(rank.topHosts(TrafficRankDay.today).first.bytes, 6000);
    expect(rank.topGroups(TrafficRankDay.today), hasLength(10));
  });

  test('落盘清掉其它账户的过期日期，同账户再登录仍能恢复', () {
    final String today = TrafficRankStore.dayKey(now);
    final String old = TrafficRankStore.dayKey(
      now.subtract(const Duration(days: 3)),
    );
    Map<String, Object> day(String host) => <String, Object>{
      'groups': <String, int>{'组': 10},
      'hosts': <String, int>{host: 10},
    };
    file.writeAsStringSync(
      jsonEncode(<String, Object>{
        'accounts': <String, Object>{
          'account-b@test': <String, Object>{
            today: day('b-today.test'),
            old: day('b-old.test'),
          },
          'account-c@test': <String, Object>{old: day('c-old.test')},
        },
      }),
    );
    final TrafficRankStore rank = store();
    rank.add(groups: <String>['美国'], host: 'a.test', bytes: 100);
    rank.flush();
    final String saved = file.readAsStringSync();
    expect(saved, isNot(contains('b-old.test')));
    expect(saved, isNot(contains('account-c@test')));
    rank.bindAccount('account-b@test');
    expect(rank.topHosts(TrafficRankDay.today).single.name, 'b-today.test');
    rank.bindAccount('account-a@test');
    expect(rank.topHosts(TrafficRankDay.today).single.name, 'a.test');
  });
}
