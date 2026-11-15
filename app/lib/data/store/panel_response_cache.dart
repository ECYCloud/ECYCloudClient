import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/app_paths.dart';
import '../../core/logger.dart';
import '../api/panel_api_client.dart';
import '../models/user_profile.dart';
import 'cache_seal.dart';
import 'json_file_store.dart';

class PanelResponseCache {
  PanelResponseCache({JsonFileStore? profileStore, JsonFileStore? remoteStore})
    : _profile =
          profileStore ??
          JsonFileStore.at(() => AppPaths.profileCache, 'profile-cache'),
      _remote =
          remoteStore ??
          JsonFileStore.at(() => AppPaths.remoteConfigCache, 'remote-cache');

  final JsonFileStore _profile;
  final JsonFileStore _remote;

  // 缓存跨版本仍在原地；写入打内核标记，旧形状不能喂给装配
  static const String _kernel = 'mihomo';

  void saveProfile(String accountKey, UserProfile profile) {
    final String key = accountKey.trim().toLowerCase();
    if (key.isEmpty) {
      return;
    }
    _save(_profile, <String, dynamic>{
      'account': key,
      'profile': profile.toJson(),
    });
  }

  // 只是限流或离线时的兜底：写不进去不能拦住登录与连接
  static void _save(JsonFileStore store, Map<String, dynamic> data) {
    try {
      store.write(data);
    } on Object catch (e) {
      Logger.instance.warn(store.source, '写入缓存失败: $e');
    }
  }

  UserProfile? loadProfile(String accountKey) {
    final String key = accountKey.trim().toLowerCase();
    if (key.isEmpty) {
      return null;
    }
    final Map<String, dynamic> data = _profile.read();
    if ((data['account'] as String? ?? '').toLowerCase() != key) {
      return null;
    }
    final Object? raw = data['profile'];
    if (raw is! Map<String, dynamic>) {
      return null;
    }
    try {
      return UserProfile.fromJson(raw);
    } on Object {
      return null;
    }
  }

  // 配置含本设备的节点凭据，只以令牌派生的密钥加密落盘；没有密钥就不写
  void saveRemote(String accountKey, RemoteProfile remote, Uint8List? sealKey) {
    final String key = accountKey.trim().toLowerCase();
    if (key.isEmpty || sealKey == null) {
      return;
    }
    final String sealed;
    try {
      sealed = CacheSeal.seal(
        sealKey,
        jsonEncode(<String, dynamic>{
          'revision': remote.revision,
          'flag_regex': remote.flagRegex,
          'group_icons': remote.groupIcons,
          'node_labels': remote.nodeLabels,
          'group_labels': remote.groupLabels,
          'config': remote.config,
          'offline_issued_at': remote.offlineIssuedAt?.millisecondsSinceEpoch,
          'offline_until': remote.offlineUntil?.millisecondsSinceEpoch,
          'cache_binding': remote.cacheBinding,
          'update_interval_hours': remote.updateInterval?.inHours,
        }),
        key,
      );
    } on Object catch (e) {
      Logger.instance.warn(_remote.source, '加密面板配置缓存失败: $e');
      return;
    }
    _save(_remote, <String, dynamic>{
      'account': key,
      'kernel': _kernel,
      'sealed': sealed,
    });
  }

  RemoteProfile? loadRemote(String accountKey, Uint8List? sealKey) {
    final String key = accountKey.trim().toLowerCase();
    if (key.isEmpty) {
      return null;
    }
    final Map<String, dynamic> stored = _remote.read();
    // 旧版本明文缓存里有节点凭据，读到即删除
    if (stored.containsKey('config')) {
      try {
        _remote.clear();
      } on FileSystemException catch (e) {
        Logger.instance.warn(_remote.source, '删除明文面板配置缓存失败: $e');
      }
      return null;
    }
    if ((stored['account'] as String? ?? '').toLowerCase() != key ||
        stored['kernel'] != _kernel ||
        sealKey == null) {
      return null;
    }
    final String? opened = CacheSeal.open(sealKey, stored['sealed'], key);
    if (opened == null) {
      return null;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(opened);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    final Map<String, dynamic> data = decoded;
    final Object? config = data['config'];
    if (config is! Map<String, dynamic>) {
      return null;
    }
    final Object? icons = data['group_icons'];
    final Object? labels = data['node_labels'];
    final Object? groupLabels = data['group_labels'];
    try {
      return RemoteProfile(
        config: config,
        revision: data['revision'] as String? ?? '',
        groupIcons: <String, String>{
          if (icons is Map<String, dynamic>)
            for (final MapEntry<String, dynamic> e in icons.entries)
              if (e.value is String) e.key: e.value as String,
        },
        groupLabels: <String, String>{
          if (groupLabels is Map<String, dynamic>)
            for (final MapEntry<String, dynamic> e in groupLabels.entries)
              if (e.value is String) e.key: e.value as String,
        },
        nodeLabels: <String, String>{
          if (labels is Map<String, dynamic>)
            for (final MapEntry<String, dynamic> e in labels.entries)
              if (e.value is String) e.key: e.value as String,
        },
        flagRegex: data['flag_regex'] as String? ?? '',
        offlineIssuedAt: data['offline_issued_at'] is int
            ? DateTime.fromMillisecondsSinceEpoch(
                data['offline_issued_at'] as int,
              )
            : null,
        offlineUntil: data['offline_until'] is int
            ? DateTime.fromMillisecondsSinceEpoch(data['offline_until'] as int)
            : null,
        cacheBinding: data['cache_binding'] as String? ?? '',
        updateInterval: RemoteProfile.parseUpdateInterval(
          data['update_interval_hours']?.toString(),
        ),
      );
    } on Object {
      return null;
    }
  }
}
