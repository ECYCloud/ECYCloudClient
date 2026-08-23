import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../core/logger.dart';
import '../models/account.dart';
import '../models/announcement.dart';
import '../models/online_device.dart';
import '../models/shop.dart';
import '../models/ticket.dart';
import '../models/user_profile.dart';
import 'api_exception.dart';

class LoginResult {
  const LoginResult(
    this.token,
    this.expiresAt, {
    this.profile,
    this.accountStatus,
  });

  final String token;
  final DateTime expiresAt;
  final UserProfile? profile;
  final AccountStatus? accountStatus;

  bool get isRestricted {
    final AccountStatus? status = accountStatus;
    return status != null && !status.isNormal;
  }
}

class RemoteProfile {
  const RemoteProfile({
    required this.config,
    required this.revision,
    required this.groupIcons,
    required this.nodeLabels,
    required this.flagRegex,
  });

  final Map<String, dynamic> config;
  final String revision;

  /// 面板 Clash 模板 x-sspanel.group_icons
  final Map<String, String> groupIcons;

  /// 内核只用 proxy 名；界面显示靠这张表
  final Map<String, String> nodeLabels;

  /// 面板 flag_regex 原文（PHP 形态）
  final String flagRegex;
}

class DeviceInfo {
  const DeviceInfo({
    required this.platform,
    required this.deviceId,
    required this.deviceName,
    required this.deviceModel,
    required this.osVersion,
    required this.appVersion,
  });

  final String platform;
  final String deviceId;
  final String deviceName;
  final String deviceModel;
  final String osVersion;
  final String appVersion;

  // platform 不上报（已含在 device_model-os_version）；字段留给 User-Agent
  Map<String, String> toJson() => <String, String>{
    'device_id': deviceId,
    'device_name': deviceName,
    'device_model': deviceModel,
    'os_version': osVersion,
    'app_version': appVersion,
  };
}

class TicketUploadResult {
  const TicketUploadResult({
    required this.url,
    required this.originalName,
    required this.kind,
  });

  final String url;
  final String originalName;
  final String kind;

  factory TicketUploadResult.fromJson(Map<String, dynamic> json) =>
      TicketUploadResult(
        url: json['url'] as String? ?? '',
        originalName: json['originalName'] as String? ?? '',
        kind: json['kind'] as String? ?? 'file',
      );
}

class PanelApiClient {
  PanelApiClient({
    required this.baseUrl,
    required this.configBaseUrl,
    required this.device,
  });

  static const String _source = 'api';
  static const Duration _timeout = Duration(seconds: 20);

  /// TUN 会把解析劫持成 fake-ip，面板域名 A 记录缓存复用，勿每请求重解
  static const Duration _directTtl = Duration(minutes: 5);

  final String baseUrl;
  final String configBaseUrl;
  final DeviceInfo device;

  int? fallbackProxyPort;

  final Map<String, List<InternetAddress>> _directByHost =
      <String, List<InternetAddress>>{};
  DateTime? _directResolvedAt;

  late final http.Client _direct = _directHttpClient(_directByHost);
  http.Client? _proxy;
  int? _proxyPort;

  String? token;

  List<String> get configDirectCidrs {
    final Set<String> seen = <String>{};
    final List<String> cidrs = <String>[];
    for (final List<InternetAddress> addresses in _directByHost.values) {
      for (final InternetAddress address in addresses) {
        final String cidr = address.type == InternetAddressType.IPv6
            ? '${address.address}/128'
            : '${address.address}/32';
        if (seen.add(cidr)) {
          cidrs.add(cidr);
        }
      }
    }
    return cidrs;
  }

  // TUN dns-hijack 会给出 198.18/16 fake-ip，写进排除列表或建连都会打空，必须丢掉。
  // 解析失败时保留上次真实地址，避免连上后被 fake-ip 清空排除列表。
  Future<void> refreshConfigDirectAddresses() async {
    await _refreshHost(configBaseUrl);
    await _refreshHost(baseUrl);
    _directResolvedAt = DateTime.now();
  }

  Future<void> _ensureDirectAddresses() async {
    final DateTime? at = _directResolvedAt;
    if (at != null &&
        _directByHost.isNotEmpty &&
        DateTime.now().difference(at) < _directTtl) {
      return;
    }
    await refreshConfigDirectAddresses();
  }

  Future<void> _refreshHost(String origin) async {
    final String host = _originHost(origin);
    if (host.isEmpty) {
      return;
    }
    final List<InternetAddress> next = await _lookupRoutable(host);
    if (next.isNotEmpty) {
      _directByHost[host] = next;
    }
  }

