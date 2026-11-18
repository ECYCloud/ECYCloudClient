import 'package:http/http.dart' as http;

import '../update/github_release.dart';

class KernelUpdate {
  const KernelUpdate({required this.current, required this.latest});

  static const String repo = 'MetaCubeX/mihomo';

  final String current;
  final String latest;

  bool get outdated => current.isNotEmpty && current != latest;

  static Future<KernelUpdate> check(
    String current, {
    http.Client? client,
    String? siteOrigin,
  }) async {
    final GithubRelease? release = GithubRelease.newestStable(
      await GithubRelease.list(
        repo,
        client: client,
        latestStableOnly: true,
        mirror: siteOrigin == null
            ? null
            : Uri.parse('$siteOrigin/api/client/v1/releases/kernel'),
      ),
    );
    if (release == null) {
      throw GithubReleaseException('GitHub 未给出版本号');
    }
    return KernelUpdate(current: current, latest: release.version);
  }
}
