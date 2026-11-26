import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:ecycloud_client/data/models/account.dart';
import 'package:ecycloud_client/data/models/user_profile.dart';
import 'package:ecycloud_client/data/store/credential_store.dart';
import 'package:ecycloud_client/data/store/json_file_store.dart';
import 'package:ecycloud_client/data/store/panel_response_cache.dart';
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/state/announcement_controller.dart';
import 'package:ecycloud_client/state/auth_controller.dart';
import 'package:ecycloud_client/state/connection_controller.dart';
import 'package:ecycloud_client/state/update_controller.dart';
import 'package:ecycloud_client/ui/app_scope.dart';
import 'package:ecycloud_client/ui/pages/login_page.dart';
import 'package:ecycloud_client/ui/theme.dart';

const String _origin = 'https://panel.example.test';
const String _token = 'fixture-session-token';
const String _password = 'Fixture-Password-1';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ecy-secret-fallback-');
    file = File('${dir.path}/credentials.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  CredentialStore store() => CredentialStore(
    store: JsonFileStore(file, 'credential', ownerOnly: true),
  );

  AuthController controller(_Platform platform, _Client client) =>
      AuthController(
        platform,
        store()
          ..saveApiOrigin(_origin)
          ..saveSiteOrigin(_origin),
        clearLocalSession: (_) async {},
        cache: _Cache(),
        createClient: (_, _, _) => client,
        bundledOrigins: (site: _origin, api: _origin),
      );

  test('没有系统密钥库时登录令牌落进仅本人可读的凭据文件，重开后仍保持登录', () async {
    final _Platform platform = _Platform(available: false);
    final AuthController first = controller(platform, _Client());
    addTearDown(first.dispose);

    expect(await first.login(email: 'a@example.test', password: 'x'), isTrue);
    expect(store().load()?.token, _token);
    if (!Platform.isWindows) {
      expect(file.statSync().mode & 0x1ff, 0x180);
    }

    final _Client reopened = _Client();
    final AuthController second = controller(platform, reopened);
    addTearDown(second.dispose);
    await second.restore();

    expect(second.stage, AuthStage.loggedIn);
    expect(reopened.token, _token);
    expect(store().load()?.token, _token);
  });

  test('密钥库恢复可用后令牌迁回密钥库，凭据文件不再留明文', () async {
    final _Platform platform = _Platform(available: false);
    final AuthController first = controller(platform, _Client());
    addTearDown(first.dispose);
    await first.login(email: 'a@example.test', password: 'x');

    platform.available = true;
    final _Client reopened = _Client();
    final AuthController second = controller(platform, reopened);
    addTearDown(second.dispose);
    await second.restore();

    expect(second.stage, AuthStage.loggedIn);
    expect(reopened.token, _token);
    expect(platform.keyring, <String, String>{'token': _token});
    expect(file.readAsStringSync(), isNot(contains(_token)));
  });

  test('退出登录删除落盘的令牌', () async {
    final _Platform platform = _Platform(available: false);
    final AuthController auth = controller(platform, _Client());
    addTearDown(auth.dispose);
    await auth.login(email: 'a@example.test', password: 'x');
    expect(file.readAsStringSync(), contains(_token));

    await auth.logout();

    expect(file.readAsStringSync(), isNot(contains(_token)));
    expect(store().load(), isNull);
  });

  test('没有系统密钥库时记住的密码不落盘', () async {
    final _Platform platform = _Platform(available: false);
    final AuthController auth = controller(platform, _Client());
    addTearDown(auth.dispose);

    await expectLater(
      auth.saveRememberedLogin(email: 'a@example.test', password: _password),
      throwsA(isA<PlatformServiceException>()),
    );

    expect(file.readAsStringSync(), isNot(contains(_password)));
    expect(store().loadRemembered(), isNull);
  });

  test('密钥库可用但写入失败时不退回明文', () async {
    final _Platform platform = _Platform(available: true)..storeFails = true;
    final AuthController auth = controller(platform, _Client());
    addTearDown(auth.dispose);

    await auth.login(email: 'a@example.test', password: 'x');

    expect(store().load(), isNull);
    expect(file.readAsStringSync(), isNot(contains(_token)));
  });

  for (final bool available in <bool>[false, true]) {
    testWidgets('登录页：密钥库${available ? '可用时照常记住密码' : '不可用时停用记住密码并说明原因'}', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final _LoginAuth auth = _LoginAuth();
      addTearDown(auth.dispose);
      await tester.pumpWidget(
        AppScope(
          auth: auth,
          connection: _Connection(),
          announcements: _Announcements(),
          update: _Update(),
          platform: _Platform(available: available),
          settingsStore: _Settings(),
          child: MaterialApp(theme: AppTheme.light(), home: const LoginPage()),
        ),
      );
      await tester.pumpAndSettle();

      final Checkbox remember = tester.widget<Checkbox>(find.byType(Checkbox));
      final Finder note = find.textContaining('GNOME Keyring');
      expect(remember.onChanged == null, !available);
      expect(note, available ? findsNothing : findsOneWidget);
      expect(auth.rememberedLoads, available ? 1 : 0);
    });
  }
}

