import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/safe_url.dart';
import '../../domain/config/local_template.dart';
import '../../domain/platform/platform_service.dart';

class AndroidPlatformService implements PlatformService {
  AndroidPlatformService() {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static const MethodChannel _channel = MethodChannel('ecycloud/platform');

  bool _isTelevision = false;

  final StreamController<TrayAction> _trayActionController =
      StreamController<TrayAction>.broadcast();

  @override
  String get platformId => 'android';

  @override
  bool get supportsTun => true;

  /// VpnService 本身就是 TUN。
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

  @override
  bool get isTelevision => _isTelevision;

  @override
  bool get supportsPayScheme => !isTelevision;

  @override
  String get tunInterfaceName => LocalTemplateOptions.defaultTunInterfaceName;

  @override
  Future<void> initialize() async {
    _isTelevision =
        await _channel.invokeMethod<bool>('device.television') ?? false;
  }

  @override
  Future<void> setSystemProxy({
    required int port,
    required List<String> bypass,
  }) async {}

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
  Future<void> setWindowDark({
    required bool dark,
    int caption = 0,
    int text = 0,
  }) async {}

  @override
  Future<String> deviceName() async =>
      await _channel.invokeMethod<String>('device.name') ?? 'Android';

  @override
  Future<({String model, String os})> deviceProfile() async {
    final Map<Object?, Object?>? profile = await _channel
        .invokeMethod<Map<Object?, Object?>>('device.profile');
    return (
      model: profile?['model'] as String? ?? '',
      os: profile?['os'] as String? ?? '',
    );
  }

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
  Future<bool> openUrl(String url) async {
    if (!SafeUrl.canOpen(url)) {
      return false;
    }
    return await _channel.invokeMethod<bool>('url.open', <String, dynamic>{
          'url': url,
        }) ??
        false;
  }

  @override
  Future<bool> openDirectory(String path) async {
    if (path.isEmpty) {
      return false;
    }
    return await _channel.invokeMethod<bool>('dir.open', <String, dynamic>{
          'path': path,
        }) ??
        false;
  }

  @override
  Future<String> protectSecret(String name, String plaintext) async {
    try {
      final String? blob = await _channel.invokeMethod<String>(
        'secret.protect',
        <String, dynamic>{'name': name, 'value': plaintext},
      );
      if (blob == null) {
        throw PlatformServiceException('无法保护凭据');
      }
      return blob;
    } on PlatformException catch (e) {
      throw PlatformServiceException(e.message ?? '无法保护凭据');
    }
  }

  @override
  Future<String?> unprotectSecret(String name, String blob) async {
    try {
      return await _channel.invokeMethod<String>(
        'secret.unprotect',
        <String, dynamic>{'name': name, 'value': blob},
      );
    } on PlatformException catch (e) {
      throw PlatformServiceException(e.message ?? '无法读取凭据');
    }
  }

  @override
  Future<void> deleteSecret(String name) async {
    try {
      await _channel.invokeMethod<void>('secret.delete', <String, dynamic>{
        'name': name,
      });
    } on PlatformException catch (e) {
      throw PlatformServiceException(e.message ?? '无法清除凭据');
    }
  }

  @override
  Future<void> dispose() async {
    await _trayActionController.close();
  }

  // 磁贴与桌面托盘同一指令，只有 toggle
  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method != 'tray.action' ||
        call.arguments != 'toggle' ||
        _trayActionController.isClosed) {
      return;
    }
    _trayActionController.add(TrayAction.toggle);
  }
}
