import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/logger.dart';
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
    required this.updateInterval,
    required this.groupIcons,
    required this.flagRegex,
  });

  final Map<String, dynamic> config;
  final Duration updateInterval;

  /// 策略组 tag => 图标地址，面板 sing-box 模板的 x-sspanel.group_icons
  final Map<String, String> groupIcons;

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

  Uri _endpoint(String path) =>
      Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/api/client/v1$path');

  Map<String, String> _headers({bool json = false}) => <String, String>{
    'Accept': 'application/json',
    'User-Agent': 'ECYCloud/${device.appVersion} (${device.platform})',
    if (json) 'Content-Type': 'application/json; charset=utf-8',
    if (_token != null) 'Authorization': 'Bearer $_token',
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

  Future<RemoteProfile> fetchSingBoxProfile() async {
    final Map<String, dynamic> data = await _get('/config/sing-box');
    final Object? icons = data['group_icons'];

    return RemoteProfile(
      config: data['config'] as Map<String, dynamic>,
      updateInterval: Duration(
        seconds: (data['update_interval'] as num?)?.toInt() ?? 86400,
      ),
      groupIcons: <String, String>{
        if (icons is Map<String, dynamic>)
          for (final MapEntry<String, dynamic> entry in icons.entries)
            if (entry.value is String) entry.key: entry.value as String,
      },
      flagRegex: data['flag_regex'] as String? ?? '',
    );
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final http.Response response = await _send(
      () => _http.get(_endpoint(path), headers: _headers()),
    );
    return _unwrap(response);
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
      );
    }

    final Object? data = payload['data'];
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }

  void close() => _http.close();
}
