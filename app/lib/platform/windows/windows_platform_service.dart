import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/logger.dart';
import '../../domain/platform/platform_service.dart';
import 'service_pipe.dart';

class WindowsPlatformService implements PlatformService {
  WindowsPlatformService() : _pipe = ServicePipe.production() {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static const String _source = 'platform';
  static const MethodChannel _channel = MethodChannel('ecycloud/platform');

  static const Map<String, TrayAction> _trayActions = <String, TrayAction>{
    'connect': TrayAction.connect,
    'disconnect': TrayAction.disconnect,
    'system_proxy': TrayAction.toggleSystemProxy,
    'tun': TrayAction.toggleTun,
  };

  final ServicePipe _pipe;
  final StreamController<TrayAction> _trayActionController =
      StreamController<TrayAction>.broadcast();

  @override
  String get platformId => 'windows';

  @override
  bool get supportsTun => true;

  @override
  bool get supportsSystemProxy => true;

  @override
  bool get supportsTray => true;

  @override
  bool get supportsLaunchAtLogin => true;

  @override
  Future<void> initialize() async {
    await _channel.invokeMethod<void>('tray.install');

    final SystemProxyState state = await systemProxyState();
    if (state.snapshotPresent) {
      Logger.instance.warn(_source, '检测到上次未还原的系统代理，已自动还原');
      await restoreSystemProxy();
    }
  }

  @override
  Future<void> setSystemProxy({required int port}) async {
    await _pipe.request('proxy.set', <String, dynamic>{'port': port});
  }

  @override
  Future<void> restoreSystemProxy() async {
    await _pipe.request('proxy.restore');
  }

  @override
  Future<SystemProxyState> systemProxyState() async {
    final Map<String, dynamic> result = await _pipe.request('proxy.state');
    return SystemProxyState(
      enabled: result['enabled'] == true,
      server: result['server'] as String? ?? '',
      snapshotPresent: result['snapshot_present'] == true,
    );
  }

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
  Future<void> setCloseToTray({required bool enabled}) async {
    await _channel.invokeMethod<void>('tray.closeToTray', <String, dynamic>{
      'enabled': enabled,
    });
  }

  @override
  Stream<TrayAction> get trayActions => _trayActionController.stream;

  @override
  Future<void> setTrayState(TrayState state) async {
    await _channel.invokeMethod<void>('tray.state', state.toJson());
  }

  @override
  Future<String> deviceName() async => Platform.localHostname;

  @override
  Future<void> dispose() async {
    await _channel.invokeMethod<void>('tray.remove');
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
