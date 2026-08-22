import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/logger.dart';
import '../../core/safe_url.dart';
import '../../domain/config/local_template.dart';
import '../../domain/platform/platform_service.dart';

abstract class UnixPlatformService implements PlatformService {
  UnixPlatformService() {
    channel.setMethodCallHandler(_onNativeCall);
  }

  static const String source = 'platform';

  static const MethodChannel channel = MethodChannel('ecycloud/platform');

  static const Map<String, TrayAction> _trayActions = <String, TrayAction>{
    'connect': TrayAction.connect,
    'disconnect': TrayAction.disconnect,
    'system_proxy': TrayAction.toggleSystemProxy,
    'tun': TrayAction.toggleTun,
    'mode_rule': TrayAction.modeRule,
    'mode_global': TrayAction.modeGlobal,
    'mode_direct': TrayAction.modeDirect,
  };

  final StreamController<TrayAction> _trayActionController =
      StreamController<TrayAction>.broadcast();

  String get openCommand;

  @override
  bool get supportsTun => true;

  @override
  bool get requiresTun => false;

  @override
  bool get supportsSystemProxy => true;

  @override
  bool get supportsTray => true;

  @override
  bool get supportsLaunchAtLogin => true;

  @override
  bool get supportsPerAppProxy => false;

  @override
  bool get isTelevision => false;

  @override
  bool get supportsPayScheme => false;

  @override
  String get tunInterfaceName => LocalTemplateOptions.defaultTunInterfaceName;

  @override
  Future<void> initialize() async {
    await channel.invokeMethod<void>('tray.install');

    final SystemProxyState state = await systemProxyState();
    if (state.snapshotPresent) {
      Logger.instance.warn(source, '检测到上次未还原的系统代理，已自动还原');
      await restoreSystemProxy();
    }
  }

  @override
  Future<void> setCloseToTray({required bool enabled}) async {
    await channel.invokeMethod<void>('tray.closeToTray', <String, dynamic>{
      'enabled': enabled,
    });
  }

  /// 无法只关本窗口 IME（无窗口级输入法上下文）。
  @override
  Future<void> setImeEnabled({required bool enabled}) async {}

  @override
  Stream<TrayAction> get trayActions => _trayActionController.stream;

  @override
  Future<void> setTrayState(TrayState state) async {
    await channel.invokeMethod<void>('tray.state', state.toJson());
  }

  @override
  Future<String> deviceName() async => Platform.localHostname;

  @override
  Future<List<InstalledApp>> installedApps() async => const <InstalledApp>[];

  @override
  Future<bool> runInstaller(String path) => _spawn(<String>[path]);

  @override
  Future<bool> openUrl(String url) {
    if (!SafeUrl.canOpen(url)) {
      return Future<bool>.value(false);
    }
    return _spawn(<String>[url]);
  }

  @override
  Future<bool> openDirectory(String path) {
    if (path.isEmpty) {
      return Future<bool>.value(false);
    }
    return _spawn(<String>[path]);
  }

  @override
  Future<String> protectSecret(String name, String plaintext) =>
      _secretInvoke('secret.protect', name, plaintext);

  @override
  Future<String?> unprotectSecret(String name, String blob) async {
    try {
      return await channel.invokeMethod<String>(
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
      await channel.invokeMethod<void>('secret.delete', <String, dynamic>{
        'name': name,
      });
    } on PlatformException catch (e) {
      throw PlatformServiceException(e.message ?? '无法清除凭据');
    }
  }

  Future<String> _secretInvoke(String method, String name, String value) async {
    try {
      final String? blob = await channel.invokeMethod<String>(
        method,
        <String, dynamic>{'name': name, 'value': value},
      );
      if (blob == null) {
        throw PlatformServiceException('无法保护凭据');
      }
      return blob;
    } on PlatformException catch (e) {
      throw PlatformServiceException(e.message ?? '无法保护凭据');
    }
  }

  /// 必须脱离进程组。
  Future<bool> _spawn(List<String> arguments) async {
    try {
      await Process.start(
        openCommand,
        arguments,
        mode: ProcessStartMode.detached,
      );
      return true;
    } on ProcessException catch (e) {
      Logger.instance.error(
        source,
        '$openCommand ${arguments.join(' ')} 失败',
        e,
      );
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    await channel.invokeMethod<void>('tray.remove');
    await _trayActionController.close();
  }

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method != 'tray.action') {
      return;
    }
    final TrayAction? action = _trayActions[call.arguments as String?];
    if (action == null || _trayActionController.isClosed) {
      return;
    }
    _trayActionController.add(action);
  }
}