  Uri _endpoint(String path, [Map<String, String>? query]) =>
      _apiUri(baseUrl, path, query);

  Uri _configEndpoint(String path, [Map<String, String>? query]) =>
      _apiUri(configBaseUrl, path, query);

  static Uri _apiUri(String root, String path, [Map<String, String>? query]) {
    final Uri uri = Uri.parse('${_originOf(root)}/api/client/v1$path');
    return query == null ? uri : uri.replace(queryParameters: query);
  }

  // API 只认主机，不要带路径
  static String _originOf(String root) {
    final Uri? parsed = Uri.tryParse(root.trim());
    if (parsed != null &&
        (parsed.scheme == 'https' || parsed.scheme == 'http') &&
        parsed.host.isNotEmpty) {
      return parsed.origin;
    }
    return root.replaceAll(RegExp(r'/+$'), '');
  }

  static String _originHost(String root) =>
      Uri.tryParse(_originOf(root))?.host ?? '';

  Map<String, String> _headers({bool json = false}) => <String, String>{
    'Accept': 'application/json',
    'User-Agent':
        'ECYCloud/${_uaVersion(device.appVersion)} (${_uaPlatform(device.platform)})',
    // 型号/系统/版本只在登录入库，须随请求刷新，否则升级后面板一直是旧值
    if (device.deviceModel.isNotEmpty)
      'X-Device-Model': _headerText(device.deviceModel),
    if (device.osVersion.isNotEmpty)
      'X-Device-OS': _headerText(device.osVersion),
    if (device.appVersion.isNotEmpty)
      'X-App-Version': _headerText(device.appVersion),
    if (json) 'Content-Type': 'application/json; charset=utf-8',
    if (token != null) 'Authorization': 'Bearer $token',
  };

  // HTTP 头只保证 ASCII；非 ASCII 须 encode，面板 rawurldecode 还原
  static String _headerText(String value) => Uri.encodeComponent(value);

  // product/version 不能有空格，界面 `Pre 1.0.2` 在 UA 收成 `Pre1.0.2`
  static String _uaVersion(String version) =>
      version.startsWith('Pre ') ? 'Pre${version.substring(4)}' : version;

  // UA 展示用大写；platformId / 登录体仍用小写，避免打乱服务端匹配
  static String _uaPlatform(String platform) => switch (platform) {
    'android' => 'Android',
    'windows' => 'Windows',
    'linux' => 'Linux',
    'macos' => 'macOS',
    _ => platform,
  };

  Future<LoginResult> login({
    required String email,
    required String password,
    String? twoFactorCode,
  }) async {
    final Map<String, dynamic> data =
        await _post('/auth/login', <String, dynamic>{
          'email': email,
          'passwd': password,
          if (twoFactorCode != null && twoFactorCode.isNotEmpty)
            'code': twoFactorCode,
          ...device.toJson(),
        });

    return _loginResult(data);
  }

  Future<void> sendLoginVerify({required String email}) async {
    await _post('/auth/send-login-verify', <String, dynamic>{'email': email});
  }

  Future<LoginResult> loginWithVerifyCode({
    required String email,
    required String code,
  }) async {
    final Map<String, dynamic> data = await _post(
      '/auth/login-with-verify-code',
      <String, dynamic>{'email': email, 'code': code, ...device.toJson()},
    );
    return _loginResult(data);
  }

  Future<AuthOptions> fetchAuthOptions() async =>
      AuthOptions.fromJson(await _get('/auth/options'));

  Future<String> fetchTos() async {
    final Map<String, dynamic> data = await _get('/auth/tos');
    return data['content'] as String? ?? '';
  }

  Future<String> sendRegisterVerify({required String email}) =>
      _postMsg('/auth/send-register-verify', <String, dynamic>{'email': email});

  Future<LoginResult> register({
    required String name,
    required String email,
    required String passwd,
    required String repasswd,
    String code = '',
    String emailcode = '',
  }) async {
    final Map<String, dynamic> data =
        await _post('/auth/register', <String, dynamic>{
          'name': name,
          'email': email,
          'passwd': passwd,
          'repasswd': repasswd,
          if (code.isNotEmpty) 'code': code,
          if (emailcode.isNotEmpty) 'emailcode': emailcode,
          ...device.toJson(),
        });
    return _loginResult(data);
  }

  Future<String> requestPasswordReset({required String email}) =>
      _postMsg('/auth/password-reset', <String, dynamic>{'email': email});

