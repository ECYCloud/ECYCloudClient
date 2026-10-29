import 'dart:io';

import '../../core/logger.dart';
import '../../domain/platform/platform_service.dart';
import '../unix/helper_client.dart';
import '../unix/unix_platform_service.dart';

class MacosPlatformService extends UnixPlatformService {
  MacosPlatformService(this._helper);

  factory MacosPlatformService.production() => MacosPlatformService(
    const HelperClient(HelperClient.defaultSocketPath, helperMissingHint),
  );

  static const String helperMissingHint = '后台服务未安装或未运行，请重新运行安装包';

  static const String _launchAgentLabel = 'com.ecycloud.client';

  final HelperClient _helper;

  Future<String>? _name;

  @override
  String get platformId => 'macos';

  @override
  String get openCommand => 'open';

  @override
  String get tunInterfaceName => '';

  @override
  Future<({String model, String os})> deviceProfile() async => (
    model: 'Mac（Flutter）',
    os: 'macOS ${RegExp(r'\d+(\.\d+)*').stringMatch(Platform.operatingSystemVersion) ?? ''}'
        .trimRight(),
  );

  // 主机名是 PCdeMacBook-Air.local 这类网络名；与 Apple 原生端一样登记系统设置里的电脑名
  @override
  Future<String> deviceName() => _name ??= _computerName();

  Future<String> _computerName() async {
    try {
      final ProcessResult result = await Process.run('scutil', <String>[
        '--get',
        'ComputerName',
      ]);
      final String name = '${result.stdout}'.trim();
      if (result.exitCode == 0 && name.isNotEmpty) {
        return name;
      }
    } on ProcessException catch (e) {
      Logger.instance.warn(UnixPlatformService.source, '读取电脑名失败: $e');
    }
    return Platform.localHostname;
  }

  @override
  Future<void> setSystemProxy({
    required int port,
    required List<String> bypass,
  }) async {
    await _helper.request('proxy.set', <String, dynamic>{
      'port': port,
      'bypass': bypass,
    });
  }

  @override
  Future<void> restoreSystemProxy() async {
    await _helper.request('proxy.restore');
  }

  @override
  Future<SystemProxyState> systemProxyState() async {
    final Map<String, dynamic> result = await _helper.request('proxy.state');
    return SystemProxyState(
      enabled: result['enabled'] == true,
      server: result['server'] as String? ?? '',
      snapshotPresent: result['snapshot_present'] == true,
    );
  }

  @override
  Future<bool> launchAtLoginEnabled() async => _launchAgent.existsSync();

  @override
  Future<void> setLaunchAtLogin({required bool enabled}) async {
    final File plist = _launchAgent;
    if (!enabled) {
      if (plist.existsSync()) {
        plist.deleteSync();
      }
      await _launchctl('disable');
      return;
    }

    plist.parent.createSync(recursive: true);
    plist.writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$_launchAgentLabel</string>
	<key>ProgramArguments</key>
	<array>
		<string>${_xmlText(Platform.resolvedExecutable)}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
''');
    // 用户在「系统设置 - 登录项」里关过一次，launchd 就把这个 label 记进了禁用表，
    // 之后只重写 plist 不会恢复自启，必须显式解禁
    await _launchctl('enable');
    Logger.instance.info(UnixPlatformService.source, '已写入登录项 ${plist.path}');
  }

  // launchctl 的域名目标只认数字 uid，没有 gui/self 这种写法，交给 shell 展开
  Future<void> _launchctl(String subcommand) async {
    final ProcessResult result = await Process.run('/bin/sh', <String>[
      '-c',
      'launchctl $subcommand "gui/\$(id -u)/$_launchAgentLabel"',
    ]);
    if (result.exitCode != 0) {
      Logger.instance.warn(
        UnixPlatformService.source,
        'launchctl $subcommand 失败（${result.exitCode}）：'
        '${(result.stderr as String).trim()}',
      );
    }
  }

  File get _launchAgent => File(
    '${Platform.environment['HOME']}/Library/LaunchAgents/$_launchAgentLabel.plist',
  );

  // 用户可以把 .app 挪走或改名，路径里的 & < > 会让 plist 变成非法 XML，
  // launchd 直接拒载，登录项就悄悄失效了
  static String _xmlText(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
