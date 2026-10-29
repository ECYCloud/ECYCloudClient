import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:ecycloud_client/data/api/api_exception.dart';
import 'package:ecycloud_client/data/models/account.dart';
import 'package:ecycloud_client/data/models/user_profile.dart';
import 'package:ecycloud_client/data/store/credential_store.dart';
import 'package:ecycloud_client/data/store/panel_response_cache.dart';
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/state/announcement_controller.dart';
import 'package:ecycloud_client/state/auth_controller.dart';
import 'package:ecycloud_client/state/connection_controller.dart';
import 'package:ecycloud_client/state/update_controller.dart';
import 'package:ecycloud_client/ui/app_scope.dart';
import 'package:ecycloud_client/ui/pages/edit_account_page.dart';
import 'package:ecycloud_client/ui/pages/reset_password_page.dart';
import 'package:ecycloud_client/ui/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('改密提示等待期间，后台发现旧令牌失效也必须等待确认后退出', () async {
    final _PasswordSessionClient api = _PasswordSessionClient(1);
    final AuthController auth = AuthController(
      _Platform(),
      _Credentials(),
      clearLocalSession: () async {},
      cache: _Cache(),
      createClient: (_, _, _) => api,
    );
    addTearDown(auth.dispose);
    await auth.login(email: 'restricted@example.test', password: 'test');
    final Completer<void> acknowledgement = Completer<void>();
    final Future<void> logout = auth.logout(
      beforeLogout: () => acknowledgement.future,
    );
    api.revoked = true;
    bool backgroundFinished = false;
    final Future<void> background = auth.refreshProfile().then(
      (_) => backgroundFinished = true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(auth.stage, AuthStage.loggedIn);
    expect(auth.api, same(api));
    expect(api.logoutCalls, 0);
    expect(backgroundFinished, isFalse);
    acknowledgement.complete();
    await Future.wait(<Future<void>>[logout, background]);
    expect(auth.stage, AuthStage.loggedOut);
    expect(auth.api, isNull);
    expect(api.logoutCalls, 1);
  });

  for (final int enable in <int>[1, 0, -1]) {
    test('重置密码等待成功提示关闭后才签入本机会话，保留账户限制：$enable', () async {
      final _PasswordSessionClient api = _PasswordSessionClient(enable);
      final _Credentials credentials = _Credentials();
      final AuthController auth = AuthController(
        _Platform(),
        credentials,
        clearLocalSession: () async {},
        cache: _Cache(),
        createClient: (_, _, _) => api,
      );
      addTearDown(auth.dispose);
      final Completer<void> shown = Completer<void>();
      final Completer<void> acknowledgement = Completer<void>();
      final Future<bool> pending = auth.confirmPasswordReset(
        email: 'restricted@example.test',
        token: 'fixture-reset',
        password: 'test-password',
        repasswd: 'test-password',
        onSuccess: (String message) {
          expect(message, _PasswordClient.message);
          shown.complete();
          return acknowledgement.future;
        },
      );
      await shown.future;
      expect(auth.busy, isTrue);
      expect(auth.api, isNull);
      expect(credentials.load(), isNull);
      expect(auth.stage, AuthStage.loggedOut);
      acknowledgement.complete();
      expect(await pending, isTrue);
      expect(
        auth.stage,
        enable == 1 ? AuthStage.loggedIn : AuthStage.accountRestricted,
      );
      auth.enterShell();
      expect(
        auth.stage,
        enable == 1 ? AuthStage.loggedIn : AuthStage.accountRestricted,
      );
    });
  }

  for (final (double width, bool dark) in <(double, bool)>[
    (390, false),
    (1000, true),
  ]) {
    testWidgets('改密成功弹窗持续展示且只有确认后退出：$width/$dark', (WidgetTester tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final _Auth auth = _Auth(_PasswordClient());
      addTearDown(auth.dispose);
      await tester.pumpWidget(
        AppScope(
          auth: auth,
          connection: _Connection(),
          announcements: _Announcements(),
          update: _Update(),
          platform: _Platform(),
          settingsStore: _Settings(),
          child: MaterialApp(
            theme: dark ? AppTheme.dark() : AppTheme.light(),
            home: const EditAccountPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Finder button = find.widgetWithText(FilledButton, '修改密码');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text(_PasswordClient.message), findsOneWidget);
      await tester.pump(const Duration(minutes: 2));
      await tester.tapAt(const Offset(5, 5));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text(_PasswordClient.message), findsOneWidget);
      expect(auth.logoutCalls, 0);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('我知道了'));
      await tester.pumpAndSettle();
      expect(auth.logoutCalls, 1);
      expect(find.text(_PasswordClient.message), findsNothing);
    });
  }

  testWidgets('找回密码成功提示关闭前不进入主界面', (WidgetTester tester) async {
    final _Auth auth = _Auth(_PasswordClient());
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      AppScope(
        auth: auth,
        connection: _Connection(),
        announcements: _Announcements(),
        update: _Update(),
        platform: _Platform(),
        settingsStore: _Settings(),
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const ResetPasswordPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'fixture@example.test');
    await tester.tap(find.widgetWithText(FilledButton, '发送重置邮件'));
    await tester.pumpAndSettle();
    final Finder fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'fixture-reset');
    await tester.enterText(fields.at(1), 'test-password');
    await tester.enterText(fields.at(2), 'test-password');
    await tester.tap(find.widgetWithText(FilledButton, '确认重置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(minutes: 2));
    expect(find.text(_PasswordClient.message), findsOneWidget);
    expect(auth.enterCalls, 0);
    await tester.tap(find.text('我知道了'));
    await tester.pumpAndSettle();
    expect(auth.enterCalls, 1);
  });

  for (final (String label, int enable) in <(String, int)>[
    ('封禁', 0),
    ('待删除', -1),
  ]) {
    test('$label账号登录后不得进入主界面', () async {
      final AuthController auth = AuthController(
        _Platform(),
        _Credentials(),
        clearLocalSession: () async {},
        cache: _Cache(),
        createClient: (_, _, _) => _RestrictedClient(enable),
      );
      addTearDown(auth.dispose);

      expect(
        await auth.login(email: 'restricted@example.test', password: 'test'),
        isTrue,
      );
      expect(auth.stage, AuthStage.accountRestricted);

      // 登录页 / 注册页 / 重置密码页在成功后都会调这一下
      auth.enterShell();

      expect(auth.stage, AuthStage.accountRestricted);
      expect(auth.accountStatus?.enable, enable);
    });
  }

  testWidgets('旧账户的改资料响应不得把两步验证密钥写进新会话页面', (WidgetTester tester) async {
    final _EditClient first = _EditClient('OLD-ACCOUNT-TOTP-SECRET');
    final _EditClient second = _EditClient('NEW-ACCOUNT-TOTP-SECRET');
    final _Auth auth = _Auth(first);
    addTearDown(auth.dispose);

    await tester.pumpWidget(
      AppScope(
        auth: auth,
        connection: _Connection(),
        announcements: _Announcements(),
        update: _Update(),
        platform: _Platform(),
        settingsStore: _Settings(),
        child: const MaterialApp(home: EditAccountPage()),
      ),
    );
    await tester.pump();
    await tester.pump();

    // 旧账户的请求在途时切换账户：新客户端就位，旧响应随后才回来
    auth.api = second;
    auth.notifyListeners();
    first.pending.complete(first.options);
    // 页面在加载态会一直转圈，pumpAndSettle 不会停
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('OLD-ACCOUNT-TOTP-SECRET'), findsNothing);
    expect(second.pending.isCompleted, isFalse);
  });

  testWidgets('已开启两步验证时关闭和重置会要求登录密码，且不显示空密钥', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _GaClient api = _GaClient();
    final _Auth auth = _Auth(api);
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      AppScope(
        auth: auth,
        connection: _Connection(),
        announcements: _Announcements(),
        update: _Update(),
        platform: _Platform(),
        settingsStore: _Settings(),
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const EditAccountPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.key), findsNothing);
    expect(find.byIcon(Icons.link), findsNothing);
    expect(find.text('测试'), findsOneWidget);

    await tester.ensureVisible(find.text('重置密钥'));
    await tester.tap(find.text('重置密钥'));
    await tester.pumpAndSettle();
    expect(find.text('请验证登录密码'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'login-password');
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();
    expect(api.gaResetPasswd, 'login-password');
    expect(find.textContaining('NEW-SECRET'), findsOneWidget);

    await tester.ensureVisible(find.text('要求验证'));
    await tester.tap(find.text('要求验证'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不要求'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, '保存').last);
    await tester.tap(find.widgetWithText(FilledButton, '保存').last);
    await tester.pumpAndSettle();
    expect(find.text('请验证登录密码'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'login-password');
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();
    expect(api.gaSetEnable, 0);
    expect(api.gaSetPasswd, 'login-password');
    expect(find.textContaining('RESTORED-SECRET'), findsOneWidget);
  });
}

class _RestrictedClient extends PanelApiClient {
  _RestrictedClient(this.enable)
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

  final int enable;

  UserProfile get profile => UserProfile.fromJson(<String, dynamic>{
    'id': 1,
    'email': 'restricted@example.test',
    'user_name': '受限账户',
    'class': 0,
    'upload': 0,
    'download': 0,
    'transfer_enable': 0,
  });

  @override
  Future<LoginResult> login({
    required String email,
    required String password,
    String? twoFactorCode,
  }) async {
    token = 'test-token';
    return LoginResult(
      token!,
      DateTime.now().add(const Duration(hours: 1)),
      profile: profile,
      accountStatus: AccountStatus.fromJson(<String, dynamic>{
        'enable': enable,
        'email': 'restricted@example.test',
      }),
    );
  }

  @override
  Future<UserProfile> fetchProfile() async => profile;

  @override
  Future<void> logout() async {}

  @override
  void close() {}
}

class _PasswordSessionClient extends _RestrictedClient {
  _PasswordSessionClient(super.enable);
  bool revoked = false;
  int logoutCalls = 0;

  @override
  Future<UserProfile> fetchProfile() async {
    if (revoked) {
      throw ApiException('登录已失效', statusCode: 401);
    }
    return profile;
  }

  @override
  Future<LoginResult> confirmPasswordReset({
    required String token,
    required String password,
    required String repasswd,
  }) async {
    final LoginResult result = await login(
      email: 'restricted@example.test',
      password: password,
    );
    return LoginResult(
      result.token,
      result.expiresAt,
      profile: result.profile,
      accountStatus: result.accountStatus,
      message: _PasswordClient.message,
    );
  }

  @override
  Future<void> logout() async {
    logoutCalls++;
  }
}

class _EditClient extends PanelApiClient {
  _EditClient(this.secret)
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

  final String secret;
  final Completer<EditAccountOptions> pending = Completer<EditAccountOptions>();

  EditAccountOptions get options =>
      EditAccountOptions.fromJson(<String, dynamic>{'ga_token': secret});

  @override
  Future<EditAccountOptions> fetchEditOptions() => pending.future;

  @override
  void close() {}
}

class _GaClient extends PanelApiClient {
  _GaClient()
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

  EditAccountOptions options = EditAccountOptions.fromJson(<String, dynamic>{
    'ga_enable': 1,
  });
  int? gaSetEnable;
  String? gaSetPasswd;
  String? gaResetPasswd;

  @override
  Future<EditAccountOptions> fetchEditOptions() async => options;

  @override
  Future<String> gaSet(int enable, {String? passwd}) async {
    gaSetEnable = enable;
    gaSetPasswd = passwd;
    options = options.copyWith(
      gaEnable: enable,
      gaToken: enable == 0 ? 'RESTORED-SECRET' : '',
      gaUrl: enable == 0 ? 'otpauth://restored' : '',
    );
    return '设置成功';
  }

  @override
  Future<({String message, String gaToken, String gaUrl})> gaReset({
    String? passwd,
  }) async {
    gaResetPasswd = passwd;
    return (
      message: '两步验证密钥已重置',
      gaToken: 'NEW-SECRET',
      gaUrl: 'otpauth://new',
    );
  }

  @override
  void close() {}
}

class _Auth extends ChangeNotifier implements AuthController {
  _Auth(this.api);

  @override
  PanelApiClient? api;
  int logoutCalls = 0;
  int enterCalls = 0;

  @override
  Future<void> logout({Future<void> Function()? beforeLogout}) async {
    await beforeLogout?.call();
    logoutCalls++;
  }

  @override
  Future<bool> requestPasswordReset({required String email}) async => true;

  @override
  Future<bool> confirmPasswordReset({
    required String email,
    required String token,
    required String password,
    required String repasswd,
    Future<void> Function(String)? onSuccess,
  }) async {
    await onSuccess?.call(_PasswordClient.message);
    return true;
  }

  @override
  void enterShell() {
    enterCalls++;
  }

  @override
  Future<AuthOptions?> fetchAuthOptions() async =>
      AuthOptions.fromJson(const <String, dynamic>{});

  @override
  String get siteOrigin => 'https://panel.example.test';

  @override
  String get apiOrigin => 'https://panel.example.test';

  @override
  String? get accountKey => 'new@example.test';

  @override
  AccountStatus? get accountStatus => null;

  @override
  AuthStage get stage => AuthStage.loggedIn;

  @override
  bool get busy => false;

  @override
  String? get error => null;

  @override
  UserProfile? get profile => UserProfile.fromJson(<String, dynamic>{
    'id': 2,
    'email': 'new@example.test',
    'user_name': '新账户',
    'class': 1,
    'upload': 0,
    'download': 0,
    'transfer_enable': 100,
  });

  @override
  Future<void> refreshProfile() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PasswordClient extends _GaClient {
  static const String message =
      '修改成功，订阅链接与节点密码已重置，旧订阅链接与旧节点密码已失效。官方客户端需使用新密码重新登录；第三方客户端需重新导入最新订阅。';

  @override
  Future<String> updatePassword({
    required String oldpwd,
    required String pwd,
    required String repwd,
  }) async => message;
}

class _Credentials extends CredentialStore {
  Credentials? _saved;
  bool _cleanup = false;

  @override
  Credentials? load() => _saved;
  @override
  void save(Credentials credentials) => _saved = credentials;
  @override
  void clear() => _saved = null;
  @override
  RememberedLogin? loadRemembered() => null;
  @override
  bool get sessionCleanupPending => _cleanup;
  @override
  void beginSessionCleanup() => _cleanup = true;
  @override
  void finishSessionCleanup() => _cleanup = false;
  @override
  String deviceId() => 'audit';
  @override
  String? loadApiOrigin() => 'https://panel.example.test';
  @override
  String? loadSiteOrigin() => 'https://panel.example.test';
}

class _Cache extends PanelResponseCache {
  @override
  void saveProfile(String accountKey, UserProfile profile) {}
  @override
  UserProfile? loadProfile(String accountKey) => null;
}

class _Platform implements PlatformService {
  @override
  String get platformId => 'windows';
  @override
  bool get isTelevision => false;
  @override
  Future<String> deviceName() async => 'audit';
  @override
  Future<({String model, String os})> deviceProfile() async =>
      (model: 'audit', os: 'test');
  @override
  Future<String> protectSecret(String name, String plaintext) async =>
      plaintext;
  @override
  Future<String?> unprotectSecret(String name, String protected) async =>
      protected;
  @override
  Future<void> deleteSecret(String name) async {}
  @override
  Future<void> setImeEnabled({required bool enabled}) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Connection implements ConnectionController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Announcements implements AnnouncementController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Update implements UpdateController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings implements SettingsStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