  Future<LoginResult> confirmPasswordReset({
    required String token,
    required String password,
    required String repasswd,
  }) async {
    final Map<String, dynamic> data = await _post(
      '/auth/password-reset/confirm',
      <String, dynamic>{
        'token': token,
        'password': password,
        'repasswd': repasswd,
        ...device.toJson(),
      },
    );
    return _loginResult(data);
  }

  LoginResult _loginResult(Map<String, dynamic> data) {
    final String token = data['token'] as String;
    this.token = token;

    final Object? userRaw = data['user'];
    final Object? statusRaw = data['account_status'];

    return LoginResult(
      token,
      DateTime.parse(data['expires_at'] as String),
      profile: userRaw is Map<String, dynamic>
          ? UserProfile.fromJson(userRaw)
          : null,
      accountStatus: statusRaw is Map<String, dynamic>
          ? AccountStatus.fromJson(statusRaw)
          : null,
    );
  }

  Future<AccountStatus> fetchAccountStatus() async =>
      AccountStatus.fromJson(await _get('/user/account-status'));

  Future<String> sendKillEmailCode() =>
      _postMsg('/user/send-kill-email-code', const <String, dynamic>{});

  Future<AccountStatus> killAccount({String? emailCode, String? passwd}) async {
    final Map<String, dynamic> envelope =
        await _postEnvelope('/user/kill', <String, dynamic>{
          'email_code': ?emailCode,
          'passwd': ?passwd,
        });
    final Object? data = envelope['data'];
    if (data is Map<String, dynamic>) {
      return AccountStatus.fromJson(data);
    }
    return fetchAccountStatus();
  }

  Future<({String message, AccountStatus status, UserProfile profile})>
  cancelAccountDeletion() async {
    final Map<String, dynamic> envelope = await _postEnvelope(
      '/user/cancel-account-deletion',
      const <String, dynamic>{},
    );
    final Object? data = envelope['data'];
    final Map<String, dynamic> map = data is Map<String, dynamic>
        ? data
        : <String, dynamic>{};
    final Object? statusRaw = map['status'];
    final Object? userRaw = map['user'];
    return (
      message: envelope['msg'] as String? ?? '账号状态已恢复正常。',
      status: statusRaw is Map<String, dynamic>
          ? AccountStatus.fromJson(statusRaw)
          : await fetchAccountStatus(),
      profile: userRaw is Map<String, dynamic>
          ? UserProfile.fromJson(userRaw)
          : await fetchProfile(),
    );
  }

  Future<void> logout() async {
    try {
      await _post('/auth/logout', const <String, dynamic>{});
    } on ApiException catch (e) {
      Logger.instance.debug(_source, '登出请求未成功: $e');
    } finally {
      token = null;
    }
  }

  Future<UserProfile> fetchProfile() async =>
      UserProfile.fromJson(await _get('/user/profile'));

  Future<String> ackIpKick() =>
      _postMsg('/user/ip-kick-ack', const <String, dynamic>{});

  Future<List<OnlineDevice>> fetchOnlineDevices() async {
    return _viaDirectThenProxy(
      run: (http.Client client) async {
        final http.Response response = await _send(
          () => client.get(_endpoint('/user/online-ips'), headers: _headers()),
        );
        final Object? data = _envelope(response)['data'];
        return <OnlineDevice>[
          if (data is List)
            for (final Object? item in data)
              if (item is Map<String, dynamic>) OnlineDevice.fromJson(item),
        ];
      },
    );
  }

  Future<String> reclaimIp({String targetIp = ''}) async {
    return _viaDirectThenProxy(
      repeatable: false,
      run: (http.Client client) async {
        final http.Response response = await _send(
          () => client.post(
            _endpoint('/user/ip-reclaim'),
            headers: _headers(json: true),
            body: jsonEncode(<String, dynamic>{'target_ip': targetIp}),
          ),
        );
        return _envelope(response)['msg'] as String? ?? '';
      },
    );
  }

  Future<({String message, UserProfile profile})> checkin() async {
    final Map<String, dynamic> envelope = await _postEnvelope(
      '/user/checkin',
      const <String, dynamic>{},
    );
    final Object? data = envelope['data'];
    final UserProfile profile = data is Map<String, dynamic>
        ? UserProfile.fromJson(data)
        : await fetchProfile();
    return (message: envelope['msg'] as String? ?? '签到成功', profile: profile);
  }

  Future<String> updateUsername(String newusername) =>
      _postMsg('/user/username', <String, dynamic>{'newusername': newusername});

  Future<String> updatePassword({
    required String oldpwd,
    required String pwd,
    required String repwd,
  }) => _postMsg('/user/password', <String, dynamic>{
    'oldpwd': oldpwd,
    'pwd': pwd,
    'repwd': repwd,
  });

