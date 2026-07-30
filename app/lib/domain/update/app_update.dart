import 'dart:ffi';

import '../../core/app_config.dart';
import 'github_release.dart';

/// 客户端自身的版本检查。资产名由 scripts/installer/ecycloud.iss 的
/// OutputBaseFilename 决定（ECYCloud-<版本>-windows-<架构>.exe），按架构后缀取。
class AppUpdate {
  const AppUpdate({
    required this.current,
    required this.latest,
    required this.installer,
  });

  static const String repo = 'ECYCloud/ECYCloudClient';

  /// 本机版本，调试构建为 `dev`
  final String current;
  final String latest;

  /// 本机架构对应的安装包，为空表示该发布没提供
  final GithubAsset? installer;

  bool get outdated => _newer(latest, current);

  static Future<AppUpdate> check() async {
    final GithubRelease release = await GithubRelease.latest(repo);
    return AppUpdate(
      current: AppConfig.appVersion,
      latest: release.version,
      installer: release.assetEndingWith('windows-$arch.exe'),
    );
  }

  static String get arch => Abi.current() == Abi.windowsArm64 ? 'arm64' : 'x64';

  static bool _newer(String latest, String current) {
    final List<int>? a = _parse(latest);
    final List<int>? b = _parse(current);
    if (a == null || b == null) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return a[i] > b[i];
      }
    }
    return false;
  }

  static List<int>? _parse(String version) {
    final List<String> parts = version.split('.');
    if (parts.length != 3) {
      return null;
    }
    final List<int> numbers = <int>[];
    for (final String part in parts) {
      final int? value = int.tryParse(part);
      if (value == null) {
        return null;
      }
      numbers.add(value);
    }
    return numbers;
  }
}
