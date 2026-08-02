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
    final int? dismissed = _store.read()['dismissed_popup_id'] as int?;
    return dismissed == popup.id ? null : popup;
  }

  void attachApi(PanelApiClient? api) {
    _api = api;
    if (api == null) {
      _items = const <Announcement>[];
      _popup = null;
      _error = null;
      _loaded = false;
      notifyListeners();
    }
    // 不在登录绑定时拉取；由首页访问时拉一次（与网页打开用户中心一致）
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
    } on ApiException catch (e) {
      // 公告也走面板限流；429 不刷到界面，也不打 warn 刷屏
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
    data['dismissed_popup_id'] = announcement.id;
    _store.write(data);
    notifyListeners();
  }
}
