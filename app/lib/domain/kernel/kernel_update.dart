import '../update/github_release.dart';

/// sing-box 内核版本检查：比对本机版本与 GitHub 最新正式版。
/// 真正的下载、校验与替换由特权服务做（IPC `kernel.upgrade`），这里只出版本号。
class KernelUpdate {
  const KernelUpdate({required this.current, required this.latest});

  static const String repo = 'SagerNet/sing-box';

  /// 本机内核自报版本，空表示没问到（特权服务未运行）
  final String current;
  final String latest;

  bool get outdated => current.isNotEmpty && current != latest;

  static Future<KernelUpdate> check(String current) async {
    final GithubRelease release = await GithubRelease.latest(repo);
    return KernelUpdate(current: current, latest: release.version);
  }
}