  Future<String> sendOldEmailVerify() =>
      _postMsg('/user/send-old-email-verify', const <String, dynamic>{});

  Future<String> verifyOldEmail({required String oldEmailcode}) => _postMsg(
    '/user/verify-old-email',
    <String, dynamic>{'old_emailcode': oldEmailcode},
  );

  Future<String> sendNewEmailVerify({required String email}) => _postMsg(
    '/user/send-new-email-verify',
    <String, dynamic>{'email': email},
  );

  Future<String> updateEmail({
    required String newemail,
    String oldEmailcode = '',
    String newEmailcode = '',
  }) => _postMsg('/user/email', <String, dynamic>{
    'newemail': newemail,
    if (oldEmailcode.isNotEmpty) 'old_emailcode': oldEmailcode,
    if (newEmailcode.isNotEmpty) 'new_emailcode': newEmailcode,
  });

  Future<InviteSummary> fetchInviteSummary({
    int invitedPage = 1,
    int invitedLength = 10,
    String invitedSearch = '',
    int paybackPage = 1,
    int paybackLength = 10,
    String paybackSearch = '',
    int withdrawPage = 1,
    int withdrawLength = 10,
    String withdrawSearch = '',
  }) async => InviteSummary.fromJson(
    await _get('/user/invite', <String, String>{
      'invited_page': '$invitedPage',
      'invited_length': '$invitedLength',
      if (invitedSearch.isNotEmpty) 'invited_search': invitedSearch,
      'payback_page': '$paybackPage',
      'payback_length': '$paybackLength',
      if (paybackSearch.isNotEmpty) 'payback_search': paybackSearch,
      'withdraw_page': '$withdrawPage',
      'withdraw_length': '$withdrawLength',
      if (withdrawSearch.isNotEmpty) 'withdraw_search': withdrawSearch,
    }),
  );

  Future<EditAccountOptions> fetchEditOptions() async =>
      EditAccountOptions.fromJson(await _get('/user/edit-options'));

  Future<SubscriptionConfig> fetchSubscriptionConfig() async =>
      SubscriptionConfig.fromJson(await _get('/user/subscription-config'));

  Future<String> saveSubscriptionConfig(Map<String, dynamic> body) =>
      _postMsg('/user/subscription-config', body);

  Future<String> gaCheck(String code) =>
      _postMsg('/user/ga-check', <String, dynamic>{'code': code});

  Future<String> gaSet(int enable) =>
      _postMsg('/user/ga-set', <String, dynamic>{'enable': enable});

  Future<({String message, String gaToken, String gaUrl})> gaReset() async {
    final Map<String, dynamic> envelope = await _postEnvelope(
      '/user/ga-reset',
      const <String, dynamic>{},
    );
    final Object? data = envelope['data'];
    final Map<String, dynamic> body = data is Map<String, dynamic>
        ? data
        : <String, dynamic>{};
    return (
      message: envelope['msg'] as String? ?? '',
      gaToken: body['ga_token'] as String? ?? '',
      gaUrl: body['ga_url'] as String? ?? '',
    );
  }

  Future<({String message, String bindToken})> telegramReset() async {
    final Map<String, dynamic> envelope = await _postEnvelope(
      '/user/telegram-reset',
      const <String, dynamic>{},
    );
    final Object? data = envelope['data'];
    final Map<String, dynamic> body = data is Map<String, dynamic>
        ? data
        : <String, dynamic>{};
    return (
      message: envelope['msg'] as String? ?? '',
      bindToken:
          body['bind_token'] as String? ??
          envelope['bind_token'] as String? ??
          '',
    );
  }

  Future<({bool bound, String imValue, int telegramId})>
  telegramBindCheck() async {
    final Map<String, dynamic> envelope = await _viaDirectThenProxy(
      run: (http.Client client) async {
        final http.Response response = await _send(
          () => client.get(
            _endpoint('/user/telegram-bind-check'),
            headers: _headers(),
          ),
        );
        return _envelopeAllowRetZero(response);
      },
    );
    final int ret = (envelope['ret'] as num?)?.toInt() ?? 0;
    final Object? data = envelope['data'];
    final Map<String, dynamic> body = data is Map<String, dynamic>
        ? data
        : <String, dynamic>{};
    return (
      bound: ret == 1,
      imValue:
          body['im_value'] as String? ?? envelope['im_value'] as String? ?? '',
      telegramId: (body['telegram_id'] as num?)?.toInt() ?? 0,
    );
  }

  Future<String> updateMailNotify(Map<String, bool> preferences) => _postMsg(
    '/user/mail-notify',
    <String, dynamic>{'preferences': jsonEncode(preferences)},
  );

