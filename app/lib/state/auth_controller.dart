import 'package:flutter/foundation.dart';

import '../core/app_config.dart';
import '../core/app_paths.dart';
import '../core/logger.dart';
import '../data/api/api_exception.dart';
import '../data/api/panel_api_client.dart';
import '../data/models/account.dart';
import '../data/models/user_profile.dart';
import '../data/store/credential_store.dart';
import '../data/store/json_file_store.dart';
import '../data/store/panel_response_cache.dart';
import '../domain/platform/platform_service.dart';
import '../l10n/app_language.dart';
import '../l10n/l10n.dart';

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
    required this._clearLocalSession,
    PanelResponseCache? cache,
    this._createClient,
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
  final Future<void> Function() _clearLocalSession;
  Future<void>? _logoutPending;
  Future<void>? _cleanupPending;
  Future<void>? _secretWritePending;
  Future<void>? _rememberedPending;
  int _rememberedGeneration = 0;
  final PanelApiClient Function(String site, String api, DeviceInfo device)?
  _createClient;
  final JsonFileStore _ticketInbox = JsonFileStore(
    AppPaths.ticketInbox,
    'ticket',
  );

  AuthStage _stage = AuthStage.unknown;
  UserProfile? _profile;
  AccountStatus? _accountStatus;
  PanelApiClient? _api;
  String? _error;
  bool _busy = false;
  bool _sendingCode = false;
  int _sessionGeneration = 0;
  DateTime? _profileCooldownUntil;
  String? _apiOrigin;
  String? _siteOrigin;

  void Function(String revision)? onConfigRevision;
  void Function()? onDeviceKickNotice;

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

  bool get sendingCode => _sendingCode;

  bool get hasUnreadTicketReply {
    final UserProfile? profile = _profile;
    if (profile == null) {
      return false;
    }
    return ticketReplyUnread(
      latestAdminReplyAt: profile.latestAdminReplyAt,
      userId: profile.id,
      seen: _ticketInbox.read(),
    );
  }

  static bool ticketReplyUnread({
    required String latestAdminReplyAt,
    required int userId,
    required Map<String, dynamic> seen,
  }) {
    if (latestAdminReplyAt.isEmpty) {
      return false;
    }
    final Object? seenUser = seen['user_id'];
    final int? seenUserId = seenUser is num ? seenUser.toInt() : null;
    if (seenUserId != userId) {
      return false;
    }
    final String seenAt = seen['seen_admin_reply_at'] as String? ?? '';
    return latestAdminReplyAt.compareTo(seenAt) > 0;
  }

  void markTicketsSeen() {
    final UserProfile? profile = _profile;
    if (profile == null) {
      return;
    }
    final Map<String, dynamic> seen = _ticketInbox.read();
    if (seen['user_id'] == profile.id &&
        !ticketReplyUnread(
          latestAdminReplyAt: profile.latestAdminReplyAt,
          userId: profile.id,
          seen: seen,
        )) {
      return;
    }
    _ticketInbox.write(<String, dynamic>{
      'user_id': profile.id,
      'seen_admin_reply_at': profile.latestAdminReplyAt,
    });
    notifyListeners();
  }

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
    while (_rememberedPending != null) {
      await _rememberedPending;
    }
    final RememberedLogin? saved = _credentials.loadRemembered();
    if (saved == null) {
      await clearRememberedLogin();
      return null;
    }
    final String stored = saved.password;
    if (stored.isNotEmpty && !stored.startsWith(_rememberedPrefix)) {
      await saveRememberedLogin(email: saved.email, password: stored);
      return loadRememberedLogin();
    }
    final int generation = _rememberedGeneration;
    final String? plain = await _revealSecret(_secretPassword, stored);
    if (generation != _rememberedGeneration) {
      return null;
    }
    return RememberedLogin(email: saved.email, password: plain ?? '');
  }

  Future<void> saveRememberedLogin({
    required String email,
    required String password,
  }) => _changeRemembered(() async {
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
      rethrow;
    }
  });

  Future<void> clearRememberedLogin() => _changeRemembered(() async {
    await _deleteRememberedSecret();
    _credentials.clearRemembered();
  });

  Future<void> _changeRemembered(Future<void> Function() change) async {
    _rememberedGeneration++;
    final Future<void>? previous = _rememberedPending;
    final Future<void> pending = () async {
      try {
        await previous;
      } on Object {
        // 之前的失败不得阻止用户再次尝试清除。
      }
      await change();
    }();
    _rememberedPending = pending;
    try {
      await pending;
    } finally {
      if (identical(pending, _rememberedPending)) {
        _rememberedPending = null;
      }
    }
  }

  Future<void> _deleteRememberedSecret() =>
      _platform.deleteSecret(_secretPassword);

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
    required int generation,
    required String token,
    required DateTime expiresAt,
    required String email,
  }) async {
    final Future<void> pending = _writeSessionSecret(
      generation: generation,
      token: token,
      expiresAt: expiresAt,
      email: email,
    );
    _secretWritePending = pending;
    try {
      await pending;
    } finally {
      if (identical(pending, _secretWritePending)) {
        _secretWritePending = null;
      }
    }
  }

  Future<void> _writeSessionSecret({
    required int generation,
    required String token,
    required DateTime expiresAt,
    required String email,
  }) async {
    try {
      final String blob = await _platform.protectSecret(_secretToken, token);
      if (generation != _sessionGeneration) {
        return;
      }
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
    await _platform.deleteSecret(_secretToken);
    _credentials.clear();
  }

  Future<void> restore() async {
    if (_busy) {
      return;
    }
    final int generation = ++_sessionGeneration;
    Credentials? saved;
    PanelApiClient? client;
    _busy = true;
    _error = null;
    notifyListeners();

    try {
      saved = _credentials.load();
      if (_credentials.sessionCleanupPending || saved == null || !saved.valid) {
        await logout();
        return;
      }

      final String? token = await _revealSecret(_secretToken, saved.token);
      if (generation != _sessionGeneration) {
        return;
      }
      if (token == null || token.isEmpty) {
        await logout();
        return;
      }
      Logger.instance.warn('boot', 'auth.secret');
      if (!saved.token.startsWith(_rememberedPrefix)) {
        await _persistSessionSecret(
          generation: generation,
          token: token,
          expiresAt: saved.expiresAt,
          email: saved.email,
        );
      }

      client = await _clientForRequest();
      if (generation != _sessionGeneration) {
        client.close();
        return;
      }
      client.token = token;
      _api = client;
      Logger.instance.warn('boot', 'auth.device');

      // 本机登录有效即凭缓存进界面，不等面板：面板请求在网络不通时要耗满超时，
      // 期间界面不能停在启动图上；账户状态与真实资料随后覆盖
      _profile = _cache.loadProfile(saved.email);
      _accountStatus = null;
      _emitConfigRevision(_profile);
      _set(AuthStage.loggedIn);

      final AccountStatus status = await client.fetchAccountStatus();
      if (!identical(client, _api)) {
        return;
      }
      Logger.instance.warn('boot', 'auth.accountStatus');
      if (!status.isNormal) {
        _accountStatus = status;
        _set(AuthStage.accountRestricted);
        await _loadProfileBestEffort(client);
        return;
      }

      _applyProfile(await _fetchProfile(client), client);
    } on Object catch (e) {
      if (generation != _sessionGeneration ||
          (client != null && !identical(client, _api))) {
        return;
      }
      if (e is ApiException && e.unauthorized) {
        await logout();
        return;
      }
      // 429 / 网络错误：凭据仍有效。绝不能清 token 或把限流文案丢到登录页。
      Logger.instance.warn(_source, '恢复会话失败，稍后重试: $e');
      if (_stage == AuthStage.unknown) {
        client?.close();
        _api = null;
        _error = L10n.t('暂时无法恢复登录，请稍后重试。');
      } else if (e is ApiException && e.transient) {
        _scheduleProfileRetry();
      }
    } finally {
      if (generation == _sessionGeneration) {
        _busy = false;
        notifyListeners();
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
    _sendingCode = true;
    _error = null;
    notifyListeners();

    final PanelApiClient client = await _clientForRequest();

    try {
      await client.sendLoginVerify(email: email);
      client.close();
      _sendingCode = false;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      client.close();
      _sendingCode = false;
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

  Future<String> fetchTos() =>
      _fetchLegalContent((client) => client.fetchTos());

  Future<String> fetchPrivacyPolicy() =>
      _fetchLegalContent((client) => client.fetchPrivacyPolicy());

  Future<String> _fetchLegalContent(
    Future<String> Function(PanelApiClient client) loadContent,
  ) async {
    final PanelApiClient client = await _clientForRequest();
    try {
      return await loadContent(client);
    } finally {
      if (!identical(client, _api)) {
        client.close();
      }
    }
  }

  Future<bool> sendRegisterVerify({required String email}) async {
    _sendingCode = true;
    _error = null;
    notifyListeners();

    final PanelApiClient client = await _clientForRequest();

    try {
      await client.sendRegisterVerify(email: email);
      client.close();
      _sendingCode = false;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      client.close();
      _sendingCode = false;
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
    Future<void> Function(String message)? onSuccess,
  }) {
    return _authenticate(
      email: email,
      run: (PanelApiClient client) => client.confirmPasswordReset(
        token: token,
        password: password,
        repasswd: repasswd,
      ),
      onSuccess: onSuccess,
    );
  }

  Future<bool> _authenticate({
    required String email,
    required Future<LoginResult> Function(PanelApiClient client) run,
    Future<void> Function(String message)? onSuccess,
  }) async {
    if (_busy) {
      return false;
    }
    final int generation = ++_sessionGeneration;
    _busy = true;
    _error = null;
    notifyListeners();

    PanelApiClient? client;
    try {
      await _clearPreviousSession();
      if (generation != _sessionGeneration) {
        return false;
      }
      client = await _clientForRequest();
      if (generation != _sessionGeneration) {
        client.close();
        return false;
      }
      final LoginResult result = await run(client);
      if (generation != _sessionGeneration) {
        client.close();
        return false;
      }
      if (onSuccess != null) {
        await onSuccess(result.message);
        if (generation != _sessionGeneration) {
          client.close();
          return false;
        }
      }
      final String accountEmail = result.profile?.email.isNotEmpty == true
          ? result.profile!.email
          : (result.accountStatus?.email.isNotEmpty == true
                ? result.accountStatus!.email
                : email);

      await _persistSessionSecret(
        generation: generation,
        token: result.token,
        expiresAt: result.expiresAt,
        email: accountEmail,
      );
      if (generation != _sessionGeneration) {
        client.close();
        return false;
      }

      _api = client;
      _profileCooldownUntil = null;

      if (result.isRestricted) {
        _accountStatus = result.accountStatus;
        await _loadProfileBestEffort(client);
        if (generation != _sessionGeneration) {
          return false;
        }
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
        _error = L10n.t('登录响应缺少用户资料');
        _set(AuthStage.loggedOut);
        return false;
      }

      _accountStatus = null;
      _applyProfile(profile, client);
      _busy = false;
      // 注册 / 登录 / 重置密码成功后立刻进主界面，避免页面 delay + mounted 竞态卡住加载
      _set(AuthStage.loggedIn);
      return true;
    } on ApiException catch (e) {
      client?.close();
      if (generation != _sessionGeneration) {
        return false;
      }
      _busy = false;
      _error = e.message;
      _set(e.needsTwoFactor ? AuthStage.needsTwoFactor : AuthStage.loggedOut);
      return false;
    } catch (e) {
      client?.close();
      if (generation != _sessionGeneration) {
        return false;
      }
      _busy = false;
      _error = L10n.t('登录失败：{0}', <Object>['$e']);
      _set(AuthStage.loggedOut);
      return false;
    }
  }

  void enterShell() {
    if (_api == null || _profile == null || _accountStatus != null) {
      return;
    }
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
      throw ApiException(L10n.t('未登录'));
    }
    final ({String message, AccountStatus status, UserProfile profile}) result =
        await client.cancelAccountDeletion();
    if (!identical(client, _api)) {
      throw ApiException(L10n.t('登录状态已变化，请重新操作'));
    }
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

  Future<void> logout({Future<void> Function()? beforeLogout}) async {
    final Future<void>? pending = _logoutPending;
    if (pending != null) {
      return pending;
    }
    final Future<void> current = _logout(beforeLogout: beforeLogout);
    _logoutPending = current;
    try {
      await current;
    } finally {
      _logoutPending = null;
    }
  }

  Future<void> _logout({Future<void> Function()? beforeLogout}) async {
    _sessionGeneration++;
    _busy = true;
    _error = null;
    try {
      if (beforeLogout != null) {
        await beforeLogout();
      }
      await _clearPreviousSession();
    } on Object catch (e) {
      _error = L10n.t('退出失败：{0}', <Object>['$e']);
      throw ApiException(_error!);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _clearPreviousSession() async {
    final Future<void>? pending = _cleanupPending;
    if (pending != null) {
      return pending;
    }
    final Future<void> current = _cleanupSession();
    _cleanupPending = current;
    try {
      await current;
    } finally {
      _cleanupPending = null;
    }
  }

  Future<void> _cleanupSession() async {
    final PanelApiClient? client = _api;
    _api = null;
    _profile = null;
    _accountStatus = null;
    _profileCooldownUntil = null;
    _set(AuthStage.loggedOut);
    try {
      _credentials.beginSessionCleanup();
      await client?.logout();
    } finally {
      client?.close();
    }
    await _secretWritePending;
    try {
      await _rememberedPending;
    } on Object {
      // 等待写入结束；可选的密码记忆失败不能阻止停止内核。
    }
    await _clearLocalSession();
    await _clearSessionSecret();
    _credentials.finishSessionCleanup();
  }

  Future<void> refreshPanelClientAddress() async {
    final PanelApiClient? client = _api;
    if (client == null) {
      return;
    }

    try {
      await client.fetchConfigRevision();
    } on Object catch (e) {
      if (identical(client, _api)) {
        Logger.instance.debug(_source, '刷新面板记录的客户端出口地址失败: $e');
      }
    }
  }

  Future<void> refreshProfile() async {
    final PanelApiClient? client = _api;
    if (client == null) {
      return;
    }

    try {
      _applyProfile(await _fetchProfile(client), client);
    } on ApiException catch (e) {
      if (!identical(client, _api)) {
        return;
      }
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

  Future<void> syncAccountStatus() async {
    final PanelApiClient? client = _api;
    if (client == null) {
      return;
    }
    final AccountStatus status = await client.fetchAccountStatus();
    if (!identical(client, _api)) {
      return;
    }
    if (!status.isNormal) {
      enterRestricted(status);
      return;
    }
    await refreshProfile();
  }

  Future<String> checkin() async {
    final PanelApiClient? client = _api;
    if (client == null) {
      throw ApiException(L10n.t('未登录'));
    }
    final ({String message, UserProfile profile}) result = await client
        .checkin();
    if (!identical(client, _api)) {
      throw ApiException(L10n.t('登录状态已变化，请重新操作'));
    }
    _applyProfile(result.profile, client);
    return result.message;
  }

  void _applyProfile(UserProfile profile, PanelApiClient client) {
    if (!identical(client, _api)) {
      return;
    }
    _profile = profile;
    _applyApiOrigin(profile.apiOrigin);
    _applySiteOrigin(profile.siteOrigin);
    final String? key = accountKey;
    if (key != null) {
      _cache.saveProfile(key, profile);
    }
    _emitConfigRevision(profile);
    if (profile.deviceKickNotice) {
      onDeviceKickNotice?.call();
    }
    if (_ticketInbox.read()['user_id'] != profile.id) {
      markTicketsSeen();
    } else {
      notifyListeners();
    }
  }

  Future<void> _loadProfileBestEffort(PanelApiClient client) async {
    try {
      final UserProfile profile = await _fetchProfile(client);
      _applyProfile(profile, client);
    } on ApiException catch (e) {
      if (!identical(client, _api)) {
        return;
      }
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
        L10n.t('请求过于频繁，请稍后再试'),
        statusCode: 429,
        retryAfterSeconds: until
            .difference(DateTime.now())
            .inSeconds
            .clamp(1, _rateLimitWindowSeconds),
      );
    }
    try {
      final AppLanguage language = L10n.current;
      final UserProfile profile = await client.fetchProfile();
      if (identical(client, _api) && language != L10n.current) {
        return await _fetchProfile(client);
      }
      if (identical(client, _api)) {
        _profileCooldownUntil = null;
      }
      return profile;
    } on ApiException catch (e) {
      if (identical(client, _api) && e.rateLimited) {
        final int seconds = e.retryAfterSeconds ?? _rateLimitFallback.inSeconds;
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

  Future<DeviceInfo> _device() async {
    final ({String model, String os}) profile = await _platform.deviceProfile();
    return DeviceInfo(
      platform: _platform.platformId,
      deviceId: _credentials.deviceId(),
      deviceName: await _platform.deviceName(),
      deviceModel: profile.model,
      osVersion: profile.os,
      appVersion: AppConfig.appVersion,
    );
  }

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
    return (_createClient?.call(site, api, device) ??
          PanelApiClient(baseUrl: site, configBaseUrl: api, device: device))
      ..token = token;
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

  // 只认 https：这两个 origin 会被落盘并接管此后所有面板请求（含带 token 的），
  // 面板一旦被改成 http 就等于把会话交给链路上的任何人。Uri.origin 也只支持
  // http / https，别的 scheme 会抛 StateError
  static String? _asOrigin(String? raw) {
    if (raw == null) {
      return null;
    }
    final String trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final Uri? uri = Uri.tryParse(trimmed);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
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
    _sessionGeneration++;
    _api?.close();
    _api = null;
    super.dispose();
  }
}
