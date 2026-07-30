import 'dart:async';

import 'package:flutter/material.dart';

import 'core/app_config.dart';
import 'core/logger.dart';
import 'data/store/credential_store.dart';
import 'data/store/settings_store.dart';
import 'domain/kernel/kernel_controller.dart';
import 'domain/platform/platform_service.dart';
import 'platform/platform_factory.dart';
import 'state/auth_controller.dart';
import 'state/connection_controller.dart';
import 'ui/app_scope.dart';
import 'ui/node_labels.dart';
import 'ui/pages/login_page.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!AppConfig.configured) {
    runApp(const _MisconfiguredApp());
    return;
  }

  final SettingsStore settingsStore = SettingsStore();
  Logger.instance.level = settingsStore.load().logLevel;
  Logger.instance.info('app', '客户端启动');

  await NodeLabels.load();

  final PlatformService platform = PlatformFactory.createPlatformService();
  final KernelController kernel = PlatformFactory.createKernelController();

  final AuthController auth = AuthController(platform, CredentialStore());
  final ConnectionController connection = ConnectionController(
    platform: platform,
    kernel: kernel,
    settingsStore: settingsStore,
  );

  runApp(
    AppScope(
      auth: auth,
      connection: connection,
      platform: platform,
      settingsStore: settingsStore,
      child: const EcyCloudApp(),
    ),
  );
}

class EcyCloudApp extends StatefulWidget {
  const EcyCloudApp({super.key});

  @override
  State<EcyCloudApp> createState() => _EcyCloudAppState();
}

class _EcyCloudAppState extends State<EcyCloudApp> {
  bool _bootstrapped = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_bootstrapped) {
      _bootstrapped = true;
      unawaited(_bootstrap());
    }
  }

  Future<void> _bootstrap() async {
    final AppScope scope = AppScope.of(context);

    scope.auth.addListener(_onAuthChanged);

    try {
      await scope.platform.initialize();
      await scope.connection.syncPlatformSettings();
    } on Object catch (e) {
      Logger.instance.error('app', '平台初始化失败', e);
    }

    await scope.connection.runPreflight();
    await scope.auth.restore();
  }

  void _onAuthChanged() {
    final AppScope scope = AppScope.of(context);
    scope.connection.attachApi(scope.auth.api);

    if (scope.auth.stage == AuthStage.loggedIn &&
        scope.connection.settings.autoConnect &&
        scope.connection.state == ConnectionPhase.disconnected) {
      unawaited(scope.connection.connect());
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppScope scope = AppScope.of(context);

    return ListenableBuilder(
      listenable: scope.connection,
      builder: (BuildContext context, _) => MaterialApp(
        title: 'ECY Cloud 网络助手',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: scope.connection.settings.themeMode,
        home: ListenableBuilder(
          listenable: scope.auth,
          builder: (BuildContext context, _) => switch (scope.auth.stage) {
            AuthStage.unknown => const _Splash(),
            AuthStage.loggedIn => const Shell(),
            _ => const LoginPage(),
          },
        ),
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class _MisconfiguredApp extends StatelessWidget {
  const _MisconfiguredApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ECY Cloud 网络助手',
    debugShowCheckedModeBanner: false,
    darkTheme: AppTheme.dark(),
    theme: AppTheme.light(),
    home: const Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            '构建缺少面板地址。\n'
            '请用 scripts/build-windows.ps1 构建，'
            '或调试时带上 --dart-define=ECYCLOUD_PANEL_URL=https://面板域名',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    ),
  );
}
