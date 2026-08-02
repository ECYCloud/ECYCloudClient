import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/logger.dart';
import '../../domain/platform/platform_service.dart';

/// macOS 与 Linux 桌面端共用的平台能力。托盘由原生侧持有（Win32 之外没有
/// 跨桌面的托盘 API），其余能力都能在 Dart 侧用进程与文件完成，不再下沉到原生。
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
  };

  final StreamController<TrayAction> _trayActionController =
      StreamController<TrayAction>.broadcast();

  /// 打开文件与链接的桌面入口命令
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

  /// macOS 与 Linux 没有「与单个窗口绑定的输入法上下文」这一层，
  /// 无法在不改用户系统输入法的前提下只关掉本窗口的组字
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
  Future<void> openUrl(String url) => _spawn(<String>[url]);

  /// 安装包与浏览器都由桌面环境接手，本进程随后会退出，必须脱离进程组
  Future<bool> _spawn(List<String> arguments) async {
    try {
      await Process.start(
        openCommand,
        arguments,
        mode: ProcessStartMode.detached,
      );
      return true;
    } on ProcessException catch (e) {
      Logger.instance.error(source, '$openCommand ${arguments.join(' ')} 失败', e);
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
