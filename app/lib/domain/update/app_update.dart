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
      installer: selfInstallable ? release.assetEndingWith(assetSuffix) : null,
    );
  }

  static String get releasesUrl => 'https://github.com/$repo/releases';

  /// Linux 的 tar.gz 要 root 解包再跑 install.sh，没有能接手的安装器，
  /// 客户端不下载也不代装，只把用户引到发布页。
  static bool get selfInstallable =>
      !Platform.isLinux || _linuxPackageFormat != 'tar.gz';

  /// 与 scripts/build-*.{ps1,sh} 的产物名后缀逐字一致。四端均按架构分包。
  static String get assetSuffix {
    if (Platform.isWindows) {
      return 'windows-$arch.exe';
    }
    if (Platform.isMacOS) {
      return 'macos-$arch.pkg';
    }
    if (Platform.isLinux) {
      return 'linux-$arch.$_linuxPackageFormat';
    }
    // Android（及未识别平台的兜底）按 ABI 分包，与 build-android.sh 后缀一致
    return 'android-$arch.apk';
  }

  /// Linux 同一架构出 deb / rpm / tar.gz 三种包，装的是哪种只有安装器知道，
  /// 由 build-linux.sh 写在安装目录里；调试构建没有这份标记，退回 deb。
  static final String _linuxPackageFormat = _readPackageFormat();

  static String _readPackageFormat() {
    final File marker = File(
      '${File(Platform.resolvedExecutable).parent.path}/package-format',
    );
    final String format = marker.existsSync()
        ? marker.readAsStringSync().trim()
        : '';
    return format.isEmpty ? 'deb' : format;
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
