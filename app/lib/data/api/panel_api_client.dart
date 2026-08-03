import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../core/logger.dart';
import '../models/announcement.dart';
import '../models/shop.dart';
import '../models/ticket.dart';
import '../models/user_profile.dart';
import 'api_exception.dart';

class LoginResult {
  const LoginResult(this.token, this.expiresAt, this.profile);

  final String token;
  final DateTime expiresAt;
  final UserProfile profile;
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

  /// 策略组 tag => 图标地址，面板 sing-box 模板的 x-sspanel.group_icons
  final Map<String, String> groupIcons;

  /// outbound tag（如 node-12）=> 节点显示名；内核只用 tag，界面用此表展示
  final Map<String, String> nodeLabels;

  /// 地区识别用的取词正则，面板设置项 flag_regex 的原文（PHP 形态）
  final String flagRegex;
}

class DeviceInfo {
  const DeviceInfo({
    required this.platform,
    required this.deviceId,
    required this.deviceName,
    required this.appVersion,
  });

  final String platform;
  final String deviceId;
  final String deviceName;
  final String appVersion;

  Map<String, String> toJson() => <String, String>{
    'platform': platform,
    'device_id': deviceId,
    'device_name': deviceName,
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
    required this.device,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  static const String _source = 'api';
  static const Duration _timeout = Duration(seconds: 20);

  final String baseUrl;
  final DeviceInfo device;
  final http.Client _http;

  String? _token;

  set token(String? value) => _token = value;

  Uri _endpoint(String path, [Map<String, String>? query]) {
    final Uri uri = Uri.parse(
      '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/api/client/v1$path',
    );
    return query == null ? uri : uri.replace(queryParameters: query);
  }

  Map<String, String> _headers({bool json = false}) => <String, String>{
    'Accept': 'application/json',
    'User-Agent':
        'ECYCloud/${device.appVersion} (${_uaPlatform(device.platform)})',
    if (json) 'Content-Type': 'application/json; charset=utf-8',
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  // UA 展示用；platformId / 登录体仍保持小写标识，避免影响服务端既有匹配
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

  LoginResult _loginResult(Map<String, dynamic> data) {
    final String token = data['token'] as String;
    _token = token;

    return LoginResult(
      token,
      DateTime.parse(data['expires_at'] as String),
      UserProfile.fromJson(data['user'] as Map<String, dynamic>),
    );
  }

  Future<void> logout() async {
    try {
      await _post('/auth/logout', const <String, dynamic>{});
    } on ApiException catch (e) {
      // 令牌本就失效时不打断登出，本地凭据照常清除
      Logger.instance.debug(_source, '登出请求未成功: $e');
    } finally {
      _token = null;
    }
  }

  Future<UserProfile> fetchProfile() async =>
      UserProfile.fromJson(await _get('/user/profile'));

  /// 与网页 POST /user/purchases/toggle 同一业务；[action] 为 enable / disable
  Future<String> togglePurchaseAutoRenew({
    required int id,
    required String action,
  }) async {
    final http.Response response = await _send(
      () => _http.post(
        _endpoint('/purchases/toggle'),
        headers: _headers(json: true),
        body: jsonEncode(<String, dynamic>{'id': id, 'action': action}),
      ),
    );
    return _envelope(response)['msg'] as String? ?? '';
  }

  /// 轻量配置戳：未变则客户端不应再打 /config/sing-box。
  Future<String> fetchConfigRevision() async {
    final Map<String, dynamic> data = await _get('/config/revision');
    return data['revision'] as String? ?? '';
  }

  /// 拉取节点与分流规则。优先直连（绕过系统代理）；直连失败且提供了
  /// [fallbackProxyPort] 时，再经本地 mixed 代理重试。
  Future<RemoteProfile> fetchSingBoxProfile({int? fallbackProxyPort}) async {
    try {
      return await _fetchSingBoxProfileVia(_directHttpClient());
    } on Object catch (directError) {
      if (fallbackProxyPort == null || !_isUnreachable(directError)) {
        rethrow;
      }
      Logger.instance.info(
        _source,
        '直连拉取面板配置失败，改经本地代理 $fallbackProxyPort：$directError',
      );
      return await _fetchSingBoxProfileVia(_proxyHttpClient(fallbackProxyPort));
    }
  }

  Future<RemoteProfile> _fetchSingBoxProfileVia(http.Client client) async {
    try {
      final http.Response response = await _send(
        () => client.get(_endpoint('/config/sing-box'), headers: _headers()),
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
    } finally {
      client.close();
    }
  }

  /// 已拿到 HTTP 响应（含业务错误）不算「连不上」，不再改走代理。
  static bool _isUnreachable(Object error) {
    if (error is ApiException) {
      return error.statusCode == null;
    }
    return true;
  }

  static http.Client _directHttpClient() => IOClient(
    HttpClient()..findProxy = (Uri _) => 'DIRECT',
  );

  static http.Client _proxyHttpClient(int port) => IOClient(
    HttpClient()..findProxy = (Uri _) => 'PROXY 127.0.0.1:$port',
  );

  Future<AnnouncementBundle> fetchAnnouncements() async =>
      AnnouncementBundle.fromJson(await _get('/announcements'));

  Future<List<TicketSummary>> fetchTickets() async {
    final Map<String, dynamic> data = await _get('/tickets');
    final Object? raw = data['tickets'];
    return <TicketSummary>[
      if (raw is List)
        for (final Object? item in raw)
          if (item is Map<String, dynamic>) TicketSummary.fromJson(item),
    ];
  }

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
    final Uri uri = _endpoint('/tickets/upload');
    final http.MultipartRequest request = http.MultipartRequest('POST', uri);
    request.headers.addAll(_headers());
    request.files.add(await http.MultipartFile.fromPath('file', filePath));
    try {
      final http.StreamedResponse streamed =
          await _http.send(request).timeout(const Duration(seconds: 120));
      final http.Response response = await http.Response.fromStream(streamed);
      final Map<String, dynamic> data = _unwrap(response);
      return TicketUploadResult.fromJson(data);
    } on ApiException {
      rethrow;
    } on Exception catch (e) {
      throw ApiException('上传失败：$e');
    }
  }

  Future<ShopCatalog> fetchShopProducts() async =>
      ShopCatalog.fromJson(await _get('/shop/products'));

  Future<PlanQuote> fetchPlanQuote({required int shop, String coupon = ''}) async =>
      PlanQuote.fromJson(
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

  /// [epayType] 为空走余额支付，否则走在线支付并返回跳转链接
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
    final http.Response response = await _send(
      () => _http.post(
        _endpoint(path),
        headers: _headers(json: true),
        body: jsonEncode(body),
      ),
    );
    return ShopPurchaseResult.fromEnvelope(_envelope(response));
  }

  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, String>? query,
  ]) async {
    final http.Response response = await _send(
      () => _http.get(_endpoint(path, query), headers: _headers()),
    );
    return _unwrap(response);
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
    final http.Response response = await _send(
      () => _http.post(
        _endpoint(path),
        headers: _headers(json: true),
        body: jsonEncode(body),
      ),
    );
    return _unwrap(response);
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(_timeout);
    } on Exception catch (e) {
      throw ApiException('无法连接面板，请检查网络或面板地址：$e');
    }
  }

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

  void close() => _http.close();
}
