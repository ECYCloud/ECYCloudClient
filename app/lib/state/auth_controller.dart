import 'package:flutter/foundation.dart';

import '../core/app_config.dart';
import '../core/logger.dart';
import '../data/api/api_exception.dart';
import '../data/api/panel_api_client.dart';
import '../data/models/user_profile.dart';
import '../data/store/credential_store.dart';
import '../domain/platform/platform_service.dart';

enum AuthStage { unknown, loggedOut, needsTwoFactor, loggedIn }

class AuthController extends ChangeNotifier {
  AuthController(this._platform, this._credentials);

  static const String _source = 'auth';

  final PlatformService _platform;
  final CredentialStore _credentials;

  AuthStage _stage = AuthStage.unknown;
  UserProfile? _profile;
  PanelApiClient? _api;
  String? _error;
  bool _busy = false;

  AuthStage get stage => _stage;

  UserProfile? get profile => _profile;

  PanelApiClient? get api => _api;

  String? get error => _error;

  bool get busy => _busy;

  Future<void> restore() async {
    final Credentials? saved = _credentials.load();
    if (saved == null || !saved.valid) {
      _set(AuthStage.loggedOut);
      return;
    }

    final PanelApiClient client = await _buildClient();
    client.token = saved.token;

    try {
      _profile = await client.fetchProfile();
      _api = client;
      _set(AuthStage.loggedIn);
    } on ApiException catch (e) {
      client.close();
      if (e.unauthorized) {
        _credentials.clear();
        _set(AuthStage.loggedOut);
      } else {
        // 非鉴权失败（如网络不通）必须保留凭据，否则用户会被迫重新登录
        Logger.instance.warn(_source, '恢复会话失败，稍后重试: $e');
        _error = e.message;
        _set(AuthStage.loggedOut);
      }
    }
  }

  Future<bool> login({
    required String email,
    required String password,
    String? twoFactorCode,
  }) async {
    _busy = true;
    _error = null;
    notifyListeners();

    final PanelApiClient client = await _buildClient();

    try {
      final LoginResult result = await client.login(
        email: email,
        password: password,
        twoFactorCode: twoFactorCode,
      );

      _credentials.save(
        Credentials(
          token: result.token,
          expiresAt: result.expiresAt,
          email: email,
        ),
      );

      _api = client;
      _profile = result.profile;
      _busy = false;
      _set(AuthStage.loggedIn);
      return true;
    } on ApiException catch (e) {
      client.close();
      _busy = false;
      _error = e.message;
      _set(e.needsTwoFactor ? AuthStage.needsTwoFactor : AuthStage.loggedOut);
      return false;
    }
  }

  Future<void> logout() async {
    await _api?.logout();
    _api?.close();
    _api = null;
    _profile = null;
    _credentials.clear();
    _set(AuthStage.loggedOut);
  }

  Future<void> refreshProfile() async {
    final PanelApiClient? client = _api;
    if (client == null) {
      return;
    }

    try {
      _profile = await client.fetchProfile();
      notifyListeners();
    } on ApiException catch (e) {
      if (e.unauthorized) {
        await logout();
      } else {
        Logger.instance.warn(_source, '刷新账号信息失败: $e');
      }
    }
  }

  Future<PanelApiClient> _buildClient() async => PanelApiClient(
    baseUrl: AppConfig.panelBaseUrl,
    device: DeviceInfo(
      platform: _platform.platformId,
      deviceId: _credentials.deviceId(),
      deviceName: await _platform.deviceName(),
      appVersion: AppConfig.appVersion,
    ),
  );

  void _set(AuthStage stage) {
    _stage = stage;
    notifyListeners();
  }

  @override
  void dispose() {
    _api?.close();
    super.dispose();
  }
}
