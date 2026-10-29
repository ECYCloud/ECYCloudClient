import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/retry.dart';

import '../../l10n/l10n.dart';

/// version 只保留 X.Y.Z；通道由 prerelease 表达，tag 后缀不进版本号
class GithubRelease {
  const GithubRelease({
    required this.version,
    required this.prerelease,
    required this.publishedAt,
    required this.assets,
  });

  static const Duration _timeout = Duration(seconds: 10);
  static const int _maxResponseBytes = 4 * 1024 * 1024;

  final String version;
  final bool prerelease;
  final DateTime publishedAt;
  final List<GithubAsset> assets;

  /// 与本机 `ECYCLOUD_VERSION` 同形的完整版本串，Pre 前缀即通道标记
  String get displayVersion => prerelease ? 'Pre $version' : version;

  static Future<bool> reachable(http.Client client) async {
    try {
      final http.Response response = await _get(
        client,
        Uri.parse('https://api.github.com'),
        const Duration(seconds: 5),
      );
      // 挡劫持/错误页：必须是 GitHub API 根文档
      return response.body.contains('"current_user_url"');
    } on Object {
      return false;
    }
  }

  // 软件通道必须读取 /releases；仅内核可使用只返回正式版的 /releases/latest。
  static Future<List<GithubRelease>> list(
    String repo, {
    http.Client? client,
    bool latestStableOnly = false,
  }) async {
    final http.Client httpClient = client ?? http.Client();
    final bool owned = client == null;
    try {
      final http.Response response = await _get(
        httpClient,
        Uri.parse(
          'https://api.github.com/repos/$repo/releases'
          '${latestStableOnly ? '/latest' : '?per_page=30'}',
        ),
        _timeout,
      );

      final Object? payload = jsonDecode(utf8.decode(response.bodyBytes));
      final List<Object?> entries;
      if (latestStableOnly && payload is Map<String, dynamic>) {
        entries = <Object?>[payload];
      } else if (!latestStableOnly && payload is List<Object?>) {
        entries = payload;
      } else {
        throw GithubReleaseException('GitHub 返回内容无法解析');
      }

      final List<GithubRelease> releases = <GithubRelease>[];
      for (final Object? entry in entries) {
        if (entry is! Map<String, dynamic> ||
            entry['draft'] == true ||
            (latestStableOnly && entry['prerelease'] == true)) {
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

  static Future<http.Response> _get(
    http.Client client,
    Uri uri,
    Duration timeout,
  ) async {
    final Completer<void> abort = Completer<void>();
    final Timer deadline = Timer(timeout, abort.complete);
    final http.Client retryClient = RetryClient(
      client,
      retries: timeout.inSeconds,
      delay: (_) => const Duration(seconds: 1),
      when: (_) => false,
      whenError: (error, _) =>
          error is HandshakeException &&
          error.message == 'Connection terminated during handshake',
    );
    try {
      return await (() async {
        final http.StreamedResponse response = await retryClient.send(
          http.AbortableRequest('GET', uri, abortTrigger: abort.future)
            ..followRedirects = false
            ..headers['Accept'] = 'application/vnd.github+json',
        );
        if (response.statusCode != 200 ||
            (response.contentLength ?? 0) > _maxResponseBytes) {
          await response.stream.listen(null).cancel();
          if (response.statusCode != 200) {
            final bool rateLimited =
                response.statusCode == 429 ||
                (response.statusCode == 403 &&
                    (response.headers['x-ratelimit-remaining'] == '0' ||
                        response.headers.containsKey('retry-after')));
            if (rateLimited) {
              final DateTime retryAt = _rateLimitRetryAt(response.headers);
              throw GithubReleaseException(
                'GitHub 请求过于频繁（HTTP ${response.statusCode}），'
                '${retryAt.toString().split('.').first} 后重试',
                retryAt: retryAt,
              );
            }
            throw GithubReleaseException(
              'GitHub 返回 HTTP ${response.statusCode}',
            );
          }
          throw GithubReleaseException('GitHub 响应超过 4 MiB 限制');
        }
        final BytesBuilder body = BytesBuilder(copy: false);
        await for (final List<int> chunk in response.stream) {
          if (body.length + chunk.length > _maxResponseBytes) {
            throw GithubReleaseException('GitHub 响应超过 4 MiB 限制');
          }
          body.add(chunk);
        }
        return http.Response.bytes(body.takeBytes(), response.statusCode);
      })().timeout(timeout);
    } finally {
      deadline.cancel();
      if (!abort.isCompleted) abort.complete();
    }
  }

  static DateTime _rateLimitRetryAt(Map<String, String> headers) {
    final DateTime now = DateTime.now();
    int seconds = int.tryParse(headers['retry-after'] ?? '') ?? 0;
    if (headers['x-ratelimit-remaining'] == '0') {
      final int? reset = int.tryParse(headers['x-ratelimit-reset'] ?? '');
      if (reset != null) {
        final int remaining = reset - now.millisecondsSinceEpoch ~/ 1000;
        if (remaining > seconds) seconds = remaining;
      }
    }
    return now.add(Duration(seconds: seconds > 0 ? seconds : 60));
  }

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
      size = json['size'] is int ? json['size'] as int : 0,
      _digest = json['digest'] as String? ?? '';

  final String name;
  final String url;
  final int size;

  // 形如 sha256:…，与二进制同源：挡的是传输损坏与镜像替换
  final String _digest;

  String get sha256 =>
      _digest.startsWith('sha256:') ? _digest.substring('sha256:'.length) : '';
}

class GithubReleaseException implements Exception {
  GithubReleaseException(this.message, {this.retryAt});

  final String message;
  final DateTime? retryAt;

  @override
  String toString() => L10n.message(message);
}
