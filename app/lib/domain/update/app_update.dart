import 'dart:ffi';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../core/app_config.dart';
import 'github_release.dart';

/// 客户端自身的版本检查。资产名由各平台出包脚本决定，按平台与架构后缀取。
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

  static Future<AppUpdate> check({http.Client? client}) async {
    final GithubRelease release = await GithubRelease.latest(
      repo,
      client: client,
    );
    return AppUpdate(
      current: AppConfig.appVersion,
      latest: release.version,
      installer: release.assetEndingWith(assetSuffix),
    );
  }

  /// 与 scripts/build-*.{ps1,sh} 的产物名后缀逐字一致。四端均按架构分包。
  static String get assetSuffix {
    if (Platform.isWindows) {
      return 'windows-$arch.exe';
    }
    if (Platform.isMacOS) {
      return 'macos-$arch.pkg';
    }
    if (Platform.isLinux) {
      return 'linux-$arch.deb';
    }
    // Android（及未识别平台的兜底）按 ABI 分包，与 build-android.sh 后缀一致
    return 'android-$arch.apk';
  }

  static String get arch => switch (Abi.current()) {
    Abi.androidArm64 ||
    Abi.windowsArm64 ||
    Abi.macosArm64 ||
    Abi.linuxArm64 =>
      'arm64',
    Abi.androidArm => 'arm',
    _ => 'x64',
  };

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
