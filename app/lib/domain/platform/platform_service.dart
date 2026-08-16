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

// toggle 由 Android 通知栏磁贴发出：磁贴只有一个按钮，该连还是该断由状态机判断
enum TrayAction { connect, disconnect, toggle, toggleSystemProxy, toggleTun }

class InstalledApp {
  const InstalledApp({
    required this.packageName,
    required this.label,
    required this.system,
  });

  final String packageName;
  final String label;
  final bool system;
}

class TrayLabels {
  const TrayLabels({
    required this.connect,
    required this.disconnect,
    required this.cancel,
    required this.systemProxy,
    required this.tun,
    required this.show,
    required this.quit,
  });

  final String connect;
  final String disconnect;
  final String cancel;
  final String systemProxy;
  final String tun;
  final String show;
  final String quit;

  @override
  bool operator ==(Object other) =>
      other is TrayLabels &&
      other.connect == connect &&
      other.disconnect == disconnect &&
      other.cancel == cancel &&
      other.systemProxy == systemProxy &&
      other.tun == tun &&
      other.show == show &&
      other.quit == quit;

  @override
  int get hashCode =>
      Object.hash(connect, disconnect, cancel, systemProxy, tun, show, quit);
}

class TrayState {
  const TrayState({
    required this.connected,
    required this.busy,
    required this.systemProxyEnabled,
    required this.tunEnabled,
    required this.darkMenu,
    required this.labels,
  });

  final bool connected;
  final bool busy;
  final bool systemProxyEnabled;
  final bool tunEnabled;

  // Win32 弹出菜单不走 Flutter 主题，明暗只能由原生侧另行设置
  final bool darkMenu;
  final TrayLabels labels;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'connected': connected,
    'busy': busy,
    'system_proxy': systemProxyEnabled,
    'tun': tunEnabled,
    'dark': darkMenu,
    'label_connect': labels.connect,
    'label_disconnect': labels.disconnect,
    'label_cancel': labels.cancel,
    'label_system_proxy': labels.systemProxy,
    'label_tun': labels.tun,
    'label_show': labels.show,
    'label_quit': labels.quit,
  };

  @override
  bool operator ==(Object other) =>
      other is TrayState &&
      other.connected == connected &&
      other.busy == busy &&
      other.systemProxyEnabled == systemProxyEnabled &&
      other.tunEnabled == tunEnabled &&
      other.darkMenu == darkMenu &&
      other.labels == labels;

  @override
  int get hashCode => Object.hash(
    connected,
    busy,
    systemProxyEnabled,
    tunEnabled,
    darkMenu,
    labels,
  );
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

  // TUN 是否为该平台唯一的接管方式。Android 的 VpnService 本身就是 TUN，关掉即不接管流量
  bool get requiresTun;

  bool get supportsSystemProxy;

  bool get supportsTray;

  bool get supportsLaunchAtLogin;

  // 能否按应用分流。只有 Android 有应用清单，桌面端的 tun 入站没有对应字段
  bool get supportsPerAppProxy;

  // TUN 网卡名，落到配置的 tun.device。darwin 的 utun 设备只能叫 utunN，内核的
  // checkTunName（listener/sing_tun/server.go）见到别的名字会打一行告警再自己改掉，
  // 因此 macOS 返回空串，让它直接走 CalculateInterfaceName，不留那行告警
  String get tunInterfaceName;

  Future<void> initialize();

  Future<void> setSystemProxy({
    required int port,
    required List<String> bypass,
  });

  Future<void> restoreSystemProxy();

  Future<SystemProxyState> systemProxyState();

  Future<bool> launchAtLoginEnabled();

  Future<void> setLaunchAtLogin({required bool enabled});

  Future<void> setCloseToTray({required bool enabled});

  /// 只解除本窗口与输入法的关联，不切换用户的系统输入法
  Future<void> setImeEnabled({required bool enabled});

  Stream<TrayAction> get trayActions;

  Future<void> setTrayState(TrayState state);

  Future<String> deviceName();

  /// 分应用代理的候选列表，只有 Android 拿得到，其余平台返回空
  Future<List<InstalledApp>> installedApps();

  /// 以管理员权限启动客户端安装包，返回 false 表示用户拒绝了提权
  Future<bool> runInstaller(String path);

  /// 返回 false 表示系统里没有能接手该链接的程序（如未安装支付 App），调用方需降级
  Future<bool> openUrl(String url);

  /// 用系统文件管理器打开本地目录。路径不存在或系统拒绝时返回 false
  Future<bool> openDirectory(String path);

  Future<String> protectSecret(String name, String plaintext);

  Future<String?> unprotectSecret(String name, String blob);

  Future<void> deleteSecret(String name);

  Future<void> dispose();
}