  Future<InviteResetResult> resetInviteCode() async {
    final Map<String, dynamic> envelope = await _put('/user/invite');
    final Object? data = envelope['data'];
    final Map<String, dynamic> body = data is Map<String, dynamic>
        ? data
        : <String, dynamic>{};
    return InviteResetResult(
      message: envelope['msg'] as String? ?? '',
      newCode: body['new_code'] as String? ?? '',
      inviteUrl: body['invite_url'] as String? ?? '',
    );
  }

  Future<String> applyWithdraw({
    required double amount,
    String channelId = 'balance',
    Map<String, String> accountInfo = const <String, String>{},
    bool saveAccount = false,
  }) => _postMsg('/user/withdraw/apply', <String, dynamic>{
    'amount': amount,
    'channel_id': channelId,
    if (accountInfo.isNotEmpty) 'account_info': accountInfo,
    if (saveAccount) 'save_account': true,
  });

  Future<String> cancelWithdraw({required int recordId}) => _postMsg(
    '/user/withdraw/cancel',
    <String, dynamic>{'record_id': recordId},
  );

  Future<WithdrawChannelFieldsResult> fetchWithdrawChannelFields(
    int channelId,
  ) async {
    return WithdrawChannelFieldsResult.fromJson(
      await _getEnvelope('/user/withdraw/channel/$channelId/fields'),
    );
  }

  Future<TrafficLogBundle> fetchTrafficLog() async =>
      TrafficLogBundle.fromJson(await _get('/user/traffic-log'));

  Future<UsageIpListPage> fetchUsageIps({
    int page = 1,
    int length = 10,
    String search = '',
  }) async => UsageIpListPage.fromJson(
    await _get('/user/usage-ips', <String, String>{
      'page': '$page',
      'length': '$length',
      if (search.isNotEmpty) 'search': search,
    }),
  );

  /// 与网页 POST /user/profile/kick-device 同一业务
  Future<String> kickDevice(String ip) =>
      _postMsg('/user/kick-device', <String, dynamic>{'ip': ip});

  Future<LoginLogListPage> fetchLoginLogs({
    int page = 1,
    int length = 10,
    String search = '',
  }) async => LoginLogListPage.fromJson(
    await _get('/user/login-logs', <String, String>{
      'page': '$page',
      'length': '$length',
      if (search.isNotEmpty) 'search': search,
    }),
  );

  Future<OperationLogListPage> fetchOperationLogs({
    int page = 1,
    int length = 10,
    String search = '',
  }) async => OperationLogListPage.fromJson(
    await _get('/user/operation-logs', <String, String>{
      'page': '$page',
      'length': '$length',
      if (search.isNotEmpty) 'search': search,
    }),
  );

  Future<PurchaseListPage> fetchPurchases({
    int page = 1,
    int length = 10,
    String search = '',
  }) async => PurchaseListPage.fromJson(
    await _get('/user/purchases', <String, String>{
      'page': '$page',
      'length': '$length',
      if (search.isNotEmpty) 'search': search,
    }),
  );

  Future<RechargeInfo> fetchRechargeInfo() async =>
      RechargeInfo.fromJson(await _get('/user/recharge'));

  Future<String> redeemRechargeCode(String code) =>
      _postMsg('/user/recharge/code', <String, dynamic>{'code': code});

  Future<ShopPurchaseResult> rechargeWithEpay({
    required double price,
    required String type,
  }) async {
    return _purchase('/user/recharge/epay', <String, dynamic>{
      'price': price,
      'type': type,
    });
  }

  Future<BalanceListPage> fetchBalanceTransactions({
    int page = 1,
    int length = 10,
    String search = '',
  }) async => BalanceListPage.fromJson(
    await _get('/user/balance-transactions', <String, String>{
      'page': '$page',
      'length': '$length',
      if (search.isNotEmpty) 'search': search,
    }),
  );

  Future<UnlockListPage> fetchUnlockResults({
    int page = 1,
    int length = 10,
    String search = '',
  }) async => UnlockListPage.fromJson(
    await _get('/user/unlock', <String, String>{
      'page': '$page',
      'length': '$length',
      if (search.isNotEmpty) 'search': search,
    }),
  );

  /// 与网页 POST /user/purchases/toggle 同一业务；[action] 为 enable / disable
  Future<String> togglePurchaseAutoRenew({
    required int id,
    required String action,
  }) => _postMsg('/purchases/toggle', <String, dynamic>{
    'id': id,
    'action': action,
  });

