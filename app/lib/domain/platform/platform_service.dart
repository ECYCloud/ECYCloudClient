class SystemProxyState {
  const SystemProxyState({
    required this.enabled,
    required this.server,
    required this.snapshotPresent,
  });

  final bool enabled;
  final String server;

  final bool snapshotPresent;
}

enum TrayAction { connect, disconnect, toggleSystemProxy, toggleTun }

class TrayState {
  const TrayState({
    required this.connected,
    required this.busy,
    required this.systemProxyEnabled,
    required this.tunEnabled,
    required this.darkMenu,
  });

  final bool connected;
  final bool busy;
  final bool systemProxyEnabled;
  final bool tunEnabled;

  // Win32 弹出菜单不走 Flutter 主题，明暗只能由原生侧另行设置
  final bool darkMenu;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'connected': connected,
    'busy': busy,
    'system_proxy': systemProxyEnabled,
    'tun': tunEnabled,
    'dark': darkMenu,
  };

  @override
  bool operator ==(Object other) =>
      other is TrayState &&
      other.connected == connected &&
      other.busy == busy &&
      other.systemProxyEnabled == systemProxyEnabled &&
      other.tunEnabled == tunEnabled &&
      other.darkMenu == darkMenu;

  @override
  int get hashCode =>
      Object.hash(connected, busy, systemProxyEnabled, tunEnabled, darkMenu);
}

// 不叫 PlatformException，避免与 package:flutter/services.dart 同名类冲突
class PlatformServiceException implements Exception {
  PlatformServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract class PlatformService {
  String get platformId;

  bool get supportsTun;

  bool get supportsSystemProxy;

  bool get supportsTray;

  bool get supportsLaunchAtLogin;

  Future<void> initialize();

  Future<void> setSystemProxy({required int port});

  Future<void> restoreSystemProxy();

  Future<SystemProxyState> systemProxyState();

  Future<bool> launchAtLoginEnabled();

  Future<void> setLaunchAtLogin({required bool enabled});

  Future<void> setCloseToTray({required bool enabled});

  Stream<TrayAction> get trayActions;

  Future<void> setTrayState(TrayState state);

  Future<String> deviceName();

  /// 以管理员权限启动客户端安装包，返回 false 表示用户拒绝了提权
  Future<bool> runInstaller(String path);

  Future<void> dispose();
}
