import '../../core/app_paths.dart';
import 'json_file_store.dart';

class SpeedTestQuotaStore {
  SpeedTestQuotaStore({
    JsonFileStore? store,
    DateTime Function()? clock,
  }) : _store = store ?? JsonFileStore(AppPaths.speedTestQuota, 'speed-test-quota'),
       _clock = clock ?? DateTime.now {
    _load();
  }

  static const int limit = 5;
  static const Duration window = Duration(hours: 1);

  final JsonFileStore _store;
  final DateTime Function() _clock;

  String _account = '';
  final Map<String, List<int>> _stamps = <String, List<int>>{};

  void bindAccount(String account) {
    final String next = account.trim().toLowerCase();
    if (next == _account) {
      return;
    }
    _account = next;
    _stamps.clear();
    _load();
  }

  bool canTest(String proxyName) => remaining(proxyName) > 0;

  int remaining(String proxyName) {
    _prune(proxyName);
    return limit - (_stamps[proxyName]?.length ?? 0);
  }

  DateTime? resetAt(String proxyName) {
    _prune(proxyName);
    final List<int> times = _stamps[proxyName] ?? const <int>[];
    if (times.length < limit) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(times.first + window.inMilliseconds);
  }

  void record(String proxyName) {
    final List<int> times = _stamps.putIfAbsent(proxyName, () => <int>[]);
    times.add(_clock().millisecondsSinceEpoch);
    _prune(proxyName);
    _write();
  }

  void markExhausted(String proxyName, DateTime reset) {
    final int oldest = reset.millisecondsSinceEpoch - window.inMilliseconds;
    _stamps[proxyName] = <int>[
      for (int i = 0; i < limit; i++) oldest,
    ];
    _write();
  }

  void _prune(String proxyName) {
    final List<int>? times = _stamps[proxyName];
    if (times == null || times.isEmpty) {
      return;
    }
    final int cutoff = _clock().millisecondsSinceEpoch - window.inMilliseconds;
    times.removeWhere((int stamp) => stamp < cutoff);
    if (times.isEmpty) {
      _stamps.remove(proxyName);
    }
  }

  void _load() {
    final Map<String, dynamic> raw = _store.read();
    if ((raw['account'] as String? ?? '') != _account || _account.isEmpty) {
      return;
    }
    if ((raw['version'] as num?)?.toInt() != 2) {
      return;
    }
    final Object? nodes = raw['nodes'];
    if (nodes is! Map) {
      return;
    }
    nodes.forEach((dynamic key, dynamic value) {
      if (value is! List) {
        return;
      }
      _stamps[key.toString()] = <int>[
        for (final Object? item in value)
          if (item is num) item.toInt(),
      ];
    });
  }

  void _write() {
    if (_account.isEmpty) {
      return;
    }
    _store.write(<String, dynamic>{
      'account': _account,
      'version': 2,
      'nodes': <String, List<int>>{
        for (final MapEntry<String, List<int>> entry in _stamps.entries)
          if (entry.value.isNotEmpty) entry.key: List<int>.of(entry.value),
      },
    });
  }
}
