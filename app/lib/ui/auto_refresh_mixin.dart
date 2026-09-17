import 'dart:async';

import 'package:flutter/widgets.dart';

mixin AutoRefreshMixin<T extends StatefulWidget> on State<T> {
  Timer? _autoRefreshTimer;
  bool _autoRefreshing = false;
  int _loadId = 0;

  Future<void> loadLatest<R, E extends Object>(
    Future<R> Function() request, {
    required ValueChanged<R> onData,
    required ValueChanged<E> onError,
    bool silent = false,
  }) async {
    final int loadId = ++_loadId;
    bool isCurrent() => mounted && loadId == _loadId;

    try {
      final R result = await request();
      if (isCurrent()) {
        onData(result);
      }
    } on E catch (e) {
      if (!silent && isCurrent()) {
        onError(e);
      }
    }
  }

  void startAutoRefresh(Future<void> Function() refresh) {
    _autoRefreshTimer ??= Timer.periodic(const Duration(seconds: 60), (
      _,
    ) async {
      if (!mounted || _autoRefreshing) {
        return;
      }
      _autoRefreshing = true;
      try {
        await refresh();
      } finally {
        _autoRefreshing = false;
      }
    });
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    super.dispose();
  }
}
