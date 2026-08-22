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
  }) async {
    // mihomo 的 Prerelease-Alpha 常年占着 tip，内核只跟正式版
    final GithubRelease? release = GithubRelease.newestStable(
      await GithubRelease.list(repo, client: client),
    );
    if (release == null) {
      throw GithubReleaseException('GitHub 未给出版本号');
    }
    return KernelUpdate(current: current, latest: release.version);
  }
}
