import 'dart:convert';

import 'package:http/http.dart' as http;

/// sing-box 内核版本检查：比对本机版本与 GitHub 最新正式版。
/// 真正的下载、校验与替换由特权服务做（IPC `kernel.upgrade`），这里只出版本号。
class KernelUpdate {
  const KernelUpdate({required this.current, required this.latest});

  // /releases/latest 只给正式版，预发布版不会被算进来，正合内核选型要求
  static const String _releaseApi =
      'https://api.github.com/repos/SagerNet/sing-box/releases/latest';
  static const Duration _timeout = Duration(seconds: 10);

  /// 本机内核自报版本，空表示没问到（特权服务未运行）
  final String current;
  final String latest;

  bool get outdated => current.isNotEmpty && current != latest;

  static Future<KernelUpdate> check(String current) async {
    final http.Response response = await http
        .get(
          Uri.parse(_releaseApi),
          headers: const <String, String>{
            'Accept': 'application/vnd.github+json',
          },
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw KernelUpdateException('GitHub 返回 HTTP ${response.statusCode}');
    }

    final Object? payload = jsonDecode(utf8.decode(response.bodyBytes));
    final Object? tag = payload is Map<String, dynamic>
        ? payload['tag_name']
        : null;
    final String latest = tag is String ? tag.replaceFirst('v', '') : '';

    if (latest.isEmpty) {
      throw KernelUpdateException('GitHub 未给出版本号');
    }

    return KernelUpdate(current: current, latest: latest);
  }
}

class KernelUpdateException implements Exception {
  KernelUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}
