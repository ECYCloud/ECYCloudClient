import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ecycloud_client/core/logger.dart';
import 'package:ecycloud_client/data/api/api_exception.dart';
import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:ecycloud_client/data/models/account.dart';
import 'package:ecycloud_client/data/models/user_profile.dart';
import 'package:ecycloud_client/data/store/credential_store.dart';
import 'package:ecycloud_client/data/store/panel_response_cache.dart';
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/main.dart';
import 'package:ecycloud_client/l10n/app_language.dart';
import 'package:ecycloud_client/l10n/l10n.dart';
import 'package:ecycloud_client/state/announcement_controller.dart';
import 'package:ecycloud_client/state/auth_controller.dart';
import 'package:ecycloud_client/state/connection_controller.dart';
import 'package:ecycloud_client/state/update_controller.dart';
import 'package:ecycloud_client/ui/app_scope.dart';
import 'package:ecycloud_client/ui/pages/account_status_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('账号刷新丢弃旧语言资料并重取当前语言，缓存保持一致', () async {
    final language = L10n.current;
    addTearDown(() => L10n.current = language);
    L10n.current = AppLanguage.en;
    final client = _SessionClient(101)..profileRequests = [];
    final cache = _SessionCache();
    final auth = AuthController(
      _SessionPlatform(),
      _SessionCredentials(),
      clearLocalSession: () async {},
      cache: cache,
      createClient: (_, _, _) => client,
    );
    addTearDown(auth.dispose);
    await auth.login(email: '101@example.test', password: 'test');
    final pending = auth.refreshProfile();
    expect(client.profileRequests, hasLength(1));
    L10n.current = AppLanguage.zhTW;
    client.profileRequests![0].complete(
      UserProfile.fromJson({
        ...client.profile.toJson(),
        'plan': {'id': 7, 'name': 'Fixture plan'},
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(client.profileRequests, hasLength(2));
    expect(auth.profile?.plan, isNull);
    client.profileRequests![1].complete(
      UserProfile.fromJson({
        ...client.profile.toJson(),
        'plan': {'id': 7, 'name': '測試方案'},
      }),
    );
    await pending;
    expect(auth.profile?.plan?.name, '測試方案');
    expect(cache.last?.plan?.name, '測試方案');
  });

  test('旧账户出口地址刷新失败不能重新写入已清理的日志', () async {
    final first = _SessionClient(101);
    final second = _SessionClient(202);
    final clients = [first, second];
    final auth = AuthController(
      _SessionPlatform(),
      _SessionCredentials(),
      clearLocalSession: () async => Logger.instance.clearSession(),
      cache: _SessionCache(),
      createClient: (_, _, _) => clients.removeAt(0),
    );
    addTearDown(auth.dispose);
    final level = Logger.instance.level;
    Logger.instance.level = LogLevel.debug;
    addTearDown(() => Logger.instance.level = level);
    expect(
      await auth.login(email: '101@example.test', password: 'test'),
      isTrue,
    );
    final pending = auth.refreshPanelClientAddress();
    await auth.logout();
    expect(
      await auth.login(email: '202@example.test', password: 'test'),
      isTrue,
    );
    first.pendingRevision.completeError(
      ApiException('private-old.example.test'),
    );
    await pending;
    expect(
      Logger.instance.entries.where(
        (entry) => entry.message.contains('private-old.example.test'),
      ),
      isEmpty,
    );
  });

  test('取消记住必须等待旧密码写入后再删除', () async {
    final platform = _SessionPlatform();
    final protected = Completer<String>();
    platform.pendingProtection = protected;
    final credentials = _SessionCredentials();
    final auth = AuthController(
      platform,
      credentials,
      clearLocalSession: () async {},
    );
    addTearDown(auth.dispose);
    final save = auth.saveRememberedLogin(
      email: 'a@example.test',
      password: 'password-a',
    );
    await platform.protectionStarted.future;
    final clear = auth.clearRememberedLogin();
    protected.complete('protected-a');
    await Future.wait([save, clear]);
    expect(platform.storedSecret, isNull);
    expect(credentials.remembered, isNull);
  });

  test('取消记住后返回的旧密码解密结果不再填回表单', () async {
    final platform = _SessionPlatform();
    platform.pendingReveal = Completer<String>();
    final credentials = _SessionCredentials()
      ..remembered = const RememberedLogin(
        email: 'a@example.test',
        password: 'ecy1:protected-a',
      );
    final auth = AuthController(
      platform,
      credentials,
      clearLocalSession: () async {},
    );
    addTearDown(auth.dispose);
    final load = auth.loadRememberedLogin();
    await auth.clearRememberedLogin();
    platform.pendingReveal!.complete('password-a');
    expect(await load, isNull);
  });

  test('系统密码删除失败必须报告失败且保留可重试记录', () async {
    final platform = _SessionPlatform()..deleteFails = true;
    final credentials = _SessionCredentials()
      ..remembered = const RememberedLogin(
        email: 'a@example.test',
        password: 'ecy1:protected-a',
      );
    final auth = AuthController(
      platform,
      credentials,
      clearLocalSession: () async {},
    );
    addTearDown(auth.dispose);
    await expectLater(auth.clearRememberedLogin(), throwsA(isA<StateError>()));
    expect(credentials.remembered, isNotNull);
  });

  test('本地清理失败时不发送登录请求并保留中断标记', () async {
    final _SessionCredentials credentials = _SessionCredentials();
    int clients = 0;
    final AuthController auth = AuthController(
      _SessionPlatform(),
      credentials,
      clearLocalSession: () async => throw StateError('旧内核未退出'),
      createClient: (_, _, _) {
        clients++;
        return _SessionClient(101);
      },
    );
    addTearDown(auth.dispose);
    expect(
      await auth.login(email: 'new@example.test', password: 'test'),
      isFalse,
    );
    expect(clients, 0);
    expect(credentials.sessionCleanupPending, isTrue);
    expect(auth.api, isNull);
    expect(auth.busy, isFalse);
  });

  test('清理完成前阻止并发登录，成功后才认证', () async {
    final Completer<void> cleanup = Completer<void>();
    final Completer<void> started = Completer<void>();
    final _SessionCredentials credentials = _SessionCredentials();
    int clients = 0;
    final AuthController auth = AuthController(
      _SessionPlatform(),
      credentials,
      cache: _SessionCache(),
      clearLocalSession: () {
        started.complete();
        return cleanup.future;
      },
      createClient: (_, _, _) {
        clients++;
        return _SessionClient(101);
      },
    );
    addTearDown(auth.dispose);
    final Future<bool> login = auth.login(
      email: '101@example.test',
      password: 'test',
    );
    await started.future;
    expect(clients, 0);
    expect(
      await auth.login(email: '202@example.test', password: 'test'),
      isFalse,
    );
    cleanup.complete();
    expect(await login, isTrue);
    expect(clients, 1);
    expect(credentials.sessionCleanupPending, isFalse);
    expect(auth.profile?.id, 101);
  });

  test('登录等待清理时登出共用同一清理任务并取消认证', () async {
    final Completer<void> cleanup = Completer<void>();
    final Completer<void> started = Completer<void>();
    int clears = 0;
    int clients = 0;
    final AuthController auth = AuthController(
      _SessionPlatform(),
      _SessionCredentials(),
      clearLocalSession: () {
        clears++;
        started.complete();
        return cleanup.future;
      },
      createClient: (_, _, _) {
        clients++;
        return _SessionClient(101);
      },
    );
    addTearDown(auth.dispose);
    final Future<bool> login = auth.login(
      email: '101@example.test',
      password: 'test',
    );
    await started.future;
    final Future<void> logout = auth.logout();
    cleanup.complete();
    await logout;
    expect(await login, isFalse);
    expect(clears, 1);
    expect(clients, 0);
    expect(auth.stage, AuthStage.loggedOut);
  });

  test('启动遇到中断标记必须清理，不能恢复旧令牌', () async {
    final _SessionCredentials credentials = _SessionCredentials()
      ..pending = true
      ..saved = Credentials(
        token: 'old',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        email: 'old@example.test',
      );
    int clears = 0;
    int clients = 0;
    final AuthController auth = AuthController(
      _SessionPlatform(),
      credentials,
      clearLocalSession: () async {
        clears++;
      },
      createClient: (_, _, _) {
        clients++;
        return _SessionClient(101);
      },
    );
    addTearDown(auth.dispose);
    await auth.restore();
    expect(clears, 1);
    expect(clients, 0);
    expect(credentials.saved, isNull);
    expect(credentials.pending, isFalse);
    expect(auth.stage, AuthStage.loggedOut);
  });

  for (final bool cached in <bool>[true, false]) {
    testWidgets('启动慢响应时先凭本机登录进入主界面${cached ? '有缓存' : '无缓存'}', (tester) async {
      final client = _SessionClient(101)
        ..pendingStatus = Completer<AccountStatus>();
      final credentials = _SessionCredentials()
        ..saved = Credentials(
          token: 'ecy1:test-token-101',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
          email: '101@example.test',
        );
      final cache = _SessionCache()..last = cached ? client.profile : null;
      final auth = AuthController(
        _SessionPlatform(),
        credentials,
        clearLocalSession: () async {},
        cache: cache,
        createClient: (_, _, _) => client,
      );
      addTearDown(auth.dispose);
      bool restored = false;
      final pending = auth.restore().then((_) => restored = true);
      try {
        await tester.pump();
        expect(auth.stage, AuthStage.loggedIn);
        expect(auth.profile?.id, cached ? 101 : isNull);
        await tester.pump(const Duration(seconds: 5));
        expect(restored, isFalse);
        expect(auth.stage, AuthStage.loggedIn);
        expect(credentials.saved, isNotNull);
        client.pendingStatus!.complete(
          AccountStatus.fromJson(<String, dynamic>{'enable': 1}),
        );
        client.pendingProfile.complete(client.profile);
        await pending;
        expect(restored, isTrue);
        expect(auth.stage, AuthStage.loggedIn);
        expect(auth.profile?.id, 101);
        expect(client.loggedOut, isFalse);
      } finally {
        if (!client.pendingStatus!.isCompleted) {
          client.pendingStatus!.complete(
            AccountStatus.fromJson(<String, dynamic>{'enable': 1}),
          );
        }
        if (!client.pendingProfile.isCompleted) {
          client.pendingProfile.complete(client.profile);
        }
        await pending;
        await auth.logout();
        await tester.pump(const Duration(seconds: 6));
      }
    });
  }

  for (final int enable in <int>[1, 0, -1]) {
    testWidgets('启动先进入主界面并随后遵守账户状态 $enable', (tester) async {
      final client = _SessionClient(101)
        ..pendingStatus = Completer<AccountStatus>();
      final credentials = _SessionCredentials()
        ..saved = Credentials(
          token: 'ecy1:test-token-101',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
          email: '101@example.test',
        );
      final auth = AuthController(
        _SessionPlatform(),
        credentials,
        clearLocalSession: () async {},
        cache: _SessionCache()..last = client.profile,
        createClient: (_, _, _) => client,
      );
      addTearDown(auth.dispose);
      final pending = auth.restore();
      await tester.pump();
      expect(auth.stage, AuthStage.loggedIn);
      expect(auth.profile?.id, 101);
      client.pendingStatus!.complete(
        AccountStatus.fromJson(<String, dynamic>{'enable': enable}),
      );
      await tester.pump();
      expect(
        auth.stage,
        enable == 1 ? AuthStage.loggedIn : AuthStage.accountRestricted,
      );
      expect(auth.accountStatus?.enable, enable == 1 ? isNull : enable);
      client.pendingProfile.complete(client.profile);
      await pending;
    });
  }

  testWidgets('启动时令牌失效必须清理，不能恢复缓存', (tester) async {
    final client = _SessionClient(101)
      ..pendingStatus = Completer<AccountStatus>();
    final credentials = _SessionCredentials()
      ..saved = Credentials(
        token: 'ecy1:test-token-101',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        email: '101@example.test',
      );
    final auth = AuthController(
      _SessionPlatform(),
      credentials,
      clearLocalSession: () async {},
      cache: _SessionCache()..last = client.profile,
      createClient: (_, _, _) => client,
    );
    addTearDown(auth.dispose);
    final pending = auth.restore();
    await tester.pump();
    client.pendingStatus!.completeError(
      ApiException('expired', statusCode: 401),
    );
    await pending;
    expect(auth.stage, AuthStage.loggedOut);
    expect(auth.profile, isNull);
    expect(credentials.saved, isNull);
    expect(client.loggedOut, isTrue);
  });

  for (final bool unauthorized in <bool>[false, true]) {
    testWidgets('启动恢复中的旧账户${unauthorized ? '失效响应' : '受限状态'}不能影响新账户', (
      tester,
    ) async {
      final first = _SessionClient(101)
        ..pendingStatus = Completer<AccountStatus>();
      final second = _SessionClient(202);
      second.pendingProfile.complete(second.profile);
      final clients = <_SessionClient>[first, second];
      final credentials = _SessionCredentials()
        ..saved = Credentials(
          token: 'ecy1:test-token-101',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
          email: '101@example.test',
        );
      final auth = AuthController(
        _SessionPlatform(),
        credentials,
        clearLocalSession: () async {},
        cache: _SessionCache()..last = first.profile,
        createClient: (_, _, _) => clients.removeAt(0),
      );
      addTearDown(auth.dispose);
      final pending = auth.restore();
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await auth.logout();
      expect(
        await auth.login(email: '202@example.test', password: 'test'),
        isTrue,
      );
      if (unauthorized) {
        first.pendingStatus!.completeError(
          ApiException('expired', statusCode: 401),
        );
      } else {
        first.pendingStatus!.complete(
          AccountStatus.fromJson(<String, dynamic>{'enable': 0}),
        );
      }
      await pending;
      await tester.pump(const Duration(seconds: 6));
      expect(auth.stage, AuthStage.loggedIn);
      expect(auth.accountStatus, isNull);
      expect(auth.profile?.id, 202);
      expect(auth.api, same(second));
      expect(second.loggedOut, isFalse);
    });
  }

  for (final int? status in <int?>[null, 403, 429, 503]) {
    testWidgets('启动暂时失败 $status 无缓存也保持登录并稍后重试', (tester) async {
      final client = _SessionClient(101)
        ..pendingStatus = Completer<AccountStatus>();
      final clients = <_SessionClient>[client];
      final credentials = _SessionCredentials()
        ..saved = Credentials(
          token: 'ecy1:test-token-101',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
          email: '101@example.test',
        );
      int clears = 0;
      final auth = AuthController(
        _SessionPlatform(),
        credentials,
        clearLocalSession: () async => clears++,
        cache: _SessionCache(),
        createClient: (_, _, _) => clients.removeAt(0),
      );
      addTearDown(auth.dispose);
      final pending = auth.restore();
      await tester.pump();
      await auth.restore();
      expect(clients, isEmpty);
      expect(auth.stage, AuthStage.loggedIn);
      client.pendingStatus!.completeError(
        ApiException('temporary', statusCode: status),
      );
      await pending;
      expect(auth.stage, AuthStage.loggedIn);
      expect(auth.busy, isFalse);
      expect(auth.error, isNull);
      expect(auth.api, same(client));
      expect(auth.profile, isNull);
      expect(credentials.saved, isNotNull);
      expect(client.loggedOut, isFalse);
      expect(client.closed, isFalse);
      expect(clears, 0);
      client.pendingProfile.complete(client.profile);
      await tester.pump(const Duration(seconds: 7));
      // 只有 transient（连不上、429、5xx）安排补拉；其余由主界面定时刷新接手
      expect(auth.profile?.id, status == 429 || status == 503 ? 101 : isNull);
      expect(auth.stage, AuthStage.loggedIn);
      expect(clears, 0);
    });
  }

  test('启动平台信息读取失败不再留下无反馈加载状态', () async {
    final credentials = _SessionCredentials()
      ..saved = Credentials(
        token: 'ecy1:test-token-101',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        email: '101@example.test',
      );
    final auth = AuthController(
      _SessionPlatform()..deviceError = StateError('读取失败'),
      credentials,
      clearLocalSession: () async {},
      cache: _SessionCache(),
      createClient: (_, _, _) => throw StateError('不应创建请求'),
    );
    addTearDown(auth.dispose);
    await auth.restore();
    expect(auth.stage, AuthStage.unknown);
    expect(auth.error, isNotEmpty);
    expect(auth.busy, isFalse);
    expect(credentials.saved, isNotNull);
  });

  for (final int status in <int>[403, 503]) {
    testWidgets('账户状态已验证时资料请求失败 $status 不撤销登录', (tester) async {
      final client = _SessionClient(101)
        ..pendingStatus = Completer<AccountStatus>();
      final credentials = _SessionCredentials()
        ..saved = Credentials(
          token: 'ecy1:test-token-101',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
          email: '101@example.test',
        );
      final auth = AuthController(
        _SessionPlatform(),
        credentials,
        clearLocalSession: () async {},
        cache: _SessionCache(),
        createClient: (_, _, _) => client,
      );
      addTearDown(auth.dispose);
      final pending = auth.restore();
      await tester.pump();
      client.pendingStatus!.complete(
        AccountStatus.fromJson(<String, dynamic>{'enable': 1}),
      );
      await tester.pump();
      client.pendingProfile.completeError(
        ApiException('request rejected', statusCode: status),
      );
      await pending;
      expect(auth.stage, AuthStage.loggedIn);
      expect(auth.api, same(client));
      expect(auth.busy, isFalse);
      expect(credentials.saved, isNotNull);
      expect(client.loggedOut, isFalse);
      await auth.logout();
      await tester.pump(const Duration(seconds: 6));
    });
  }

  for (final ThemeMode theme in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    for (final bool narrow in <bool>[false, true]) {
      testWidgets('启动不经恢复页直接按账户状态显示 $theme 窄窗=$narrow', (tester) async {
        final language = L10n.current;
        addTearDown(() => L10n.current = language);
        tester.view.physicalSize = narrow
            ? const Size(390, 844)
            : const Size(1100, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final first = _SessionClient(101)
          ..pendingStatus = (Completer<AccountStatus>()
            ..complete(AccountStatus.fromJson(<String, dynamic>{'enable': 0})));
        final clients = <_SessionClient>[first];
        final credentials = _SessionCredentials()
          ..saved = Credentials(
            token: 'ecy1:test-token-101',
            expiresAt: DateTime.now().add(const Duration(hours: 1)),
            email: '101@example.test',
          );
        final platform = _SessionPlatform();
        final auth = AuthController(
          platform,
          credentials,
          clearLocalSession: () async {},
          cache: _SessionCache(),
          createClient: (_, _, _) => clients.removeAt(0),
        );
        final connection = _StartupConnection(theme);
        final announcements = _StartupAnnouncements();
        final update = _StartupUpdate();
        addTearDown(() {
          auth.dispose();
          connection.dispose();
          announcements.dispose();
          update.dispose();
        });
        await tester.pumpWidget(
          AppScope(
            auth: auth,
            connection: connection,
            announcements: announcements,
            update: update,
            platform: platform,
            settingsStore: SettingsStore(),
            child: const EcyCloudApp(),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(find.text('正在恢复登录…'), findsNothing);
        expect(find.text('暂时无法恢复登录，请稍后重试。'), findsNothing);
        expect(credentials.saved, isNotNull);
        expect(auth.stage, AuthStage.accountRestricted);
        expect(find.byType(AccountStatusPage), findsOneWidget);
        expect(connection.attached, isNull, reason: '受限账号不能向连接控制器提供 API');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  test('系统凭据删除失败不能完成账户交接', () async {
    final _SessionCredentials credentials = _SessionCredentials();
    final AuthController auth = AuthController(
      _SessionPlatform()..deleteFails = true,
      credentials,
      clearLocalSession: () async {},
      createClient: (_, _, _) => _SessionClient(101),
    );
    addTearDown(auth.dispose);
    await expectLater(auth.logout(), throwsA(isA<ApiException>()));
    expect(credentials.pending, isTrue);
    expect(auth.busy, isFalse);
    expect(auth.error, isNotEmpty);
  });

  for (final bool unauthorized in <bool>[false, true]) {
    test('旧账户延迟${unauthorized ? '鉴权失败' : '资料响应'}不能影响新账户', () async {
      final _SessionClient first = _SessionClient(101);
      final _SessionClient second = _SessionClient(202);
      final List<_SessionClient> clients = <_SessionClient>[first, second];
      final _SessionCache cache = _SessionCache();
      final AuthController auth = AuthController(
        _SessionPlatform(),
        _SessionCredentials(),
        clearLocalSession: () async {},
        cache: cache,
        createClient: (_, _, _) => clients.removeAt(0),
      );
      addTearDown(auth.dispose);

      expect(
        await auth.login(email: '101@example.test', password: 'test'),
        isTrue,
      );
      final Future<void> pending = auth.refreshProfile();
      await auth.logout();
      expect(
        await auth.login(email: '202@example.test', password: 'test'),
        isTrue,
      );
      if (unauthorized) {
        first.pendingProfile.completeError(
          ApiException('expired', statusCode: 401),
        );
      } else {
        first.pendingProfile.complete(first.profile);
      }
      await pending;

      expect(auth.stage, AuthStage.loggedIn);
      expect(auth.profile?.id, 202);
      expect(auth.api, same(second));
      expect(cache.last?.id, 202);
      expect(second.loggedOut, isFalse);
    });
  }

  test('退出后返回的凭据加密结果不能重新保存会话', () async {
    final _SessionPlatform platform = _SessionPlatform();
    final _SessionCredentials credentials = _SessionCredentials();
    final Completer<String> protected = Completer<String>();
    platform.pendingProtection = protected;
    final AuthController auth = AuthController(
      platform,
      credentials,
      clearLocalSession: () async {},
      cache: _SessionCache(),
      createClient: (_, _, _) => _SessionClient(101),
    );
    addTearDown(auth.dispose);

    final Future<bool> pending = auth.login(
      email: '101@example.test',
      password: 'test',
    );
    await platform.protectionStarted.future;
    bool loggedOut = false;
    final Future<void> logout = auth.logout().then((_) => loggedOut = true);
    await Future<void>.delayed(Duration.zero);
    final bool finishedBeforeProtection = loggedOut;
    protected.complete('test-token-101');
    await logout;

    expect(await pending, isFalse);
    expect(credentials.saved, isNull);
    expect(auth.api, isNull);
    expect(auth.stage, AuthStage.loggedOut);
    expect(platform.storedSecret, isNull);
    expect(finishedBeforeProtection, isFalse);
  });

  test('429 必须带 statusCode，供 restore 区分限流与鉴权失败', () {
    final ApiException limited = ApiException(
      '请求过于频繁，请稍后再试',
      statusCode: 429,
      retryAfterSeconds: 12,
    );
    expect(limited.statusCode, 429);
    expect(limited.rateLimited, isTrue);
    expect(limited.unauthorized, isFalse);
    expect(limited.retryAfterSeconds, 12);

    final ApiException expired = ApiException('登录已失效', statusCode: 401, ret: 0);
    expect(expired.unauthorized, isTrue);
    expect(expired.rateLimited, isFalse);
  });

  test('鉴权失败与限流不得混用同一处理分支', () {
    const List<int> statuses = <int>[401, 429];
    final Map<int, bool> keepSession = <int, bool>{
      for (final int code in statuses)
        code: !ApiException('x', statusCode: code).unauthorized,
    };
    expect(keepSession[401], isFalse);
    expect(keepSession[429], isTrue);
  });
}

class _SessionClient extends PanelApiClient {
  _SessionClient(this.userId)
    : super(
        baseUrl: 'https://panel.example.test',
        configBaseUrl: 'https://panel.example.test',
        device: const DeviceInfo(
          platform: 'windows',
          deviceId: 'audit',
          deviceName: 'audit',
          deviceModel: 'audit',
          osVersion: 'test',
          appVersion: 'test',
        ),
      );

  final int userId;
  Completer<AccountStatus>? pendingStatus;
  final Completer<UserProfile> pendingProfile = Completer<UserProfile>();
  List<Completer<UserProfile>>? profileRequests;
  final Completer<String> pendingRevision = Completer<String>();
  bool loggedOut = false;
  bool closed = false;

  UserProfile get profile => UserProfile.fromJson(<String, dynamic>{
    'id': userId,
    'email': '$userId@example.test',
    'user_name': '测试账户',
    'class': 1,
    'upload': 0,
    'download': 0,
    'transfer_enable': 100,
    'config_revision': 'revision-$userId',
  });

  @override
  Future<LoginResult> login({
    required String email,
    required String password,
    String? twoFactorCode,
  }) async {
    token = 'test-token-$userId';
    return LoginResult(
      token!,
      DateTime.now().add(const Duration(hours: 1)),
      profile: profile,
    );
  }

  @override
  Future<AccountStatus> fetchAccountStatus() => pendingStatus!.future;

  @override
  Future<UserProfile> fetchProfile() {
    if (profileRequests == null) return pendingProfile.future;
    final request = Completer<UserProfile>();
    profileRequests!.add(request);
    return request.future;
  }

  @override
  Future<String> fetchConfigRevision({int? fallbackProxyPort}) =>
      pendingRevision.future;

  @override
  Future<void> logout() async {
    loggedOut = true;
    token = null;
  }

  @override
  void close() => closed = true;
}

class _SessionCredentials extends CredentialStore {
  RememberedLogin? remembered;
  @override
  RememberedLogin? loadRemembered() => remembered;
  @override
  void saveRemembered({required String email, required String password}) {
    remembered = RememberedLogin(email: email, password: password);
  }

  @override
  void clearRemembered() => remembered = null;
  Credentials? saved;
  bool pending = false;
  @override
  bool get sessionCleanupPending => pending;
  @override
  void beginSessionCleanup() => pending = true;
  @override
  void finishSessionCleanup() => pending = false;
  @override
  String? loadApiOrigin() => 'https://panel.example.test';
  @override
  String? loadSiteOrigin() => 'https://panel.example.test';
  @override
  String deviceId() => 'audit';
  @override
  Credentials? load() => saved;
  @override
  void save(Credentials credentials) {
    saved = credentials;
  }

  @override
  void clear() {
    saved = null;
  }
}

class _SessionCache extends PanelResponseCache {
  UserProfile? last;
  @override
  UserProfile? loadProfile(String accountKey) =>
      last?.email.toLowerCase() == accountKey.toLowerCase() ? last : null;
  @override
  void saveProfile(String accountKey, UserProfile profile) {
    last = profile;
  }
}

class _SessionPlatform implements PlatformService {
  Object? deviceError;
  Completer<String>? pendingReveal;
  @override
  Future<String?> unprotectSecret(String name, String protected) async =>
      pendingReveal == null ? protected : await pendingReveal!.future;
  bool deleteFails = false;
  String? storedSecret;
  Completer<String>? pendingProtection;
  final Completer<void> protectionStarted = Completer<void>();
  @override
  String get platformId => 'windows';
  @override
  bool get isTelevision => false;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> setWindowDark({
    required bool dark,
    int caption = 0,
    int text = 0,
  }) async {}
  @override
  Future<String> deviceName() async => 'audit';
  @override
  Future<({String model, String os})> deviceProfile() async {
    if (deviceError != null) throw deviceError!;
    return (model: 'audit', os: 'test');
  }

  @override
  Future<String> protectSecret(String name, String plaintext) async {
    if (!protectionStarted.isCompleted) {
      protectionStarted.complete();
    }
    final String result =
        await (pendingProtection?.future ?? Future<String>.value(plaintext));
    storedSecret = result;
    return result;
  }

  @override
  Future<void> deleteSecret(String name) async {
    if (deleteFails) throw StateError('测试凭据删除失败');
    storedSecret = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StartupConnection extends ChangeNotifier
    implements ConnectionController {
  @override
  Future<void> shutdown({bool clearSession = false}) async {}
  _StartupConnection(ThemeMode theme)
    : settings = const AppSettings.defaults().copyWith(
        locale: AppLanguage.zhCN.code,
        themeMode: theme,
        autoConnect: false,
      );

  @override
  Future<void> Function()? onPanelSync;
  @override
  Future<void> Function()? onSessionRejected;
  PanelApiClient? attached;
  @override
  final AppSettings settings;
  @override
  Future<void> syncPlatformSettings() async {}
  @override
  Future<void> adoptRunningKernel() async {}
  @override
  Future<void> runPreflight() async {}
  @override
  void attachApi(PanelApiClient? api, {String? accountKey}) => attached = api;
  @override
  void attachProfileLookup(UserProfile? Function()? lookup) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StartupAnnouncements extends ChangeNotifier
    implements AnnouncementController {
  @override
  void attachApi(PanelApiClient? api) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StartupUpdate extends ChangeNotifier implements UpdateController {
  @override
  void start() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
