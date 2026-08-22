import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../core/app_paths.dart';
import '../core/logger.dart';
import '../domain/kernel/kernel_update.dart';
import '../domain/platform/platform_service.dart';
import '../domain/update/app_update.dart';
import '../l10n/l10n.dart';
import '../domain/update/github_release.dart';
import 'connection_controller.dart';

class UpdateController extends ChangeNotifier {
  // 命名参数不能写成 this._field，只能在初始化列表里赋值
  // ignore_for_file: prefer_initializing_formals
  UpdateController({
    required ConnectionController connection,
    required PlatformService platform,
  }) : _connection = connection,
       _platform = platform;

  static const Duration interval = Duration(hours: 24);
  static const String _source = 'update';

  final ConnectionController _connection;
  final PlatformService _platform;

  Timer? _timer;

  AppUpdate? _app;
  String? _appError;
  String? _appStage;
  int _appPercent = 0;

  String _kernelStatus = L10n.t('正在读取版本…');
  KernelUpdate? _kernel;
  bool _kernelUpgrading = false;
  int _kernelPercent = 0;
  Timer? _kernelProgressTimer;

  bool _checking = false;
  bool _retryWhenConnected = false;
  String _dismissedKey = '';

  AppUpdate? get appUpdate => _app;

  String get appStatus {
    final String? stage = _appStage;
    if (stage != null) {
      return _statusWithPercent(stage, _appPercent);
    }
    final String? error = _appError;
    if (error != null) {
      return error;
    }
    final AppUpdate? app = _app;
    if (app == null) {
      return L10n.t('尚未检查');
    }
    if (!app.outdated) {
      return L10n.t('已是最新（{0}）', <Object>[app.latest]);
    }
    if (!AppUpdate.selfInstallable) {
      return L10n.t('发现新版本（{0}），需自行安装', <Object>[app.latest]);
    }
    return app.installer == null
        ? L10n.t('发现新版本（{0}），无对应安装包', <Object>[app.latest])
        : L10n.t('发现新版本（{0}）', <Object>[app.latest]);
  }

  bool get appInstallable =>
      _app?.outdated == true && _app?.installer != null && _appStage == null;

  bool get appManualOnly =>
      _app?.outdated == true && !AppUpdate.selfInstallable;

  bool get appBusy => _appStage != null;

  int? get appPercent => appBusy && _appPercent > 0 ? _appPercent : null;

  KernelUpdate? get kernelUpdate => _kernel;

  String get kernelStatus => _kernelStatus;

  String? get kernelUpgradable =>
      _kernel?.outdated == true && _connection.kernelUpgradeSupported
      ? _kernel!.latest
      : null;

  bool get kernelUpgrading => _kernelUpgrading;

  int? get kernelPercent =>
      _kernelUpgrading && _kernelPercent > 0 ? _kernelPercent : null;

  bool get requiresUpdate =>
      (_app?.outdated == true && _app?.installer != null) ||
      kernelUpgradable != null;

  bool get shouldPromptUpdate =>
      requiresUpdate && _updateKey.isNotEmpty && _updateKey != _dismissedKey;

  bool get updateNetworkReady =>
      _connection.state == ConnectionPhase.connected &&
      (_connection.settings.systemProxyEnabled ||
          _connection.settings.tunEnabled);

  void dismissUpdatePrompt() => _dismissedKey = _updateKey;

  Future<bool> githubReachable() async {
    if (!updateNetworkReady) {
      return false;
    }
    final http.Client client = _httpClient();
    try {
      return await GithubRelease.reachable(client);
    } finally {
      client.close();
    }
  }

  http.Client _httpClient() {
    if (!updateNetworkReady) {
      return http.Client();
    }
    final int port = _connection.settings.mixedPort;
    return IOClient(
      HttpClient()..findProxy = (Uri _) => 'PROXY 127.0.0.1:$port',
    );
  }

