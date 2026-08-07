import 'dart:async';

import 'package:flutter/services.dart';

import '../../domain/config/local_template.dart';
import '../../domain/platform/platform_service.dart';

class AndroidPlatformService implements PlatformService {
  AndroidPlatformService() {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static const MethodChannel _channel = MethodChannel('ecycloud/platform');

  final StreamController<TrayAction> _trayActionController =
      StreamController<TrayAction>.broadcast();

  @override
  String get platformId => 'android';

  @override
  bool get supportsTun => true;

  /// VpnService 本身就是 TUN，关掉它等于连上也不接管任何流量
  @override
  bool get requiresTun => true;

  @override
  bool get supportsSystemProxy => false;

  @override
  bool get supportsTray => false;

  @override
  bool get supportsLaunchAtLogin => true;

  @override
  bool get supportsPerAppProxy => true;

  // VpnService 直接把 fd 交给内核，这个名字不参与建卡
  @override
  String get tunInterfaceName => LocalTemplateOptions.defaultTunInterfaceName;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> setSystemProxy({required int port}) async {}

  @override
  Future<void> restoreSystemProxy() async {}

  @override
  Future<SystemProxyState> systemProxyState() async => const SystemProxyState(
    enabled: false,
    server: '',
    snapshotPresent: false,
  );

  @override
  Future<bool> launchAtLoginEnabled() async =>
      await _channel.invokeMethod<bool>('autostart.get') ?? false;

  @override
  Future<void> setLaunchAtLogin({required bool enabled}) async {
    await _channel.invokeMethod<void>('autostart.set', <String, dynamic>{
      'enabled': enabled,
    });
  }

  @override
  Future<void> setCloseToTray({required bool enabled}) async {}

  @override
  Future<void> setImeEnabled({required bool enabled}) async {}

  @override
  Stream<TrayAction> get trayActions => _trayActionController.stream;

  @override
  Future<void> setTrayState(TrayState state) async {}

  @override
  Future<String> deviceName() async =>
      await _channel.invokeMethod<String>('device.name') ?? 'Android';

  @override
  Future<List<InstalledApp>> installedApps() async {
    final List<Object?>? result = await _channel.invokeMethod<List<Object?>>(
      'apps.list',
    );
    if (result == null) {
      return const <InstalledApp>[];
    }
    return <InstalledApp>[
      for (final Object? item in result)
        if (item is Map<Object?, Object?>)
          InstalledApp(
            packageName: item['package'] as String? ?? '',
            label: item['label'] as String? ?? '',
            system: item['system'] == true,
          ),
    ];
  }

  @override
  Future<bool> runInstaller(String path) async =>
      await _channel.invokeMethod<bool>('installer.run', <String, dynamic>{
        'path': path,
      }) ??
      false;

  @override
  Future<void> openUrl(String url) async {
    await _channel.invokeMethod<void>('url.open', <String, dynamic>{
      'url': url,
    });
  }

  @override
  Future<void> dispose() async {
    await _trayActionController.close();
  }

  // 通知栏磁贴走与桌面端托盘同一个指令，只有 toggle 一项
  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method != 'tray.action' ||
        call.arguments != 'toggle' ||
        _trayActionController.isClosed) {
      return;
    }
    _trayActionController.add(TrayAction.toggle);
  }
}
