import 'dart:io';

import 'package:flutter/services.dart';

// GUI 以普通用户权限只写 userData，特权侧（Windows 服务以 SYSTEM、Unix helper 以 root）
// 只写 machineData，不得交叉。Android 无特权侧，内核与 GUI 同进程，两者同为应用私有目录。
class AppPaths {
  AppPaths._();

  static const String vendorDirName = 'ECYCloud';

  static String _androidBase = '';

  // 应用私有目录只有 Android 原生侧知道，必须在触碰任何路径之前取回
  static Future<void> bootstrap() async {
    if (!Platform.isAndroid) {
      return;
    }
    final String? base = await const MethodChannel(
      'ecycloud/platform',
    ).invokeMethod<String>('paths.data');
    if (base == null || base.isEmpty) {
      throw StateError('原生侧未返回应用数据目录');
    }
    _androidBase = base;
  }

  static final Directory userData = _restrictToOwner(
    _ensure(Directory(_resolveUserData())),
  );

  static final Directory machineData = Directory(_resolveMachineData());

  static File get credentials => File(_join(userData.path, 'credentials.json'));

  static File get settings => File(_join(userData.path, 'settings.json'));

  static File get installerLocale =>
      File(_join(userData.path, 'installer-locale'));

  static File get announcementState =>
      File(_join(userData.path, 'announcement.json'));

  // 上次成功的账号资料 / 面板配置：限流 429 时复用，避免冷启动无内存缓存就失败
  static File get profileCache =>
      File(_join(userData.path, 'profile-cache.json'));

  static File get remoteConfigCache =>
      File(_join(userData.path, 'remote-config-cache.json'));

  // Windows 停内核是 TerminateProcess，mihomo 来不及关 bbolt；cache.db 校验失败会被整份删掉，选择另落 userData
  static File get selectorCache =>
      File(_join(userData.path, 'selector-cache.json'));

  static Directory get logs => _ensure(Directory(_join(userData.path, 'logs')));

  static Directory get iconCache =>
      _ensure(Directory(_join(userData.path, 'icons')));

  static Directory get videoCache =>
      _ensure(Directory(_join(userData.path, 'videos')));

  static Directory get updates =>
      _ensure(Directory(_join(userData.path, 'updates')));

  // Linux 的代理设置属用户会话（GSettings 走会话 D-Bus），root 改不到，由 GUI 自己
  // 快照；Windows 服务与 macOS helper 的快照归特权侧，落在 GUI 读不到的运行目录里
  static File get proxySnapshot =>
      File(_join(userData.path, 'proxy-snapshot.json'));

  // 必须与特权侧 runDir() / Android BoxState.runDir() 逐字一致
  static String get kernelRunDir => _join(machineData.path, 'run');

  // 内核启动时用的那份配置。内核活得比界面久时，靠它读回控制面端口与 secret
  static String get kernelConfigFile => _join(kernelRunDir, 'config.json');

  static String _resolveUserData() {
    if (Platform.isAndroid) {
      if (_androidBase.isEmpty) {
        throw StateError('应用数据目录尚未就绪，AppPaths.bootstrap 未先行完成');
      }
      return _androidBase;
    }
    if (Platform.isWindows) {
      return _join(_env('APPDATA'), vendorDirName);
    }
    if (Platform.isMacOS) {
      return _join(
        _join(_env('HOME'), 'Library/Application Support'),
        vendorDirName,
      );
    }
    final String? xdg = Platform.environment['XDG_CONFIG_HOME'];
    return _join(
      xdg == null || xdg.isEmpty ? _join(_env('HOME'), '.config') : xdg,
      vendorDirName,
    );
  }

  // 特权侧写入、GUI 只读的目录，必须与 native 侧 dataDir() 逐字一致
  static String _resolveMachineData() {
    if (Platform.isAndroid) {
      return userData.path;
    }
    if (Platform.isWindows) {
      return _join(_env('ProgramData'), vendorDirName);
    }
    if (Platform.isMacOS) {
      return _join('/Library/Application Support', vendorDirName);
    }
    return _join('/var/lib', vendorDirName);
  }

  static Directory _ensure(Directory directory) {
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    return directory;
  }

  // Unix umask 默认 0755，Dart 没有 chmod，只能借外部命令把目录收成 700；Android / Windows 靠系统隔离
  static Directory _restrictToOwner(Directory directory) {
    if (Platform.isLinux || Platform.isMacOS) {
      Process.runSync('chmod', <String>['700', directory.path]);
    }
    return directory;
  }

  static String _env(String name) {
    final String? value = Platform.environment[name];
    if (value == null || value.isEmpty) {
      throw StateError('环境变量 $name 不存在，无法定位应用数据目录');
    }
    return value;
  }

  static String _join(String a, String b) =>
      '${a.replaceAll(RegExp(r'[\\/]+$'), '')}${Platform.pathSeparator}$b';
}
