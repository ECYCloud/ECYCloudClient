import 'package:flutter/foundation.dart';

import '../core/app_config.dart';
import '../core/logger.dart';
import '../data/api/api_exception.dart';
import '../data/api/panel_api_client.dart';
import '../data/models/account.dart';
import '../data/models/user_profile.dart';
import '../data/store/credential_store.dart';
import '../data/store/panel_response_cache.dart';
import '../domain/platform/platform_service.dart';

enum AuthStage {
  unknown,
  loggedOut,
  needsTwoFactor,
  loggedIn,
  accountRestricted,
}

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
  // 明文遗留项无此外缀；改此外缀会导致已保存的密码无法解
  static const String _rememberedPrefix = 'ecy1:';
  static const String _secretPassword = 'remembered_password';
  static const String _secretToken = 'token';

  final PlatformService _platform;
  final CredentialStore _credentials;
  final PanelResponseCache _cache;

  AuthStage _stage = AuthStage.unknown;
  UserProfile? _profile;
  AccountStatus? _accountStatus;
  PanelApiClient? _api;
  String? _error;
  bool _busy = false;
  DateTime? _profileCooldownUntil;
  String? _apiOrigin;
  String? _siteOrigin;

  void Function(String revision)? onConfigRevision;
  void Function()? onIpKickNotice;

  AuthStage get stage => _stage;

  UserProfile? get profile => _profile;

  AccountStatus? get accountStatus => _accountStatus;

  PanelApiClient? get api => _api;

  String get apiOrigin =>
      _apiOrigin ??
      _asOrigin(_credentials.loadApiOrigin()) ??
      AppConfig.subOrigin;

  String get siteOrigin =>
      _siteOrigin ??
      _asOrigin(_credentials.loadSiteOrigin()) ??
      AppConfig.siteOrigin;

  String? get error => _error;

  bool get busy => _busy;

  /// 当前会话账号键（邮箱）；profile 尚未拉到时用本地凭据里的邮箱
  String? get accountKey {
    final String? fromProfile = _profile?.email;
    if (fromProfile != null && fromProfile.isNotEmpty) {
      return fromProfile;
    }
    final String? fromStatus = _accountStatus?.email;
    if (fromStatus != null && fromStatus.isNotEmpty) {
      return fromStatus;
    }
    final String? fromCreds = _credentials.load()?.email;
    if (fromCreds != null && fromCreds.isNotEmpty) {
      return fromCreds;
    }
    return null;
  }

  Future<RememberedLogin?> loadRememberedLogin() async {
    final RememberedLogin? saved = _credentials.loadRemembered();
    if (saved == null) {
      return null;
    }
    final String stored = saved.password;
    if (stored.isNotEmpty && !stored.startsWith(_rememberedPrefix)) {
      await saveRememberedLogin(email: saved.email, password: stored);
      return saved;
    }
    final String? plain = await _revealSecret(_secretPassword, stored);
    return RememberedLogin(email: saved.email, password: plain ?? '');
  }

  Future<void> saveRememberedLogin({
    required String email,
    required String password,
  }) async {
    try {
      final String blob = await _platform.protectSecret(
        _secretPassword,
        password,
      );
      _credentials.saveRemembered(
        email: email,
        password: '$_rememberedPrefix$blob',
      );
    } on Object catch (e) {
      Logger.instance.warn(_source, '记住密码写入失败: $e');
      await _deleteRememberedSecret();
      _credentials.clearRemembered();
    }
  }

  Future<void> clearRememberedLogin() async {
    await _deleteRememberedSecret();
    _credentials.clearRemembered();
  }

  Future<void> _deleteRememberedSecret() async {
    try {
      await _platform.deleteSecret(_secretPassword);
    } on Object catch (e) {
      Logger.instance.warn(_source, '清除记住的密码失败: $e');
    }
  }

  Future<String?> _revealSecret(String name, String stored) async {
    if (stored.isEmpty) {
      return stored;
    }
    if (!stored.startsWith(_rememberedPrefix)) {
      return stored;
    }
    try {
      return await _platform.unprotectSecret(
        name,
        stored.substring(_rememberedPrefix.length),
      );
    } on Object catch (e) {
      Logger.instance.warn(_source, '读取凭据失败: $e');
      return null;
    }
  }

  Future<void> _persistSessionSecret({
    required String token,
    required DateTime expiresAt,
    required String email,
  }) async {
    try {
      final String blob = await _platform.protectSecret(_secretToken, token);
      _credentials.save(
        Credentials(
          token: '$_rememberedPrefix$blob',
          expiresAt: expiresAt,
          email: email,
        ),
      );
    } on Object catch (e) {
      Logger.instance.warn(_source, '会话凭据写入失败: $e');
    }
  }

  Future<void> _clearSessionSecret() async {
    try {
      await _platform.deleteSecret(_secretToken);
    } on Object catch (e) {
      Logger.instance.warn(_source, '清除会话凭据失败: $e');
    }
    _credentials.clear();
  }

  Future<void> restore() async {
    final Credentials? saved = _credentials.load();
    if (saved == null || !saved.valid) {
      _set(AuthStage.loggedOut);
      return;
    }

    final String? token = await _revealSecret(_secretToken, saved.token);
    if (token == null || token.isEmpty) {
      await _clearSessionSecret();
      _set(AuthStage.loggedOut);
      return;
    }
    if (!saved.token.startsWith(_rememberedPrefix)) {
      await _persistSessionSecret(
        token: token,
        expiresAt: saved.expiresAt,
        email: saved.email,
      );
    }

    final PanelApiClient client = await _clientForRequest();
    client.token = token;
    _api = client;
    _error = null;

    try {
      final AccountStatus status = await client.fetchAccountStatus();
      if (!status.isNormal) {
        _accountStatus = status;
        _profile ??= _cache.loadProfile(saved.email);
        await _loadProfileBestEffort(client);
        _set(AuthStage.accountRestricted);
        return;
      }

      // 先凭本地凭据进界面。拉 profile 要走网络，隧道不通时要耗满 20 秒超时，
      // 期间界面停在启动图上一片空白；缓存里的资料先顶着，真实资料随后覆盖
      _accountStatus = null;
      _profile ??= _cache.loadProfile(saved.email);
      _emitConfigRevision(_profile);
      _set(AuthStage.loggedIn);

      await _applyProfile(await _fetchProfile(client));
    } on ApiException catch (e) {
      if (e.unauthorized) {
        client.close();
        _api = null;
        _profile = null;
        _accountStatus = null;
        await _clearSessionSecret();
        _set(AuthStage.loggedOut);
        return;
      }
      // 429 / 网络错误：凭据仍有效。绝不能清 token 或把限流文案丢到登录页。
      Logger.instance.warn(_source, '恢复会话失败，稍后重试: $e');
      _profile ??= _cache.loadProfile(saved.email);
      if (_profile != null) {
        _emitConfigRevision(_profile);
        _set(AuthStage.loggedIn);
        _scheduleProfileRetry();
      } else {
        _set(AuthStage.loggedOut);
      }
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

    final PanelApiClient client = await _clientForRequest();

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

  Future<bool> register({
    required String name,
    required String email,
    required String passwd,
    required String repasswd,
    String code = '',
    String emailcode = '',
  }) {
    return _authenticate(
      email: email,
      run: (PanelApiClient client) => client.register(
        name: name,
        email: email,
        passwd: passwd,
        repasswd: repasswd,
        code: code,
        emailcode: emailcode,
      ),
    );
  }

  Future<AuthOptions?> fetchAuthOptions() async {
    try {
      final PanelApiClient client = await _clientForRequest();
      try {
        final AuthOptions options = await client.fetchAuthOptions();
        _applyApiOrigin(options.apiOrigin);
        _applySiteOrigin(options.siteOrigin);
        return options;
      } finally {
        if (!identical(client, _api)) {
          client.close();
        }
      }
    } on ApiException catch (e) {
      _error = e.message;
      notifyListeners();
      return null;
    }
  }

  Future<bool> sendRegisterVerify({required String email}) async {
    _busy = true;
    _error = null;
    notifyListeners();

    final PanelApiClient client = await _clientForRequest();

    try {
      await client.sendRegisterVerify(email: email);
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

  Future<bool> requestPasswordReset({required String email}) async {
    _busy = true;
    _error = null;
    notifyListeners();

    final PanelApiClient client = await _clientForRequest();

    try {
      await client.requestPasswordReset(email: email);
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

  Future<bool> confirmPasswordReset({
    required String email,
    required String token,
    required String password,
    required String repasswd,
  }) {
    return _authenticate(
      email: email,
      run: (PanelApiClient client) => client.confirmPasswordReset(
        token: token,
        password: password,
        repasswd: repasswd,
      ),
    );
  }

  Future<bool> _authenticate({
    required String email,
    required Future<LoginResult> Function(PanelApiClient client) run,
  }) async {
    _busy = true;
    _error = null;
    notifyListeners();

    final PanelApiClient client = await _clientForRequest();

    try {
      final LoginResult result = await run(client);
      final String accountEmail =
          result.profile?.email.isNotEmpty == true
          ? result.profile!.email
          : (result.accountStatus?.email.isNotEmpty == true
                ? result.accountStatus!.email
                : email);

      await _persistSessionSecret(
        token: result.token,
        expiresAt: result.expiresAt,
        email: accountEmail,
      );

      _api = client;
      _profileCooldownUntil = null;

      if (result.isRestricted) {
        _accountStatus = result.accountStatus;
        await _loadProfileBestEffort(client);
        _busy = false;
        _set(AuthStage.accountRestricted);
        return true;
      }

      final UserProfile? profile = result.profile;
      if (profile == null) {
        client.close();
        _api = null;
        await _clearSessionSecret();
        _busy = false;
        _error = '登录响应缺少用户资料';
        _set(AuthStage.loggedOut);
        return false;
      }

      _accountStatus = null;
      await _applyProfile(profile);
      _busy = false;
      // 注册 / 登录 / 重置密码成功后立刻进主界面，避免页面 delay + mounted 竞态卡住加载
      _set(AuthStage.loggedIn);
      return true;
    } on ApiException catch (e) {
      client.close();
      _busy = false;
      _error = e.message;
      _set(e.needsTwoFactor ? AuthStage.needsTwoFactor : AuthStage.loggedOut);
      return false;
    } catch (e) {
      client.close();
      _busy = false;
      _error = '登录失败：$e';
      _set(AuthStage.loggedOut);
      return false;
    }
  }

  void enterShell() {
    if (_api == null || _profile == null) {
      return;
    }
    _accountStatus = null;
    _set(AuthStage.loggedIn);
  }

  void enterRestricted(AccountStatus status) {
    _accountStatus = status;
    _profileCooldownUntil = null;
    _set(AuthStage.accountRestricted);
  }

  Future<String> cancelAccountDeletion() async {
    final PanelApiClient? client = _api;
    if (client == null) {
      throw ApiException('未登录');
    }
    final ({String message, AccountStatus status, UserProfile profile}) result =
        await client.cancelAccountDeletion();
    _accountStatus = null;
    _profile = result.profile;
    final String? key = accountKey;
    if (key != null) {
      _cache.saveProfile(key, result.profile);
    }
    _emitConfigRevision(_profile);
    _set(AuthStage.loggedIn);
    return result.message;
  }

  Future<void> logout() async {
    await _api?.logout();
    _api?.close();
    _api = null;
    _profile = null;
    _accountStatus = null;
    _profileCooldownUntil = null;
    await _clearSessionSecret();
    _set(AuthStage.loggedOut);
  }

  Future<void> refreshProfile() async {
    final PanelApiClient? client = _api;
    if (client == null) {
      return;
    }

    try {
      await _applyProfile(await _fetchProfile(client));
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

  Future<String> checkin() async {
    final PanelApiClient? client = _api;
    if (client == null) {
      throw ApiException('未登录');
    }
    final ({String message, UserProfile profile}) result =
        await client.checkin();
    await _applyProfile(result.profile);
    return result.message;
  }

  Future<void> _applyProfile(UserProfile profile) async {
    _profile = profile;
    _applyApiOrigin(profile.apiOrigin);
    _applySiteOrigin(profile.siteOrigin);
    final String? key = accountKey;
    if (key != null) {
      _cache.saveProfile(key, profile);
    }
    _emitConfigRevision(profile);
    if (profile.ipKickNotice) {
      onIpKickNotice?.call();
    }
    notifyListeners();
  }

  Future<void> _loadProfileBestEffort(PanelApiClient client) async {
    try {
      final UserProfile profile = await _fetchProfile(client);
      await _applyProfile(profile);
    } on ApiException catch (e) {
      Logger.instance.warn(_source, '拉取账号资料失败: $e');
      final String? key = accountKey;
      if (_profile == null && key != null) {
        _profile = _cache.loadProfile(key);
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

  Future<DeviceInfo> _device() async => DeviceInfo(
    platform: _platform.platformId,
    deviceId: _credentials.deviceId(),
    deviceName: await _platform.deviceName(),
    appVersion: AppConfig.appVersion,
  );

  Future<PanelApiClient> _clientForRequest() async {
    final String site = siteOrigin;
    final String api = apiOrigin;
    if (site.isEmpty) {
      throw ApiException('构建缺少站点域名');
    }
    if (api.isEmpty) {
      throw ApiException('构建缺少订阅域名');
    }
    _siteOrigin ??= site;
    _apiOrigin ??= api;
    return _newClient(site: site, api: api, device: await _device());
  }

  PanelApiClient _newClient({
    required String site,
    required String api,
    required DeviceInfo device,
    String? token,
  }) {
    return PanelApiClient(
      baseUrl: site,
      configBaseUrl: api,
      device: device,
    )..token = token;
  }

  void _rebuildClient() {
    final PanelApiClient? old = _api;
    if (old == null) {
      return;
    }
    _api = _newClient(
      site: siteOrigin,
      api: apiOrigin,
      device: old.device,
      token: old.token,
    );
    old.close();
  }

  void _applyApiOrigin(String raw) {
    final String? origin = _asOrigin(raw);
    if (origin == null || origin == _apiOrigin) {
      return;
    }
    _apiOrigin = origin;
    _credentials.saveApiOrigin(origin);
    _rebuildClient();
  }

  void _applySiteOrigin(String raw) {
    final String? origin = _asOrigin(raw);
    if (origin == null || origin == _siteOrigin) {
      return;
    }
    _siteOrigin = origin;
    _credentials.saveSiteOrigin(origin);
    _rebuildClient();
  }

  static String? _asOrigin(String? raw) {
    if (raw == null) {
      return null;
    }
    final String trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final Uri? uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) {
      return null;
    }
    return uri.origin;
  }

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