  String get _updateKey {
    final String app = _app?.outdated == true && _app?.installer != null
        ? 'app${_app!.latest}'
        : '';
    final String kernel = kernelUpgradable == null
        ? ''
        : 'kernel$kernelUpgradable';
    return '$app$kernel';
  }

  void start() {
    _connection.addListener(_onConnectionChanged);
    unawaited(loadKernelVersion().then((_) => checkAll()));
    _timer = Timer.periodic(interval, (_) => unawaited(checkAll()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _kernelProgressTimer?.cancel();
    _connection.removeListener(_onConnectionChanged);
    super.dispose();
  }

  Future<void> checkAll() async {
    if (_checking) {
      return;
    }
    _checking = true;
    try {
      await checkApp();
      await checkKernel();
    } finally {
      _checking = false;
    }
  }

  Future<void> checkApp() async {
    final http.Client client = _httpClient();
    try {
      _app = await AppUpdate.check(client: client);
      _appError = null;
      _retryWhenConnected = false;
    } on Object catch (e) {
      _appError = L10n.t('检查失败：{0}', <Object>['$e']);
      _retryWhenConnected = true;
      Logger.instance.debug(_source, '检查客户端更新失败: $e');
    } finally {
      client.close();
    }
    notifyListeners();
  }

  Future<void> checkKernel() async {
    final http.Client client = _httpClient();
    try {
      final KernelUpdate update = await KernelUpdate.check(
        await _connection.kernelVersion(),
        client: client,
      );
      _kernel = update;
      if (update.current.isEmpty) {
        _kernelStatus = L10n.t('本机版本未知，最新（{0}）', <Object>[update.latest]);
      } else if (update.outdated) {
        _kernelStatus = _connection.kernelUpgradeSupported
            ? L10n.t('发现新版本（{0}）', <Object>[update.latest])
            : L10n.t('发现新版本（{0}），将随新版客户端提供，无需单独更新', <Object>[update.latest]);
      } else {
        _kernelStatus = L10n.t('已是最新（{0}）', <Object>[update.current]);
      }
    } on Object catch (e) {
      _kernelStatus = L10n.t('检查失败：{0}', <Object>['$e']);
      _retryWhenConnected = true;
      Logger.instance.debug(_source, '检查内核更新失败: $e');
    } finally {
      client.close();
    }
    notifyListeners();
  }

  Future<void> loadKernelVersion() async {
    if (_kernel != null) {
      return;
    }
    final String version = await _connection.kernelVersion();
    _kernelStatus = version.isEmpty
        ? L10n.t('本机版本未知')
        : L10n.t('当前（{0}）', <Object>[version]);
    notifyListeners();
  }

  Future<void> upgradeKernel() async {
    final String? version = kernelUpgradable;
    if (version == null || _kernelUpgrading) {
      return;
    }

    _kernelUpgrading = true;
    _kernelPercent = 0;
    _kernelStatus = L10n.t('正在更新（{0}）', <Object>[version]);
    notifyListeners();
    _startKernelProgressPoll();

    try {
      final String installed = await _connection.upgradeKernel(version);
      _kernel = KernelUpdate(current: installed, latest: installed);
      _kernelStatus = L10n.t('更新成功（{0}）', <Object>[installed]);
    } on Object catch (e) {
      _kernelStatus = L10n.t('更新失败：{0}', <Object>['$e']);
    } finally {
      _stopKernelProgressPoll();
      _kernelUpgrading = false;
      _kernelPercent = 0;
      notifyListeners();
    }
  }

  void _startKernelProgressPoll() {
    _kernelProgressTimer?.cancel();
    _kernelProgressTimer = Timer.periodic(const Duration(milliseconds: 400), (
      _,
    ) {
      unawaited(_pollKernelProgress());
    });
  }

  void _stopKernelProgressPoll() {
    _kernelProgressTimer?.cancel();
    _kernelProgressTimer = null;
  }

  Future<void> _pollKernelProgress() async {
    if (!_kernelUpgrading) {
      return;
    }
    try {
      final ({String stage, int percent}) progress = await _connection
          .kernelUpgradeProgress();
      if (!_kernelUpgrading) {
        return;
      }
      final String label = _kernelStageLabel(progress.stage);
      if (label.isEmpty) {
        return;
      }
      final int percent = progress.percent;
      final String next = _statusWithPercent(label, percent);
      if (next == _kernelStatus && percent == _kernelPercent) {
        return;
      }
      _kernelStatus = next;
      _kernelPercent = percent;
      notifyListeners();
    } on Object catch (_) {}
  }

  static String _statusWithPercent(String stage, int percent) =>
      percent > 0 ? '$stage（$percent%）' : stage;

  static String _kernelStageLabel(String stage) => switch (stage) {
    'resolving' => L10n.t('正在解析发布信息'),
    'downloading' => L10n.t('正在下载内核'),
    'verifying' => L10n.t('正在校验内核'),
    'extracting' => L10n.t('正在解压内核'),
    'installing' => L10n.t('正在安装内核'),
    _ => '',
  };

  /// 下载并校验安装包后交给安装器接手。安装器认客户端的单实例互斥体，
  /// 本进程必须立刻退出；系统代理与内核由特权服务在 GUI 退出后收尾。
  Future<void> installApp() async {
    final GithubAsset? asset = _app?.installer;
    if (asset == null || appBusy) {
      return;
    }

    _appError = null;
    _appStage = L10n.t('正在下载 {0}', <Object>[asset.name]);
    _appPercent = 0;
    notifyListeners();

    try {
      final File file = await _download(asset);

      _appStage = L10n.t('正在校验安装包');
      _appPercent = 0;
      notifyListeners();

      if (asset.sha256.isEmpty) {
        throw GithubReleaseException('发布资产没有校验值，已中止更新');
      }
      final String actual = sha256.convert(await file.readAsBytes()).toString();
      if (actual != asset.sha256.toLowerCase()) {
        await file.delete();
        throw GithubReleaseException('安装包校验失败，已删除');
      }

      _appStage = L10n.t('正在启动安装程序');
      notifyListeners();

      if (!await _platform.runInstaller(file.path)) {
        throw GithubReleaseException('已取消更新');
      }

      Logger.instance.info(_source, '安装器已启动，客户端退出让位');
      exit(0);
    } on Object catch (e) {
      _appError = L10n.t('更新失败：{0}', <Object>['$e']);
      Logger.instance.error(_source, '安装客户端更新失败', e);
    } finally {
      _appStage = null;
      notifyListeners();
    }
  }

  Future<File> _download(GithubAsset asset) async {
    if (!asset.url.startsWith(AppUpdate.downloadPrefix)) {
      throw GithubReleaseException('下载地址不在官方发布路径下，已中止更新');
    }
    final File file = File(
      '${AppPaths.updates.path}${Platform.pathSeparator}${_localName(asset.name)}',
    );
    final http.Client client = _httpClient();

    try {
      final http.StreamedResponse response = await client.send(
        http.Request('GET', Uri.parse(asset.url)),
      );
      if (response.statusCode != 200) {
        throw GithubReleaseException('下载返回 HTTP ${response.statusCode}');
      }

      final int total = response.contentLength ?? 0;
      final IOSink sink = file.openWrite();
      int received = 0;
      try {
        await for (final List<int> chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          // 每字节都通知会把界面刷爆，只在整数百分比变化时报一次
          final int percent = total > 0 ? received * 100 ~/ total : 0;
          if (percent != _appPercent) {
            _appPercent = percent;
            notifyListeners();
          }
        }
      } finally {
        await sink.close();
      }
      return file;
    } finally {
      client.close();
    }
  }

  // 资产名来自 GitHub 应答，直接拼进路径就等于让对方决定写到哪；
  // 只留文件名允许的字符，目录分隔与盘符一律落成下划线
  static String _localName(String name) =>
      name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  void _onConnectionChanged() {
    if (!_retryWhenConnected || !updateNetworkReady) {
      return;
    }
    _retryWhenConnected = false;
    unawaited(checkAll());
  }
}
