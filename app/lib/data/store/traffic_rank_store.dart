import 'dart:convert';

import '../../core/app_paths.dart';
import '../../core/logger.dart';
import 'json_file_store.dart';

enum TrafficRankDay { today, yesterday }

class TrafficRankRow {
  const TrafficRankRow({required this.name, required this.bytes});

  final String name;
  final int bytes;
}

class TrafficRankStore {
  TrafficRankStore({JsonFileStore? store, DateTime Function()? clock})
    : _store = store ?? JsonFileStore(AppPaths.trafficRank, 'traffic-rank'),
      _clock = clock ?? DateTime.now;

  static const int topLimit = 10;
  static const Duration _saveInterval = Duration(seconds: 30);

  // 与 OpenWrt statistics.uc 同一口径：当天内存计数受键数上限约束，落盘只留每类前 100
  static const int _keepLimit = 100;
  static const int _groupLimit = 512;
  static const int _hostLimit = 10000;
  static const int _hostBytes = 253;

  final JsonFileStore _store;
  final DateTime Function() _clock;

  final Map<String, _DayBucket> _days = <String, _DayBucket>{};
  bool _dirty = false;
  DateTime? _savedAt;
  String _account = '';

  void bindAccount(String account) {
    final String next = account.trim().toLowerCase();
    if (next == _account) {
      return;
    }
    flush();
    _account = next;
    _savedAt = null;
    _days.clear();
    _load();
  }