  /// 未变则不要再打 /config/clash（走订阅域名）
  Future<String> fetchConfigRevision({int? fallbackProxyPort}) async {
    return _viaDirectThenProxy(
      fallbackProxyPort: fallbackProxyPort,
      run: (http.Client client) async {
        final http.Response response = await _send(
          () => client.get(
            _configEndpoint('/config/revision'),
            headers: _headers(),
          ),
        );
        final Map<String, dynamic> data = _unwrap(response);
        return data['revision'] as String? ?? '';
      },
    );
  }

  Future<RemoteProfile> fetchClashProfile({int? fallbackProxyPort}) async {
    return _viaDirectThenProxy(
      fallbackProxyPort: fallbackProxyPort,
      run: _fetchClashProfileVia,
    );
  }

  /// repeatable 为 false 时只在连接未建起时换代理重发，超时可能已处理完
  Future<T> _viaDirectThenProxy<T>({
    required Future<T> Function(http.Client client) run,
    int? fallbackProxyPort,
    bool repeatable = true,
  }) async {
    await _ensureDirectAddresses();
    final int? proxyPort = fallbackProxyPort ?? this.fallbackProxyPort;
    try {
      return await run(_direct);
    } on Object catch (directError) {
      if (proxyPort == null || !_canRetryViaProxy(directError, repeatable)) {
        rethrow;
      }
      Logger.instance.info(_source, '直连面板失败，改经本地代理 $proxyPort：$directError');
      return await run(_proxyClient(proxyPort));
    }
  }

  Future<RemoteProfile> _fetchClashProfileVia(http.Client client) async {
    final http.Response response = await _send(
      () => client.get(_configEndpoint('/config/clash'), headers: _headers()),
    );
    final Map<String, dynamic> data = _unwrap(response);
    final Object? icons = data['group_icons'];
    final Object? labels = data['node_labels'];

    return RemoteProfile(
      config: data['config'] as Map<String, dynamic>,
      revision: data['revision'] as String? ?? '',
      groupIcons: <String, String>{
        if (icons is Map<String, dynamic>)
          for (final MapEntry<String, dynamic> entry in icons.entries)
            if (entry.value is String) entry.key: entry.value as String,
      },
      nodeLabels: <String, String>{
        if (labels is Map<String, dynamic>)
          for (final MapEntry<String, dynamic> entry in labels.entries)
            if (entry.value is String) entry.key: entry.value as String,
      },
      flagRegex: data['flag_regex'] as String? ?? '',
    );
  }

  static bool _canRetryViaProxy(Object error, bool repeatable) {
    if (!repeatable) {
      return error is ApiException && error.connectFailed;
    }
    return _isUnreachable(error);
  }

  /// 已拿到 HTTP 响应（含业务错误）不算连不上，不再改走代理
  static bool _isUnreachable(Object error) {
    if (error is ApiException) {
      return error.statusCode == null;
    }
    return true;
  }

  http.Client _proxyClient(int port) {
    final http.Client? cached = _proxy;
    if (cached != null && _proxyPort == port) {
      return cached;
    }
    cached?.close();
    _proxyPort = port;
    return _proxy = _proxyHttpClient(port);
  }

