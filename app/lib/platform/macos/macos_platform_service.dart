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

  /// 登录项写在用户自己的 LaunchAgents 下，不需要提权，登录时由 launchd 拉起
  static const String _launchAgentLabel = 'com.ecycloud.client';

  final HelperClient _helper;

  @override
  String get platformId => 'macos';

  @override
  String get openCommand => 'open';

  @override
  String get tunInterfaceName => '';

  @override
  Future<void> setSystemProxy({required int port}) async {
    await _helper.request('proxy.set', <String, dynamic>{'port': port});
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
		<string>${Platform.resolvedExecutable}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
''');
    Logger.instance.info(UnixPlatformService.source, '已写入登录项 ${plist.path}');
  }

  File get _launchAgent => File(
    '${Platform.environment['HOME']}/Library/LaunchAgents/$_launchAgentLabel.plist',
  );
}
