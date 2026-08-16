import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/app_config.dart';
import 'core/app_paths.dart';
import 'core/error_logger.dart';
import 'core/logger.dart';
import 'data/store/credential_store.dart';
import 'data/store/settings_store.dart';
import 'l10n/app_language.dart';
import 'l10n/l10n.dart';
import 'domain/kernel/kernel_controller.dart';
import 'domain/platform/platform_service.dart';
import 'platform/platform_factory.dart';
import 'state/announcement_controller.dart';
import 'state/auth_controller.dart';
import 'state/connection_controller.dart';
import 'state/update_controller.dart';
import 'ui/app_scope.dart';
import 'ui/node_labels.dart';
import 'ui/pages/account_status_page.dart';
import 'ui/pages/language_setup_page.dart';
import 'ui/pages/login_page.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';
import 'ui/widgets/zoom_cursors.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppPaths.bootstrap();
  await ZoomCursors.ensureReady();
  ErrorLogger.init();

  if (!AppConfig.configured) {
    runApp(const _MisconfiguredApp());
    return;
  }

  final SettingsStore settingsStore = SettingsStore();
  final AppSettings seeded = AppLanguage.seed(
    settingsStore,
    settingsStore.load(),
  );
  L10n.current = AppLanguage.resolve(stored: seeded.locale);
  Logger.instance.level = seeded.logLevel;
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
  final AnnouncementController announcements = AnnouncementController();
  final UpdateController update = UpdateController(
    connection: connection,
    platform: platform,
  );

  runApp(
    AppScope(
      auth: auth,
      connection: connection,
      announcements: announcements,
      update: update,
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
  ThemeMode _themeMode = ThemeMode.system;
  Locale _locale = L10n.current.flutterLocale;
  AuthController? _auth;
  ConnectionController? _connection;
  AnnouncementController? _announcements;
  UpdateController? _update;
  PlatformService? _platform;
  AuthStage _authStage = AuthStage.unknown;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_bootstrapped) {
      _bootstrapped = true;
      final AppScope scope = AppScope.of(context);
      _auth = scope.auth;
      _connection = scope.connection;
      _announcements = scope.announcements;
      _update = scope.update;
      _platform = scope.platform;
      _themeMode = scope.connection.settings.themeMode;
      L10n.current = AppLanguage.resolve(
        stored: scope.connection.settings.locale,
      );
      _locale = L10n.current.flutterLocale;
      unawaited(_bootstrap());
    }
  }

  @override
  void dispose() {
    _auth?.removeListener(_onAuthChanged);
    _connection?.removeListener(_onConnectionChanged);
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final AuthController auth = _auth!;
    final ConnectionController connection = _connection!;
    final UpdateController update = _update!;
    final PlatformService platform = _platform!;

    auth.addListener(_onAuthChanged);
    // 流量轮询也会 notify connection：绝不能因此整棵重建 MaterialApp，否则偶发白屏
    connection.addListener(_onConnectionChanged);
    auth.onConfigRevision = connection.notePanelRevision;

    try {
      await platform.initialize();
      await connection.syncPlatformSettings();
    } on Object catch (e) {
      Logger.instance.error('app', '平台初始化失败', e);
    }

    // 预检只是给设置页攒一份问题清单，慢的话不该一直挡着启动图
    unawaited(connection.runPreflight());
    // 界面可能是被系统重建的，隧道还在后台跑着，要在拉起常驻内核之前认回来
    await connection.adoptRunningKernel();
    await auth.restore();

    update.start();
  }

  void _onConnectionChanged() {
    final ConnectionController? connection = _connection;
    if (!mounted || connection == null) {
      return;
    }
    // 监听回调不用 AppScope.of：of 走 dependOnInherited，应在 build /
    // didChangeDependencies 里取好引用（见 Flutter BuildContext 文档）。
    final ThemeMode next = connection.settings.themeMode;
    final AppLanguage language = AppLanguage.resolve(
      stored: connection.settings.locale,
    );
    final Locale nextLocale = language.flutterLocale;
    if (next == _themeMode && nextLocale == _locale) {
      return;
    }
    L10n.current = language;
    setState(() {
      _themeMode = next;
      _locale = nextLocale;
    });
  }

  void _onAuthChanged() {
    final AuthController? auth = _auth;
    final ConnectionController? connection = _connection;
    final AnnouncementController? announcements = _announcements;
    if (!mounted ||
        auth == null ||
        connection == null ||
        announcements == null) {
      return;
    }
    final AuthStage previous = _authStage;
    final bool leftRestricted = auth.stage == AuthStage.loggedIn &&
        previous == AuthStage.accountRestricted;
    _authStage = auth.stage;

    connection.attachApi(auth.api, accountKey: auth.accountKey);
    connection.attachProfileLookup(() => auth.profile);
    announcements.attachApi(auth.api);

    // attachApi 仅在 API 实例变化时 preload；受限恢复仍是同一实例
    if (leftRestricted) {
      unawaited(connection.preloadProxies());
    }

    if (auth.stage == AuthStage.loggedIn &&
        previous != AuthStage.loggedIn &&
        connection.settings.autoConnect &&
        connection.state == ConnectionPhase.disconnected &&
        !connection.busy) {
      unawaited(connection.connect());
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppScope scope = AppScope.of(context);

    return MaterialApp(
      title: 'ECY Cloud',
      debugShowCheckedModeBanner: false,
      locale: _locale,
      supportedLocales: const <Locale>[
        Locale('zh', 'CN'),
        Locale('zh', 'TW'),
        Locale('en'),
      ],
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _themeMode,
      home: scope.connection.settings.locale.isEmpty
          ? LanguageSetupPage(
              initial: AppLanguage.resolve(stored: ''),
              onChosen: (AppLanguage language) {
                L10n.current = language;
                unawaited(
                  scope.connection.updateSettings(
                    scope.connection.settings.copyWith(locale: language.code),
                  ),
                );
              },
            )
          : ListenableBuilder(
              listenable: scope.auth,
              builder: (BuildContext context, _) => switch (scope.auth.stage) {
                AuthStage.unknown => const _Splash(),
                AuthStage.loggedIn => const Shell(),
                AuthStage.accountRestricted => const AccountStatusPage(),
                _ => const LoginPage(),
              },
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
    title: 'ECY Cloud',
    debugShowCheckedModeBanner: false,
    darkTheme: AppTheme.dark(),
    theme: AppTheme.light(),
    home: const Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            '构建缺少站点域名或订阅域名。\n'
            '请用 scripts/ 下对应平台的出包脚本构建，或调试时带上\n'
            '--dart-define=ECYCLOUD_SITE_URL=https://站点域名\n'
            '--dart-define=ECYCLOUD_SUB_URL=https://订阅域名',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    ),
  );
}