  static http.Client _directHttpClient(
    Map<String, List<InternetAddress>> bindByHost,
  ) {
    final HttpClient raw = HttpClient()..findProxy = (Uri _) => 'DIRECT';
    raw.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
      if (proxyHost != null && proxyPort != null) {
        return Socket.startConnect(proxyHost, proxyPort);
      }
      final List<InternetAddress> bind =
          bindByHost[uri.host] ?? const <InternetAddress>[];
      final Object connectHost = bind.isEmpty
          ? uri.host
          : bind.firstWhere(
              (InternetAddress address) =>
                  address.type == InternetAddressType.IPv4,
              orElse: () => bind.first,
            );
      if (uri.scheme != 'https') {
        return Socket.startConnect(connectHost, uri.port);
      }
      // HttpClient 对 connectionFactory 的明文 socket 不会再升 TLS；
      // 直连 IP 时必须自己握手，SNI / 证书校验仍用域名
      if (connectHost is InternetAddress) {
        final ConnectionTask<Socket> tcp = await Socket.startConnect(
          connectHost,
          uri.port,
        );
        return ConnectionTask.fromSocket(
          tcp.socket.then(
            (Socket plain) => SecureSocket.secure(plain, host: uri.host),
          ),
          tcp.cancel,
        );
      }
      return SecureSocket.startConnect(connectHost, uri.port);
    };
    return IOClient(raw);
  }

  static Future<List<InternetAddress>> _lookupRoutable(String host) async {
    final InternetAddress? literal = InternetAddress.tryParse(host);
    if (literal != null) {
      return <InternetAddress>[literal];
    }
    try {
      final List<InternetAddress> found = await InternetAddress.lookup(host);
      return <InternetAddress>[
        for (final InternetAddress address in found)
          if (!_isClashFakeIp(address)) address,
      ];
    } on SocketException {
      return const <InternetAddress>[];
    }
  }

  static bool _isClashFakeIp(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4) {
      return false;
    }
    final List<int> bytes = address.rawAddress;
    return bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19);
  }

  static http.Client _proxyHttpClient(int port) =>
      IOClient(HttpClient()..findProxy = (Uri _) => 'PROXY 127.0.0.1:$port');

  Future<AnnouncementBundle> fetchAnnouncements() async =>
      AnnouncementBundle.fromJson(await _get('/announcements'));

  Future<TicketListPage> fetchTickets({
    int page = 1,
    int length = 10,
    String search = '',
  }) async => TicketListPage.fromJson(
    await _get('/tickets', <String, String>{
      'page': '$page',
      'length': '$length',
      if (search.isNotEmpty) 'search': search,
    }),
  );

  Future<TicketDetail> fetchTicket(int id) async =>
      TicketDetail.fromJson(await _get('/tickets/$id'));

  Future<int> createTicket({
    required String title,
    required String content,
  }) async {
    final Map<String, dynamic> data = await _post('/tickets', <String, dynamic>{
      'title': title,
      'content': content,
    });
    return (data['ticket_id'] as num).toInt();
  }

  Future<void> replyTicket({required int id, required String content}) async {
    await _post('/tickets/$id/reply', <String, dynamic>{'content': content});
  }

  Future<void> closeTicket(int id) async {
    await _post('/tickets/$id/close', const <String, dynamic>{});
  }

  Future<TicketUploadResult> uploadTicketAttachment(String filePath) async {
    return _viaDirectThenProxy(
      repeatable: false,
      run: (http.Client client) async {
        final Uri uri = _endpoint('/tickets/upload');
        final http.MultipartRequest request = http.MultipartRequest(
          'POST',
          uri,
        );
        request.headers.addAll(_headers());
        request.files.add(await http.MultipartFile.fromPath('file', filePath));
        try {
          final http.StreamedResponse streamed = await client
              .send(request)
              .timeout(const Duration(seconds: 120));
          final http.Response response = await http.Response.fromStream(
            streamed,
          );
          return TicketUploadResult.fromJson(_unwrap(response));
        } on ApiException {
          rethrow;
        } on Exception catch (e) {
          throw ApiException('上传失败：$e');
        }
      },
    );
  }

  Future<ShopCatalog> fetchShopProducts() async =>
      ShopCatalog.fromJson(await _get('/shop/products'));

  Future<PlanQuote> fetchPlanQuote({
    required int shop,
    String coupon = '',
  }) async => PlanQuote.fromJson(
    await _get('/shop/order-status', <String, String>{
      'shop': '$shop',
      if (coupon.isNotEmpty) 'coupon': coupon,
    }),
  );

  Future<ProductQuote> fetchTrafficPackageQuote(int shop) async =>
      ProductQuote.fromJson(
        await _get('/shop/traffic-package-status', <String, String>{
          'shop': '$shop',
        }),
      );

  Future<ProductQuote> fetchCardKeyQuote(int shop) async =>
      ProductQuote.fromJson(
        await _get('/shop/card-key-status', <String, String>{'shop': '$shop'}),
      );

  Future<ShopPurchaseResult> buyPlan({
    required int shop,
    required String coupon,
    required bool autoRenew,
    required bool disableOthers,
    String epayType = '',
  }) => _purchase(
    epayType.isEmpty ? '/shop/buy' : '/shop/buy-with-epay',
    <String, dynamic>{
      'shop': shop,
      'coupon': coupon,
      'autorenew': autoRenew ? 1 : 0,
      'disableothers': disableOthers ? 1 : 0,
      if (epayType.isNotEmpty) 'epay_type': epayType,
    },
  );

  Future<ShopPurchaseResult> buyTrafficPackage({
    required int shop,
    String epayType = '',
  }) => _purchase(
    epayType.isEmpty
        ? '/shop/buy-traffic-package'
        : '/shop/buy-traffic-package-with-epay',
    <String, dynamic>{
      'shop': shop,
      if (epayType.isNotEmpty) 'epay_type': epayType,
    },
  );

  Future<ShopPurchaseResult> buyCardKey({
    required int shop,
    String epayType = '',
  }) => _purchase(
    epayType.isEmpty ? '/shop/buy-card-key' : '/shop/buy-card-key-with-epay',
    <String, dynamic>{
      'shop': shop,
      if (epayType.isNotEmpty) 'epay_type': epayType,
    },
  );

  Future<PaymentStatus> fetchPaymentStatus(String tradeNo) async =>
      PaymentStatus.fromJson(
        await _get('/shop/payment-status', <String, String>{
          'tradeno': tradeNo,
        }),
      );

  Future<ShopPurchaseResult> _purchase(
    String path,
    Map<String, dynamic> body,
  ) async {
    return ShopPurchaseResult.fromEnvelope(await _postEnvelope(path, body));
  }

  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, String>? query,
  ]) async {
    return _unwrap(
      await _sendVia(
        (http.Client client) =>
            client.get(_endpoint(path, query), headers: _headers()),
      ),
    );
  }

  Future<Map<String, dynamic>> _getEnvelope(String path) async {
    return _envelope(
      await _sendVia(
        (http.Client client) =>
            client.get(_endpoint(path), headers: _headers()),
      ),
    );
  }

  static int? _retryAfterSeconds(http.Response response) {
    final String? raw = response.headers['retry-after'];
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final int? seconds = int.tryParse(raw.trim());
    if (seconds == null || seconds <= 0) {
      return null;
    }
    return seconds;
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    return _unwrap(
      await _sendVia(
        (http.Client client) => client.post(
          _endpoint(path),
          headers: _headers(json: true),
          body: jsonEncode(body),
        ),
        repeatable: false,
      ),
    );
  }

  Future<Map<String, dynamic>> _put(
    String path, [
    Map<String, dynamic> body = const <String, dynamic>{},
  ]) async {
    return _envelope(
      await _sendVia(
        (http.Client client) => client.put(
          _endpoint(path),
          headers: _headers(json: true),
          body: jsonEncode(body),
        ),
        repeatable: false,
      ),
    );
  }

  Future<String> _postMsg(String path, Map<String, dynamic> body) async {
    final Map<String, dynamic> envelope = await _postEnvelope(path, body);
    return envelope['msg'] as String? ?? '';
  }

  Future<Map<String, dynamic>> _postEnvelope(
    String path,
    Map<String, dynamic> body,
  ) async {
    return _envelope(
      await _sendVia(
        (http.Client client) => client.post(
          _endpoint(path),
          headers: _headers(json: true),
          body: jsonEncode(body),
        ),
        repeatable: false,
      ),
    );
  }

  Future<http.Response> _sendVia(
    Future<http.Response> Function(http.Client client) request, {
    bool repeatable = true,
  }) {
    return _viaDirectThenProxy(
      repeatable: repeatable,
      run: (http.Client client) => _send(() => request(client)),
    );
  }

  /// 绑定轮询等接口用 ret=0 表示未绑定，不当作错误。
  Map<String, dynamic> _envelopeAllowRetZero(http.Response response) {
    Map<String, dynamic>? payload;
    try {
      payload =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } on FormatException {
      payload = null;
    }
    if (payload == null) {
      throw ApiException(
        '面板返回了非预期的内容（HTTP ${response.statusCode}）',
        statusCode: response.statusCode,
      );
    }
    return payload;
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(_timeout);
    } on Exception catch (e) {
      throw ApiException(
        '无法连接面板，请检查网络或面板地址：$e',
        connectFailed: _isConnectFailure(e),
      );
    }
  }

  /// 超时不算连接失败：服务端可能已处理完
  static bool _isConnectFailure(Object error) =>
      error is SocketException || error is HandshakeException;

  Map<String, dynamic> _unwrap(http.Response response) {
    final Object? data = _envelope(response)['data'];
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }

  /// 商店成功文案在 msg 里，需要整个信封
  Map<String, dynamic> _envelope(http.Response response) {
    Map<String, dynamic>? payload;
    try {
      payload =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } on FormatException {
      payload = null;
    }

    if (payload == null) {
      throw ApiException(
        '面板返回了非预期的内容（HTTP ${response.statusCode}）',
        statusCode: response.statusCode,
      );
    }

    final int ret = (payload['ret'] as num?)?.toInt() ?? 0;
    if (ret != 1) {
      throw ApiException(
        payload['msg'] as String? ?? '请求失败（HTTP ${response.statusCode}）',
        statusCode: response.statusCode,
        ret: ret,
        retryAfterSeconds: _retryAfterSeconds(response),
      );
    }

    return payload;
  }

  void close() {
    _direct.close();
    _proxy?.close();
    _proxy = null;
    _proxyPort = null;
  }
}
