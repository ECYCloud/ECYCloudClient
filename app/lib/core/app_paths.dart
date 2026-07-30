import 'dart:io';

// GUI 以普通用户权限只写 userData，特权服务以 SYSTEM 只写 machineData，不得交叉。
class AppPaths {
  AppPaths._();

  static const String vendorDirName = 'ECYCloud';

  static final Directory userData = _ensure(
    Directory(_join(_env('APPDATA'), vendorDirName)),
  );

  static final Directory machineData = Directory(
    _join(_env('ProgramData'), vendorDirName),
  );

  static File get credentials => File(_join(userData.path, 'credentials.json'));

  static File get settings => File(_join(userData.path, 'settings.json'));

  static Directory get logs => _ensure(Directory(_join(userData.path, 'logs')));

  // 面板下发地址的图标缓存，删掉只会让客户端下次显示时重新取一遍
  static Directory get iconCache =>
      _ensure(Directory(_join(userData.path, 'icons')));

  static File get proxySnapshot =>
      File(_join(machineData.path, 'proxy-snapshot.json'));

  static String get kernelCacheFile =>
      _join(_join(machineData.path, 'run'), 'cache.db');

  static Directory _ensure(Directory directory) {
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
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
