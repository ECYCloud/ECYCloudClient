import 'package:flutter/foundation.dart';

import '../core/app_config.dart';
import '../core/logger.dart';
import '../data/api/api_exception.dart';
import '../data/api/panel_api_client.dart';
import '../data/models/user_profile.dart';
import '../data/store/credential_store.dart';
import '../data/store/panel_response_cache.dart';
import '../domain/platform/platform_service.dart';

enum AuthStage { unknown, loggedOut, needsTwoFactor, loggedIn }

class AuthController extends ChangeNotifier {
  AuthController(
    this._platform,
    this._credentials, {
    PanelResponseCache? cache,
  }) : _cache = cache ?? PanelResponseCache();

  static const String _source = 'auth';
  // 与 Website ClientApiRateLimit 一致：60s 窗口；缺 Retry-After 时的退避兜底
  static const Duration _rateLimitFallback = Duration(seconds: 6);
  static const int _rateLimitWindowSeconds = 60;

  final PlatformService _platform;
  final CredentialStore _credentials;
  final PanelResponseCache _cache;

  AuthStage _stage = AuthStage.unknown;
  UserProfile? _profile;
  PanelApiClient? _api;
  String? _error;
  bool _busy = false;
  DateTime? _profileCooldownUntil;

  void Function(String revision)? onConfigRevision;

  AuthStage get stage => _stage;

  UserProfile? get profile => _profile;

  PanelApiClient? get api => _api;

  String? get error => _error;

  bool get busy => _busy;

  /// 当前会话账号键（邮箱）；profile 尚未拉到时用本地凭据里的邮箱
  String? get accountKey {
    final String? fromProfile = _profile?.email;
    if (fromProfile != null && fromProfile.isNotEmpty) {
      return fromProfile;
    }
    final String? fromCreds = _credentials.load()?.email;
    if (fromCreds != null && fromCreds.isNotEmpty) {
      return fromCreds;
    }
    return null;
  }

  Future<void> restore() async {
    final Credentials? saved = _credentials.load();
    if (saved == null || !saved.valid) {
      _set(AuthStage.loggedOut);
      return;
    }

    final PanelApiClient client = await _buildClient();
    client.token = saved.token;
    _api = client;
    _error = null;

    // 先凭本地凭据进界面。拉 profile 要走网络，隧道不通时要耗满 20 秒超时，
    // 期间界面停在启动图上一片空白；缓存里的资料先顶着，真实资料随后覆盖
    _profile ??= _cache.loadProfile(saved.email);
    _emitConfigRevision(_profile);
    _set(AuthStage.loggedIn);

    try {
      _profile = await _fetchProfile(client);
      _cache.saveProfile(saved.email, _profile!);
      _emitConfigRevision(_profile);
      notifyListeners();
    } on ApiException catch (e) {
      if (e.unauthorized) {
        client.close();
        _api = null;
        _profile = null;
        _credentials.clear();
        _set(AuthStage.loggedOut);
        return;
      }
      // 429 / 网络错误：凭据仍有效。绝不能清 token 或把限流文案丢到登录页。
      Logger.instance.warn(_source, '恢复会话失败，稍后重试: $e');
      _scheduleProfileRetry();
    }
  }

  Future<bool> login({
    required String email,
    required String password,
    String? twoFactorCode,
  }) async {
    return _authenticate(
      email: email,
      run: (PanelApiClient client) => client.login(
        email: email,
        password: password,
        twoFactorCode: twoFactorCode,
      ),
    );
  }

  Future<bool> sendLoginVerify({required String email}) async {
    _busy = true;
    _error = null;
    notifyListeners();

    final PanelApiClient client = await _buildClient();

    try {
      await client.sendLoginVerify(email: email);
      client.close();
      _busy = false;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      client.close();
      _busy = false;
      _error = e.message;
      notifyListeners();
      return false;
    }
  }

  Future<bool> loginWithVerifyCode({
    required String email,
    required String code,
  }) async {
    return _authenticate(
      email: email,
      run: (PanelApiClient client) =>
          client.loginWithVerifyCode(email: email, code: code),
    );
  }

  Future<bool> _authenticate({
    required String email,
    required Future<LoginResult> Function(PanelApiClient client) run,
  }) async {
    _busy = true;
    _error = null;
    notifyListeners();

    final PanelApiClient client = await _buildClient();

    try {
      final LoginResult result = await run(client);

      _credentials.save(
        Credentials(
          token: result.token,
          expiresAt: result.expiresAt,
          email: email,
        ),
      );

      _api = client;
      _profile = result.profile;
      _cache.saveProfile(email, result.profile);
      _profileCooldownUntil = null;
      _emitConfigRevision(_profile);
      _busy = false;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      client.close();
      _busy = false;
      _error = e.message;
      _set(e.needsTwoFactor ? AuthStage.needsTwoFactor : AuthStage.loggedOut);
      return false;
    }
  }

  void enterShell() {
    if (_api == null || _profile == null) {
      return;
    }
    _set(AuthStage.loggedIn);
  }

  Future<void> logout() async {
    await _api?.logout();
    _api?.close();
    _api = null;
    _profile = null;
    _profileCooldownUntil = null;
    _credentials.clear();
    _set(AuthStage.loggedOut);
  }

  Future<void> refreshProfile() async {
    final PanelApiClient? client = _api;
    if (client == null) {
      return;
    }

    try {
      _profile = await _fetchProfile(client);
      final String? key = accountKey;
      if (key != null) {
        _cache.saveProfile(key, _profile!);
      }
      _emitConfigRevision(_profile);
      notifyListeners();
    } on ApiException catch (e) {
      if (e.unauthorized) {
        await logout();
      } else {
        Logger.instance.warn(_source, '刷新账号信息失败: $e');
        if (e.rateLimited) {
          _scheduleProfileRetry();
        }
      }
    }
  }

  Future<UserProfile> _fetchProfile(PanelApiClient client) async {
    final DateTime? until = _profileCooldownUntil;
    if (until != null && DateTime.now().isBefore(until)) {
      throw ApiException(
        '请求过于频繁，请稍后再试',
        statusCode: 429,
        retryAfterSeconds: until
            .difference(DateTime.now())
            .inSeconds
            .clamp(1, _rateLimitWindowSeconds),
      );
    }
    try {
      final UserProfile profile = await client.fetchProfile();
      _profileCooldownUntil = null;
      return profile;
    } on ApiException catch (e) {
      if (e.rateLimited) {
        final int seconds =
            e.retryAfterSeconds ?? _rateLimitFallback.inSeconds;
        _profileCooldownUntil = DateTime.now().add(
          Duration(seconds: seconds.clamp(1, _rateLimitWindowSeconds)),
        );
      }
      rethrow;
    }
  }

  void _scheduleProfileRetry() {
    final DateTime? until = _profileCooldownUntil;
    final Duration delay = until == null
        ? _rateLimitFallback
        : until.difference(DateTime.now());
    Future<void>.delayed(delay.isNegative ? Duration.zero : delay, () async {
      if (_api == null || _stage != AuthStage.loggedIn) {
        return;
      }
      await refreshProfile();
    });
  }

  void _emitConfigRevision(UserProfile? profile) {
    final String revision = profile?.configRevision ?? '';
    if (revision.isEmpty) {
      return;
    }
    onConfigRevision?.call(revision);
  }

  Future<PanelApiClient> _buildClient() async => PanelApiClient(
    baseUrl: AppConfig.panelBaseUrl,
    configBaseUrl: AppConfig.subOrigin,
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
