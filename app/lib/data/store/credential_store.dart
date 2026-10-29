import 'dart:io';
import 'dart:math';

import '../../core/app_paths.dart';
import '../../l10n/l10n.dart';
import 'json_file_store.dart';

class Credentials {
  const Credentials({
    required this.token,
    required this.expiresAt,
    required this.email,
  });

  final String token;
  final DateTime expiresAt;
  final String email;

  bool get valid => token.isNotEmpty && expiresAt.isAfter(DateTime.now());
}

class RememberedLogin {
  const RememberedLogin({required this.email, required this.password});

  final String email;
  final String password;
}

class CredentialStore {
  CredentialStore({JsonFileStore? store})
    : _store = store ?? JsonFileStore(AppPaths.credentials, 'credential');

  final JsonFileStore _store;

  File get _sessionMarker => File('${_store.file.path}.session-ending');

  bool get sessionCleanupPending =>
      FileSystemEntity.typeSync(_sessionMarker.path, followLinks: false) !=
      FileSystemEntityType.notFound;

  void beginSessionCleanup() {
    final FileSystemEntityType type = FileSystemEntity.typeSync(
      _sessionMarker.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw FileSystemException(L10n.t('会话清理标记不是普通文件'), _sessionMarker.path);
    }
    _sessionMarker.writeAsStringSync('1', flush: true);
  }

  void finishSessionCleanup() {
    if (sessionCleanupPending) {
      _sessionMarker.deleteSync();
    }
  }

  Credentials? load() {
    final Map<String, dynamic> data = _store.read();
    final String? token = data['token'] as String?;
    final String? expiresAt = data['expires_at'] as String?;

    if (token == null || expiresAt == null) {
      return null;
    }

    final DateTime? parsed = DateTime.tryParse(expiresAt);
    if (parsed == null) {
      return null;
    }

    return Credentials(
      token: token,
      expiresAt: parsed,
      email: data['email'] as String? ?? '',
    );
  }

  void save(Credentials credentials) {
    final Map<String, dynamic> data = _store.read()
      ..['token'] = credentials.token
      ..['expires_at'] = credentials.expiresAt.toIso8601String()
      ..['email'] = credentials.email;
    _store.write(data);
  }

  RememberedLogin? loadRemembered() {
    final Map<String, dynamic> data = _store.read();
    if (data['remember'] != true) {
      return null;
    }
    final String email = data['remembered_email'] as String? ?? '';
    if (email.isEmpty) {
      return null;
    }
    return RememberedLogin(
      email: email,
      password: data['password'] as String? ?? '',
    );
  }

  void saveRemembered({required String email, required String password}) {
    final Map<String, dynamic> data = _store.read()
      ..['remember'] = true
      ..['remembered_email'] = email
      ..['password'] = password;
    _store.write(data);
  }

  void clearRemembered() {
    final Map<String, dynamic> data = _store.read()
      ..remove('remember')
      ..remove('remembered_email')
      ..remove('password');
    _store.write(data);
  }

  // 设备标识必须保留，面板靠它识别同一台机器
  void clear() {
    final Map<String, dynamic> data = _store.read()
      ..remove('token')
      ..remove('expires_at');
    _store.write(data);
  }

  String deviceId() {
    final Map<String, dynamic> data = _store.read();
    final String? existing = data['device_id'] as String?;
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }

    final Random random = Random.secure();
    final String generated = List<String>.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();

    data['device_id'] = generated;
    _store.write(data);
    return generated;
  }

  String? loadApiOrigin() {
    final String? origin = _store.read()['api_origin'] as String?;
    if (origin == null || origin.isEmpty) {
      return null;
    }
    return origin;
  }

  void saveApiOrigin(String origin) {
    final Map<String, dynamic> data = _store.read()..['api_origin'] = origin;
    _store.write(data);
  }

  void clearApiOrigin() {
    final Map<String, dynamic> data = _store.read()..remove('api_origin');
    _store.write(data);
  }

  String? loadSiteOrigin() {
    final String? origin = _store.read()['site_origin'] as String?;
    if (origin == null || origin.isEmpty) {
      return null;
    }
    return origin;
  }

  void saveSiteOrigin(String origin) {
    final Map<String, dynamic> data = _store.read()..['site_origin'] = origin;
    _store.write(data);
  }

  void clearSiteOrigin() {
    final Map<String, dynamic> data = _store.read()..remove('site_origin');
    _store.write(data);
  }
}
