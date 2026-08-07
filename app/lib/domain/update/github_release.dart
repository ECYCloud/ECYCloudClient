import 'dart:convert';

import 'package:http/http.dart' as http;

/// GitHub Releases 的一条发布。`version` 只保留 `X.Y.Z` 号段，
/// 通道由 `prerelease` 表达，tag 上的 `-pre` 之类后缀不进版本号。
class GithubRelease {
  const GithubRelease({
    required this.version,
    required this.prerelease,
    required this.publishedAt,
    required this.assets,
  });

  static const Duration _timeout = Duration(seconds: 10);

  final String version;
  final bool prerelease;
  final DateTime publishedAt;
  final List<GithubAsset> assets;

  /// 与本机 `ECYCLOUD_VERSION` 同形的完整版本串，Pre 前缀即通道标记
  String get displayVersion => prerelease ? 'Pre $version' : version;

  static Future<bool> reachable(http.Client client) async {
    try {
      final http.Response response = await client
          .get(
            Uri.parse('https://api.github.com'),
            headers: const <String, String>{
              'Accept': 'application/vnd.github+json',
            },
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        return false;
      }
      // 挡劫持/错误页：必须是 GitHub API 根文档
      return response.body.contains('"current_user_url"');
    } on Object {
      return false;
    }
  }

  /// 按 published_at 从新到旧列出全部正式发布，草稿与号段不合法的 tag 不计。
  /// 只走 /releases：/releases/latest 不返回 Pre-release，表达不了通道规则。
  static Future<List<GithubRelease>> list(
    String repo, {
    http.Client? client,
  }) async {
    final http.Client httpClient = client ?? http.Client();
    final bool owned = client == null;
    try {
      final http.Response response = await httpClient
          .get(
            Uri.parse(
              'https://api.github.com/repos/$repo/releases?per_page=30',
            ),
            headers: const <String, String>{
              'Accept': 'application/vnd.github+json',
            },
          )
          .timeout(_timeout);

      if (response.statusCode != 200) {
        throw GithubReleaseException('GitHub 返回 HTTP ${response.statusCode}');
      }

      final Object? payload = jsonDecode(utf8.decode(response.bodyBytes));
      if (payload is! List<Object?>) {
        throw GithubReleaseException('GitHub 返回内容无法解析');
      }

      final List<GithubRelease> releases = <GithubRelease>[];
      for (final Object? entry in payload) {
        if (entry is! Map<String, dynamic> || entry['draft'] == true) {
          continue;
        }
        final GithubRelease? release = _fromJson(entry);
        if (release != null) {
          releases.add(release);
        }
      }
      if (releases.isEmpty) {
        throw GithubReleaseException('GitHub 未给出版本号');
      }
      releases.sort(
        (GithubRelease a, GithubRelease b) =>
            b.publishedAt.compareTo(a.publishedAt),
      );
      return releases;
    } finally {
      if (owned) {
        httpClient.close();
      }
    }
  }

  /// 时间线上最新的正式版；全是 Pre-release 时为空
  static GithubRelease? newestStable(List<GithubRelease> releases) {
    for (final GithubRelease release in releases) {
      if (!release.prerelease) {
        return release;
      }
    }
    return null;
  }

  static GithubRelease? _fromJson(Map<String, dynamic> json) {
    final Object? tag = json['tag_name'];
    final RegExpMatch? number = tag is String
        ? RegExp(r'^v?(\d+\.\d+\.\d+)').firstMatch(tag)
        : null;
    final DateTime? published = DateTime.tryParse(
      json['published_at'] as String? ?? '',
    );
    if (number == null || published == null) {
      return null;
    }
    final Object? assets = json['assets'];
    return GithubRelease(
      version: number.group(1)!,
      prerelease: json['prerelease'] == true,
      publishedAt: published,
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
