import '../../core/app_paths.dart';
import '../api/panel_api_client.dart';
import '../models/user_profile.dart';
import 'json_file_store.dart';

class PanelResponseCache {
  PanelResponseCache({JsonFileStore? profileStore, JsonFileStore? remoteStore})
    : _profile =
          profileStore ?? JsonFileStore(AppPaths.profileCache, 'profile-cache'),
      _remote =
          remoteStore ??
          JsonFileStore(AppPaths.remoteConfigCache, 'remote-cache');

  final JsonFileStore _profile;
  final JsonFileStore _remote;

  void clear() {
    _profile.clear();
    _remote.clear();
  }

  // 缓存跨版本仍在原地；写入打内核标记，旧形状不能喂给装配
  static const String _kernel = 'mihomo';

  void saveProfile(String accountKey, UserProfile profile) {
    final String key = accountKey.trim().toLowerCase();
    if (key.isEmpty) {
      return;
    }
    _profile.write(<String, dynamic>{
      'account': key,
      'profile': profile.toJson(),
    });
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

  void saveRemote(String accountKey, RemoteProfile remote) {
    final String key = accountKey.trim().toLowerCase();
    if (key.isEmpty) {
      return;
    }
    _remote.write(<String, dynamic>{
      'account': key,
      'kernel': _kernel,
      'revision': remote.revision,
      'flag_regex': remote.flagRegex,
      'group_icons': remote.groupIcons,
      'node_labels': remote.nodeLabels,
      'group_labels': remote.groupLabels,
      'config': remote.config,
      'offline_issued_at': remote.offlineIssuedAt?.millisecondsSinceEpoch,
      'offline_until': remote.offlineUntil?.millisecondsSinceEpoch,
      'cache_binding': remote.cacheBinding,
    });
  }

  RemoteProfile? loadRemote(String accountKey) {
    final String key = accountKey.trim().toLowerCase();
    if (key.isEmpty) {
      return null;
    }
    final Map<String, dynamic> data = _remote.read();
    if ((data['account'] as String? ?? '').toLowerCase() != key ||
        data['kernel'] != _kernel) {
      return null;
    }
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
      );
    } on Object {
      return null;
    }
  }
}