class _Platform implements PlatformService {
  _Platform({required this.available});

  bool available;
  bool storeFails = false;
  final Map<String, String> keyring = <String, String>{};

  @override
  String get platformId => 'linux';
  @override
  bool get isTelevision => false;
  @override
  Future<String> deviceName() async => 'fixture';
  @override
  Future<({String model, String os})> deviceProfile() async =>
      (model: 'fixture', os: 'test');
  @override
  Future<bool> secretStoreAvailable() async => available;
  @override
  Future<String> protectSecret(String name, String plaintext) async {
    if (!available || storeFails) {
      throw PlatformServiceException(
        'The name org.freedesktop.secrets was not provided by any .service files',
      );
    }
    keyring[name] = plaintext;
    return '';
  }

  @override
  Future<String?> unprotectSecret(String name, String blob) async {
    if (!available) {
      throw PlatformServiceException('无法读取凭据');
    }
    return keyring[name];
  }

  @override
  Future<void> deleteSecret(String name) async {
    if (!available) {
      throw PlatformServiceException('无法清除凭据');
    }
    keyring.remove(name);
  }

  @override
  Future<void> setImeEnabled({required bool enabled}) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends PanelApiClient {
  _Client()
    : super(
        baseUrl: _origin,
        configBaseUrl: _origin,
        device: const DeviceInfo(
          platform: 'linux',
          deviceId: 'fixture',
          deviceName: 'fixture',
          deviceModel: 'fixture',
          osVersion: 'test',
          appVersion: 'test',
        ),
      );

  static final UserProfile _profile = UserProfile.fromJson(<String, dynamic>{
    'id': 7,
    'email': 'a@example.test',
    'user_name': 'fixture',
    'class': 1,
    'upload': 0,
    'download': 0,
    'transfer_enable': 100,
  });

  @override
  Future<LoginResult> login({
    required String email,
    required String password,
    String? twoFactorCode,
  }) async => LoginResult(
    _token,
    DateTime.now().add(const Duration(days: 1)),
    profile: _profile,
  );

  @override
  Future<AccountStatus> fetchAccountStatus() async => AccountStatus.fromJson(
    <String, dynamic>{'enable': 1, 'email': 'a@example.test'},
  );

  @override
  Future<UserProfile> fetchProfile() async => _profile;

  @override
  Future<void> logout() async {}

  @override
  void close() {}
}

class _Cache extends PanelResponseCache {
  @override
  UserProfile? loadProfile(String accountKey) => null;
  @override
  void saveProfile(String accountKey, UserProfile profile) {}
}

class _LoginAuth extends ChangeNotifier implements AuthController {
  int rememberedLoads = 0;
  @override
  String get siteOrigin => _origin;
  @override
  bool get busy => false;
  @override
  bool get sendingCode => false;
  @override
  String? get error => null;
  @override
  AuthStage get stage => AuthStage.loggedOut;
  @override
  Future<AuthOptions?> fetchAuthOptions() async => null;
  @override
  Future<RememberedLogin?> loadRememberedLogin() async {
    rememberedLoads++;
    return null;
  }

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
