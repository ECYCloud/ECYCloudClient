import 'dart:convert';

import 'package:http/http.dart' as http;

/// GitHub 的 /releases/latest 只返回正式版，预发布不会被算进来。
class GithubRelease {
  const GithubRelease({required this.version, required this.assets});

  static const Duration _timeout = Duration(seconds: 10);

  final String version;
  final List<GithubAsset> assets;

  static Future<GithubRelease> latest(String repo) async {
    final http.Response response = await http
        .get(
          Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
          headers: const <String, String>{
            'Accept': 'application/vnd.github+json',
          },
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw GithubReleaseException('GitHub 返回 HTTP ${response.statusCode}');
    }

    final Object? payload = jsonDecode(utf8.decode(response.bodyBytes));
    if (payload is! Map<String, dynamic>) {
      throw GithubReleaseException('GitHub 返回内容无法解析');
    }

    final Object? tag = payload['tag_name'];
    final String version = tag is String
        ? tag.replaceFirst(RegExp('^v'), '')
        : '';
    if (version.isEmpty) {
      throw GithubReleaseException('GitHub 未给出版本号');
    }

    final Object? assets = payload['assets'];
    return GithubRelease(
      version: version,
      assets: <GithubAsset>[
        if (assets is List<Object?>)
          for (final Object? asset in assets)
            if (asset is Map<String, dynamic>) GithubAsset.fromJson(asset),
      ],
    );
  }

  GithubAsset? assetEndingWith(String suffix) {
    for (final GithubAsset asset in assets) {
      if (asset.name.endsWith(suffix)) {
        return asset;
      }
    }
    return null;
  }
}

class GithubAsset {
  GithubAsset.fromJson(Map<String, dynamic> json)
    : name = json['name'] as String? ?? '',
      url = json['browser_download_url'] as String? ?? '',
      _digest = json['digest'] as String? ?? '';

  final String name;
  final String url;

  // 形如 sha256:…，与二进制同源：挡的是传输损坏与镜像替换
  final String _digest;

  String get sha256 =>
      _digest.startsWith('sha256:') ? _digest.substring('sha256:'.length) : '';
}

class GithubReleaseException implements Exception {
  GithubReleaseException(this.message);

  final String message;

  @override
  String toString() => message;
}
