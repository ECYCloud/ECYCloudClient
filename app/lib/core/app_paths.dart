import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'logger.dart';

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
    final String? base = await const MethodChannel('ecycloud/platform')
        .invokeMethod<String>('paths.data');
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

  static File get installerLocale => File(
    _join(
      Platform.isWindows
          ? File(Platform.resolvedExecutable).parent.path
          : userData.path,
      'installer-locale',
    ),
  );

  static File get announcementState =>
      File(_join(userData.path, 'announcement.json'));

  static File get ticketInbox =>
      File(_join(userData.path, 'ticket-inbox.json'));

  // 上次成功的账号资料 / 面板配置：限流 429 时复用，避免冷启动无内存缓存就失败
  static File get profileCache =>
      File(_join(userData.path, 'profile-cache.json'));

  static File get remoteConfigCache =>
      File(_join(userData.path, 'remote-config-cache.json'));

  static File get selectorCache =>
      File(_join(userData.path, 'selector-cache.json'));

  static File get trafficRank =>
      File(_join(userData.path, 'traffic-rank.json'));

  static File get speedTestQuota =>
      File(_join(userData.path, 'speed-test-quota.json'));

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

  // Unix umask 默认 0755，Dart 没有 chmod，只能借外部命令把目录收成 700；
  // Windows 用 icacls 去掉继承来的 ACE，只保留 SYSTEM / Administrators / 当前用户，
  // 否则 %APPDATA% 继承下来的组可读到明文面板配置缓存（含节点凭据，安全审计 AUD-22）
  static Directory _restrictToOwner(Directory directory) {
    if (Platform.isLinux || Platform.isMacOS) {
      final ProcessResult result = Process.runSync('chmod', <String>[
        '700',
        directory.path,
      ]);
      if (result.exitCode != 0) {
        throw FileSystemException('无法限制应用数据目录权限', directory.path);
      }
      return directory;
    }
    if (Platform.isWindows) {
      restrictWindowsDir(directory);
    }
    return directory;
  }

  // 尽力而为：拿不到当前用户 SID 或 icacls 失败都不抛出，避免把启动卡死；
  // 失败时退回到原先「随 %APPDATA% 继承」的行为，不比修复前更差
  @visibleForTesting
  static void restrictWindowsDir(Directory directory) {
    try {
      final String sid = _currentUserSid();
      if (sid.isEmpty) {
        _warnUnhardened('拿不到当前用户 SID');
        return;
      }
      // S-1-5-18=SYSTEM，S-1-5-32-544=Administrators；(OI)(CI)F 让子项继承完全控制。
      // 这里不能加 /C：带上它 icacls 即便报 “Failed processing” 也返回 0，失败无从判断
      final ProcessResult dacl = Process.runSync('icacls', <String>[
        directory.path,
        '/inheritance:r',
        '/grant:r',
        '*S-1-5-18:(OI)(CI)F',
        '/grant:r',
        '*S-1-5-32-544:(OI)(CI)F',
        '/grant:r',
        '*$sid:(OI)(CI)F',
        '/Q',
      ]);
      if (dacl.exitCode != 0) {
        _warnUnhardened('icacls 退出码 ${dacl.exitCode}');
        return;
      }
      // 目录直属的旧文件（如已写出的 remote-config-cache.json）改回按新目录 DACL 继承，
      // 清掉它们此前继承来的可读 ACE；不加 /T，不去动 logs/icons/videos 里的公开素材。
      // 这条必须留 /C，一个被占用的文件不该让其余文件都不处理；代价是失败时退出码仍是 0，
      // 只能看 stderr 是否为空——里面的文案随系统语言变，空与非空不变
      final ProcessResult reset = Process.runSync('icacls', <String>[
        '${directory.path}\\*',
        '/reset',
        '/C',
        '/Q',
      ]);
      final String resetError = '${reset.stderr}'.trim();
      if (reset.exitCode != 0 || resetError.isNotEmpty) {
        _warnUnhardened('目录内旧文件未能改回继承：${resetError.split('\n').first}');
      }
    } on Object catch (e) {
      // 见上：安全加固失败不阻断启动
      _warnUnhardened('$e');
    }
  }

  // Logger 落盘时会回读 AppPaths.logs，而本函数运行在 userData 的初始化器内，
  // 就地记日志会重入这个尚未赋值的字段；只能等初始化返回后再写
  static void _warnUnhardened(String reason) {
    scheduleMicrotask(
      () => Logger.instance.warn(
        'paths',
        '应用数据目录权限未收紧，凭据与面板缓存可能被本机其它账户读取：$reason',
      ),
    );
  }

  static String _currentUserSid() {
    try {
      final ProcessResult who = Process.runSync('whoami', <String>[
        '/user',
        '/fo',
        'csv',
        '/nh',
      ]);
      if (who.exitCode != 0) {
        return '';
      }
      // Entra ID 加入的设备上账户 SID 是 S-1-12-1-…，只认 S-1-5-21- 会漏掉
      final Match? sid = RegExp(
        r'S-1-\d+(?:-\d+)+',
      ).firstMatch(who.stdout.toString());
      return sid?.group(0) ?? '';
    } on Object {
      return '';
    }
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
