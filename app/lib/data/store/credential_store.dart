import 'dart:math';

import '../../core/app_paths.dart';
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

class CredentialStore {
  CredentialStore()
    : _store = JsonFileStore(AppPaths.credentials, 'credential');

  final JsonFileStore _store;

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
}