  static String dayKey(DateTime time) {
    final DateTime local = time.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  static String yesterdayKey(DateTime time) {
    final DateTime local = time.toLocal();
    return dayKey(DateTime(local.year, local.month, local.day - 1));
  }

  void add({
    required Iterable<String> groups,
    required String host,
    required int bytes,
  }) {
    if (_account.isEmpty || bytes <= 0) {
      return;
    }

    final DateTime now = _clock();
    final _DayBucket bucket = _days.putIfAbsent(dayKey(now), _DayBucket.new);
    for (final String group in groups) {
      if (group.isEmpty ||
          (!bucket.groups.containsKey(group) &&
              bucket.groups.length >= _groupLimit)) {
        continue;
      }
      bucket.groups[group] = (bucket.groups[group] ?? 0) + bytes;
    }
    if (host.isNotEmpty &&
        utf8.encode(host).length <= _hostBytes &&
        (bucket.hosts.containsKey(host) || bucket.hosts.length < _hostLimit)) {
      bucket.hosts[host] = (bucket.hosts[host] ?? 0) + bytes;
    }
    _prune(now);
    _dirty = true;
  }

  List<TrafficRankRow> topGroups(TrafficRankDay day) =>
      _top(_bucket(day).groups);

  List<TrafficRankRow> topHosts(
    TrafficRankDay day, {
    Set<String> exclude = const <String>{},
  }) => _top(_bucket(day).hosts, exclude: exclude);

  void flush({bool force = true}) {
    if (_account.isEmpty || !_dirty) {
      return;
    }
    final DateTime now = _clock();
    final DateTime? savedAt = _savedAt;
    if (!force && savedAt != null && now.difference(savedAt) < _saveInterval) {
      return;
    }
    try {
      _write();
    } on Object catch (e) {
      Logger.instance.warn('traffic-rank', '保存流量排行失败: $e');
      return;
    }
    _dirty = false;
    _savedAt = now;
  }

  _DayBucket _bucket(TrafficRankDay day) {
    final DateTime now = _clock();
    final String key = day == TrafficRankDay.yesterday
        ? yesterdayKey(now)
        : dayKey(now);
    return _days[key] ?? _DayBucket();
  }

  List<TrafficRankRow> _top(
    Map<String, int> map, {
    Set<String> exclude = const <String>{},
  }) {
    final List<TrafficRankRow> rows = <TrafficRankRow>[
      for (final MapEntry<String, int> entry in map.entries)
        if (entry.value > 0 && !exclude.contains(entry.key.toLowerCase()))
          TrafficRankRow(name: entry.key, bytes: entry.value),
    ]..sort((TrafficRankRow a, TrafficRankRow b) => b.bytes.compareTo(a.bytes));
    if (rows.length > topLimit) {
      return rows.sublist(0, topLimit);
    }
    return rows;
  }

  void _load() {
    if (_account.isEmpty) {
      return;
    }
    final Map<String, dynamic> raw = _store.read();
    final Object? accounts = raw['accounts'];
    final Object? days = accounts is Map<String, dynamic>
        ? accounts[_account]
        : raw['account'] == _account
        ? raw['days']
        : null;
    if (days is! Map<String, dynamic>) {
      return;
    }
    days.forEach((String key, Object? value) {
      if (value is Map<String, dynamic>) {
        _days[key] = _DayBucket.fromJson(value);
      } else if (value is Map) {
        _days[key] = _DayBucket.fromJson(Map<String, dynamic>.from(value));
      }
    });
    _prune(_clock());
  }

  void _prune(DateTime now) {
    final Set<String> keep = <String>{dayKey(now), yesterdayKey(now)};
    _days.removeWhere((String key, _DayBucket _) => !keep.contains(key));
  }

  // 其它账户只留今天与昨天：过期日期一并清掉，同账户再登录仍能恢复近两天排行
  void _write() {
    final Map<String, dynamic> raw = _store.read();
    final Map<String, dynamic> accounts =
        raw['accounts'] is Map<String, dynamic>
        ? raw['accounts'] as Map<String, dynamic>
        : <String, dynamic>{};
    final Object? oldAccount = raw['account'];
    if (oldAccount is String && oldAccount.isNotEmpty && raw['days'] is Map) {
      accounts[oldAccount] = raw['days'];
    }
    final DateTime now = _clock();
    _store.write(<String, dynamic>{
      'accounts': <String, dynamic>{
        for (final MapEntry<String, dynamic> entry in accounts.entries)
          if (entry.key != _account)
            if (_recentJson(entry.value, now)
                case final Map<String, dynamic> days when days.isNotEmpty)
              entry.key: days,
        _account: <String, dynamic>{
          for (final MapEntry<String, _DayBucket> entry in _days.entries)
            entry.key: entry.value.toJson(),
        },
      },
    });
  }

  static Map<String, dynamic> _recentJson(Object? days, DateTime now) =>
      <String, dynamic>{
        if (days is Map)
          for (final String key in <String>[dayKey(now), yesterdayKey(now)])
            if (days[key] case final Map<dynamic, dynamic> bucket)
              key: _DayBucket.fromJson(Map<String, dynamic>.from(bucket))
                  .toJson(),
      };
}

class _DayBucket {
  _DayBucket({Map<String, int>? groups, Map<String, int>? hosts})
    : groups = groups ?? <String, int>{},
      hosts = hosts ?? <String, int>{};

  factory _DayBucket.fromJson(Map<String, dynamic> json) => _DayBucket(
    groups: _intMap(json['groups']),
    hosts: _intMap(json['hosts']),
  );

  final Map<String, int> groups;
  final Map<String, int> hosts;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'groups': _kept(groups),
    'hosts': _kept(hosts),
  };

  static Map<String, int> _kept(Map<String, int> map) {
    if (map.length <= TrafficRankStore._keepLimit) {
      return map;
    }
    final List<MapEntry<String, int>> entries = map.entries.toList()
      ..sort(
        (MapEntry<String, int> a, MapEntry<String, int> b) => b.value == a.value
            ? a.key.compareTo(b.key)
            : b.value.compareTo(a.value),
      );
    return Map<String, int>.fromEntries(
      entries.take(TrafficRankStore._keepLimit),
    );
  }

  static Map<String, int> _intMap(Object? raw) {
    if (raw is! Map) {
      return <String, int>{};
    }
    return <String, int>{
      for (final MapEntry<dynamic, dynamic> entry in raw.entries)
        if (entry.value is num)
          entry.key.toString(): (entry.value as num).toInt(),
    };
  }
}
