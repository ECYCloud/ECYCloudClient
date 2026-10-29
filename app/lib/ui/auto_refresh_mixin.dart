import 'dart:async';

import 'package:flutter/widgets.dart';

import '../state/auth_controller.dart';
import 'app_scope.dart';

mixin AutoRefreshMixin<T extends StatefulWidget> on State<T> {
  Timer? _autoRefreshTimer;
  bool _autoRefreshing = false;
  int _loadId = 0;
  Locale? _loadLocale;
  Future<void> Function()? _refresh;
  AuthController? _auth;
  String? _revisionKey;
  String? _revision;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadLocale != null) {
      final Locale locale = Localizations.localeOf(context);
      if (_loadLocale != locale) {
        _loadLocale = locale;
        unawaited(_refresh?.call());
      }
    }
  }

  Future<void> loadLatest<R, E extends Object>(
    Future<R> Function() request, {
    required ValueChanged<R> onData,
    required ValueChanged<E> onError,
    bool silent = false,
  }) async {
    final int loadId = ++_loadId;
    _loadLocale ??= Localizations.localeOf(context);
    while (mounted && loadId == _loadId) {
      final Locale locale = Localizations.localeOf(context);
      try {
        final R result = await request();
        if (!mounted || loadId != _loadId) return;
        if (locale != Localizations.localeOf(context)) continue;
        onData(result);
      } on E catch (e) {
        if (!mounted || loadId != _loadId) return;
        if (locale != Localizations.localeOf(context)) continue;
        if (!silent) onError(e);
      }
      return;
    }
  }

  /// [revision] 为 profile 里该页的版本号键：面板已下发时只在版本变化后静默重取，
  /// 未下发（旧面板或单项计算失败）时仍每 60 秒刷新
  void startAutoRefresh(Future<void> Function() refresh, {String? revision}) {
    _refresh = refresh;
    if (revision != null && _auth == null) {
      _revisionKey = revision;
      _auth = AppScope.of(context).auth..addListener(_onProfileChanged);
      _revision = _currentRevision;
    }
    _autoRefreshTimer ??= Timer.periodic(const Duration(seconds: 60), (_) {
      if (_currentRevision == null) {
        unawaited(_runRefresh());
      }
    });
  }

  String? get _currentRevision {
    final String? key = _revisionKey;
    return key == null ? null : _auth?.profile?.revisions[key];
  }

  void _onProfileChanged() {
    final String? previous = _revision;
    final String? next = _currentRevision;
    _revision = next;
    if (previous != null && next != null && previous != next) {
      unawaited(_runRefresh());
    }
  }

  Future<void> _runRefresh() async {
    final Future<void> Function()? refresh = _refresh;
    if (!mounted || _autoRefreshing || refresh == null) {
      return;
    }
    _autoRefreshing = true;
    try {
      await refresh();
    } finally {
      _autoRefreshing = false;
    }
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _auth?.removeListener(_onProfileChanged);
    super.dispose();
  }
}
