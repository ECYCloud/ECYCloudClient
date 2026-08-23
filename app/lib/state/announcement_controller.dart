import 'package:flutter/foundation.dart';

import '../core/app_paths.dart';
import '../core/logger.dart';
import '../data/api/api_exception.dart';
import '../data/api/panel_api_client.dart';
import '../data/models/announcement.dart';
import '../data/store/json_file_store.dart';

class AnnouncementController extends ChangeNotifier {
  AnnouncementController();

  static const String _source = 'announcement';
  static const String _readMaxIdKey = 'read_max_id';
  static const String _seenKey = 'seen_revisions';
  static const String _dismissedPopupIdKey = 'dismissed_popup_id';
  static const String _dismissedPopupAtKey = 'dismissed_popup_updated_at';

  final JsonFileStore _store = JsonFileStore(
    AppPaths.announcementState,
    _source,
  );

  PanelApiClient? _api;
  List<Announcement> _items = const <Announcement>[];
  Announcement? _popup;
  String? _error;
  bool _busy = false;
  bool _loaded = false;

  List<Announcement> get items => _items;
  Announcement? get popup => _popup;
  String? get error => _error;
  bool get busy => _busy;
  bool get loaded => _loaded;

  Announcement? get pendingPopup {
    final Announcement? popup = _popup;
    if (popup == null) {
      return null;
    }
    final Map<String, dynamic> data = _store.read();
    final Object? dismissedRaw = data[_dismissedPopupIdKey];
    final int? dismissed = dismissedRaw is num ? dismissedRaw.toInt() : null;
    if (dismissed != popup.id) {
      return popup;
    }
    final String? dismissedAt = data[_dismissedPopupAtKey] as String?;
    return dismissedAt == popup.updatedAt ? null : popup;
  }

  bool get hasUnread {
    if (!_loaded) {
      return false;
    }
    return unreadFocusIndex != null;
  }

  int? get unreadFocusIndex => focusUnreadIndex(_items, _seenRevisions());

  int get openIndex => unreadFocusIndex ?? latestIndex(_items);

  static Map<String, String> decodeSeen(Object? raw) {
    if (raw is! Map) {
      return <String, String>{};
    }
    return <String, String>{
      for (final MapEntry<dynamic, dynamic> entry in raw.entries)
        entry.key.toString(): entry.value.toString(),
    };
  }

  static int? focusUnreadIndex(
    List<Announcement> items,
    Map<String, String> seen,
  ) {
    int? bestIndex;
    DateTime? bestAt;
    for (int i = 0; i < items.length; i++) {
      final Announcement item = items[i];
      if (item.id == 1) {
        continue;
      }
      if (seen['${item.id}'] == item.updatedAt) {
        continue;
      }
      final DateTime? at = item.revisedAt;
      if (bestIndex == null ||
          (at != null && (bestAt == null || at.isAfter(bestAt)))) {
        bestIndex = i;
        bestAt = at;
      }
    }
    return bestIndex;
  }

  static int latestIndex(List<Announcement> items) {
    if (items.isEmpty) {
      return 0;
    }
    int best = 0;
    DateTime? bestAt;
    for (int i = 0; i < items.length; i++) {
      if (items[i].id == 1 && items.length > 1) {
        continue;
      }
      final DateTime? at = items[i].revisedAt;
      if (at != null && (bestAt == null || at.isAfter(bestAt))) {
        best = i;
        bestAt = at;
      }
    }
    return best;
  }

  Map<String, String> _seenRevisions() =>
      decodeSeen(_store.read()[_seenKey]);

  void attachApi(PanelApiClient? api) {
    _api = api;
    if (api == null) {
      _items = const <Announcement>[];
      _popup = null;
      _error = null;
      _loaded = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    final PanelApiClient? api = _api;
    if (api == null || _busy) {
      return;
    }

    _busy = true;
    _error = null;
    notifyListeners();

    try {
      final AnnouncementBundle bundle = await api.fetchAnnouncements();
      _items = bundle.items;
      _popup = bundle.popup;
      _loaded = true;
      _migrateSeenIfNeeded();
    } on ApiException catch (e) {
      if (e.rateLimited) {
        Logger.instance.debug(_source, '拉取公告限流，稍后重试');
      } else {
        _error = e.message;
        Logger.instance.warn(_source, '拉取公告失败: $e');
      }
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void dismissPopup(Announcement announcement) {
    final Map<String, dynamic> data = _store.read();
    data[_dismissedPopupIdKey] = announcement.id;
    data[_dismissedPopupAtKey] = announcement.updatedAt;
    _store.write(data);
    notifyListeners();
  }

  void markAnnouncementSeen(Announcement announcement) {
    final Map<String, String> seen = _seenRevisions();
    if (seen['${announcement.id}'] == announcement.updatedAt) {
      return;
    }
    seen['${announcement.id}'] = announcement.updatedAt;
    _writeSeen(seen);
  }

  void markSeen() {
    if (_items.isEmpty) {
      return;
    }
    _writeSeen(<String, String>{
      for (final Announcement item in _items) '${item.id}': item.updatedAt,
    });
  }

  void _writeSeen(Map<String, String> seen) {
    final Map<String, dynamic> data = _store.read();
    data[_seenKey] = seen;
    data.remove(_readMaxIdKey);
    data.remove('last_seen_id');
    _store.write(data);
    notifyListeners();
  }

  void _migrateSeenIfNeeded() {
    final Map<String, dynamic> data = _store.read();
    bool dirty = false;

    if (data[_seenKey] is! Map) {
      final Object? maxIdRaw = data[_readMaxIdKey];
      if (maxIdRaw is num) {
        final int maxId = maxIdRaw.toInt();
        data[_seenKey] = <String, String>{
          for (final Announcement item in _items)
            if (item.id <= maxId) '${item.id}': item.updatedAt,
        };
        data.remove(_readMaxIdKey);
        data.remove('last_seen_id');
        dirty = true;
      }
    }

    if (data[_dismissedPopupIdKey] != null &&
        !data.containsKey(_dismissedPopupAtKey)) {
      final int dismissedId = data[_dismissedPopupIdKey] is num
          ? (data[_dismissedPopupIdKey] as num).toInt()
          : 0;
      for (final Announcement item in _items) {
        if (item.id == dismissedId) {
          data[_dismissedPopupAtKey] = item.updatedAt;
          dirty = true;
          break;
        }
      }
    }

    if (dirty) {
      _store.write(data);
    }
  }
}
