import 'dart:async';

import 'package:ecycloud_client/data/api/api_exception.dart';
import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:ecycloud_client/data/models/account.dart';
import 'package:ecycloud_client/data/models/shop.dart';
import 'package:ecycloud_client/data/models/ticket.dart';
import 'package:ecycloud_client/data/models/user_profile.dart';
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:ecycloud_client/data/store/credential_store.dart';
import 'package:ecycloud_client/main.dart';
import 'package:ecycloud_client/l10n/app_language.dart';
import 'package:ecycloud_client/l10n/l10n.dart';
import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/state/announcement_controller.dart';
import 'package:ecycloud_client/state/auth_controller.dart';
import 'package:ecycloud_client/state/connection_controller.dart';
import 'package:ecycloud_client/state/update_controller.dart';
import 'package:ecycloud_client/ui/app_scope.dart';
import 'package:ecycloud_client/ui/pages/balance_records_page.dart';
import 'package:ecycloud_client/ui/pages/delete_account_page.dart';
import 'package:ecycloud_client/ui/pages/invite_page.dart';
import 'package:ecycloud_client/ui/pages/login_logs_page.dart';
import 'package:ecycloud_client/ui/pages/login_page.dart';
import 'package:ecycloud_client/ui/pages/operation_logs_page.dart';
import 'package:ecycloud_client/ui/pages/purchases_page.dart';
import 'package:ecycloud_client/ui/pages/recharge_page.dart';
import 'package:ecycloud_client/ui/pages/rule_providers_page.dart';
import 'package:ecycloud_client/ui/pages/shop_page.dart';
import 'package:ecycloud_client/ui/pages/subscription_strategy_page.dart';
import 'package:ecycloud_client/ui/pages/tickets_page.dart';
import 'package:ecycloud_client/ui/pages/traffic_log_page.dart';
import 'package:ecycloud_client/ui/pages/unlock_page.dart';
import 'package:ecycloud_client/ui/pages/devices_page.dart';
import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/list_toolbar.dart';
import 'package:ecycloud_client/ui/widgets/search_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

class _Api implements PanelApiClient {
  String value = '第一版';
  int calls = 0;
  Object? error;
  Future<UnlockListPage> Function(int page, String search)? unlock;
  Future<BalanceListPage> Function()? balance;
  Future<ShopCatalog> Function()? shop;
  final Completer<AccountStatus> deletion = Completer<AccountStatus>();
  final List<(int, String)> queries = <(int, String)>[];
  final List<Map<String, dynamic>> withdrawRecords = <Map<String, dynamic>>[];

  UnlockListPage unlockResult({int page = 1, String? text}) =>
      UnlockListPage.fromJson(<String, dynamic>{
        'results': <Object>[
          <String, dynamic>{
            'node_name': '测试节点',
            'created_at': '2026-09-14 10:00:00',
            'unlock_item': <String, String>{'YouTube_Premium': text ?? value},
          },
        ],
        'current_page': page,
        'last_page': 3,
        'total': 60,
        'unlock_check_interval': 1,
      });

  Future<T> _respond<T>(T result) {
    calls++;
    return error == null ? Future<T>.value(result) : Future<T>.error(error!);
  }

  @override
  Future<BalanceListPage> fetchBalanceTransactions({
    int page = 1,
    int length = 10,
    String search = '',
  }) {
    if (balance != null) {
      calls++;
      return balance!();
    }
    return _respond(
      BalanceListPage.fromJson(<String, dynamic>{
        'items': <Object>[
          <String, dynamic>{'order_no': value},
        ],
        'total': 1,
      }),
    );
  }

  @override
  Future<AccountStatus> killAccount({String? emailCode}) => deletion.future;

  @override
  Future<UnlockListPage> fetchUnlockResults({
    int page = 1,
    int length = 10,
    String search = '',
  }) {
    queries.add((page, search));
    if (unlock != null) {
      calls++;
      return unlock!(page, search);
    }
    return _respond(unlockResult(page: page));
  }

  @override
  DeviceInfo get device => const DeviceInfo(
    platform: 'Windows',
    deviceId: 'test',
    deviceName: 'test',
    deviceModel: 'test',
    osVersion: 'test',
    appVersion: '0.0.0',
  );

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final Map<String, dynamic> item = <String, dynamic>{
      'order_no': value,
      'device': value,
      'operation_description': value,
    };
    final Map<String, dynamic> list = <String, dynamic>{
      'items': <Object>[item],
      'total': 1,
    };
    return switch (invocation.memberName) {
      #fetchLoginLogs => _respond(LoginLogListPage.fromJson(list)),
      #fetchOperationLogs => _respond(OperationLogListPage.fromJson(list)),
      #fetchDevices => _respond(DeviceListPage.fromJson(list)),
      #fetchPurchases => _respond(
        PurchaseListPage.fromJson(<String, dynamic>{
          'purchases': <Object>[item],
          'total': 1,
        }),
      ),
      #fetchInviteSummary => _respond(
        InviteSummary.fromJson(<String, dynamic>{
          'code': value,
          'withdraw_records': withdrawRecords,
        }),
      ),
      #fetchRechargeInfo => _respond(
        RechargeInfo.fromJson(<String, dynamic>{'total_top_up': value}),
      ),
      #fetchSubscriptionConfig => _respond(
        SubscriptionConfig.fromJson(<String, dynamic>{
          'all_group_names': <String>['主节点'],
          'customizable_groups': <String>['主节点'],
          'allow_custom_hosts': true,
          'available_proxy_names': <String>['主节点'],
          'group_labels': <String, String>{'主节点': value},
          'custom_hosts': 'fixture.test 127.0.0.1',
        }),
      ),
      #fetchTrafficLog => _respond(
        TrafficLogBundle.fromJson(<String, dynamic>{
          'total_usage': value,
          'traffic': <String, dynamic>{
            '2026-09-14': <String, dynamic>{'total_usage': value},
          },
        }),
      ),
      #fetchShopProducts =>
        shop?.call() ??
            _respond(
              ShopCatalog.fromJson(<String, dynamic>{
                'products': <Object>[
                  <String, dynamic>{
                    'id': 1,
                    'name': value,
                    'type': 'plan',
                    'class_expire': 30,
                  },
                ],
              }),
            ),
      #fetchTickets => _respond(
        TicketListPage.fromJson(<String, dynamic>{
          'tickets': <Object>[
            <String, dynamic>{'id': 1, 'title': value},
          ],
          'total': 1,
        }),
      ),
      #fetchTicket => _respond(
        TicketDetail.fromJson(<String, dynamic>{
          'id': 1,
          'title': value,
          'messages': <Object>[
            for (int i = 1; i <= 30; i++)
              <String, dynamic>{'id': i, 'content': '<p>回复$i</p>'},
          ],
        }),
      ),
      _ => super.noSuchMethod(invocation),
    };
  }
}

class _Auth extends ChangeNotifier implements AuthController {
  _Auth(this.api);
  @override
  bool get busy => false;
  @override
  String? get error => null;
  @override
  Future<RememberedLogin?> loadRememberedLogin() async => null;
  @override
  Future<bool> login({
    required String email,
    required String password,
    String? twoFactorCode,
  }) async {
    stage = AuthStage.needsTwoFactor;
    notifyListeners();
    return false;
  }

  @override
  _Api api;
  UserProfile? profileValue;
  @override
  UserProfile? get profile => profileValue;
  @override
  String get siteOrigin => '';
  @override
  String? accountKey;
  @override
  AuthStage stage = AuthStage.unknown;
  @override
  set onConfigRevision(void Function(String)? value) {}
  @override
  Future<AuthOptions?> fetchAuthOptions() async =>
      AuthOptions.fromJson(<String, dynamic>{'enable_kill': true});
  @override
  void enterRestricted(AccountStatus status) {
    stage = AuthStage.accountRestricted;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Connection extends ChangeNotifier implements ConnectionController {
  int disconnects = 0;
  @override
  Future<void> disconnect() async {
    disconnects++;
  }

  @override
  Future<void> shutdown({bool clearSession = false}) => disconnect();

  List<RuleProviderRef> rules = const <RuleProviderRef>[];
  @override
  AppSettings get settings => const AppSettings.defaults();
  @override
  void attachApi(PanelApiClient? api, {String? accountKey}) {}
  @override
  void attachProfileLookup(UserProfile? Function()? lookup) {}
  @override
  set onPanelSync(Future<void> Function()? value) {}
  @override
  set onSessionRejected(Future<void> Function()? value) {}
  @override
  List<RuleProviderRef> ruleProviderRefs() => rules;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Announcements extends ChangeNotifier implements AnnouncementController {
  @override
  void attachApi(PanelApiClient? api) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Update extends ChangeNotifier implements UpdateController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Platform implements PlatformService {
  @override
  Future<void> setImeEnabled({required bool enabled}) async {}
  @override
  bool get isTelevision => false;
  @override
  Future<void> initialize() => Completer<void>().future;
  @override
  Future<void> setWindowDark({
    required bool dark,
    int caption = 0,
    int text = 0,
  }) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings implements SettingsStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pumpPage(
  WidgetTester tester,
  Widget page,
  _Api api, {
  bool narrow = false,
  _Connection? connection,
  Locale? locale,
  _Auth? auth,
}) async {
  tester.view.physicalSize = narrow
      ? const Size(390, 844)
      : const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final _Auth panelAuth = auth ?? _Auth(api);
  final _Connection conn = connection ?? _Connection();
  final _Announcements announcements = _Announcements();
  final _Update update = _Update();
  addTearDown(() {
    panelAuth.dispose();
    conn.dispose();
    announcements.dispose();
    update.dispose();
  });
  await tester.pumpWidget(
    AppScope(
      auth: panelAuth,
      connection: conn,
      announcements: announcements,
      update: update,
      platform: _Platform(),
      settingsStore: _Settings(),
      child: MaterialApp(
        theme: narrow ? AppTheme.dark() : AppTheme.light(),
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          body: locale == null
              ? page
              : Builder(
                  builder: (context) => Localizations.override(
                    context: context,
                    locale: locale,
                    child: page,
                  ),
                ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final AppLanguage language in <AppLanguage>[
    AppLanguage.en,
    AppLanguage.zhTW,
  ]) {
    for (final bool narrow in <bool>[false, true]) {
      testWidgets('商店实际页面翻译库存和倒计时：${language.name}/$narrow', (tester) async {
        addTearDown(() => L10n.current = AppLanguage.zhCN);
        L10n.current = language;
        final _Api api = _Api()
          ..shop = () async => ShopCatalog.fromJson(<String, dynamic>{
            'products': <Object>[
              <String, dynamic>{
                'id': 1,
                'name': 'Fixture plan',
                'type': 'plan',
                'class_expire': 30,
                'stock': '12件',
                'in_stock': true,
                'countdowns': <Object>[
                  <String, dynamic>{
                    'label': '限时销售',
                    'end':
                        DateTime.now()
                            .add(const Duration(days: 1))
                            .millisecondsSinceEpoch ~/
                        1000,
                  },
                ],
              },
            ],
          });
        await _pumpPage(
          tester,
          const ShopPage(),
          api,
          narrow: narrow,
          locale: language.flutterLocale,
        );
        expect(
          find.text(language == AppLanguage.en ? 'Stock 12' : '庫存12件'),
          findsWidgets,
        );
        expect(
          find.text(language == AppLanguage.en ? 'Limited-time sale' : '限時銷售'),
          findsWidgets,
        );
        expect(
          find.textContaining('12件'),
          language == AppLanguage.en ? findsNothing : findsWidgets,
        );
        await tester.pumpWidget(const SizedBox());
      });
      testWidgets('邀请实际页面翻译提现状态：${language.name}/$narrow', (tester) async {
        addTearDown(() => L10n.current = AppLanguage.zhCN);
        L10n.current = language;
        final _Api api = _Api()
          ..withdrawRecords.add(<String, dynamic>{
            'id': 1,
            'amount': 1,
            'status': 2,
            'status_text': '已拒绝',
            'channel': 'Fixture channel',
          });
        await _pumpPage(
          tester,
          const InvitePage(),
          api,
          narrow: narrow,
          locale: language.flutterLocale,
        );
        await tester.ensureVisible(find.text(L10n.t('提现记录')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(L10n.t('提现记录')));
        await tester.pumpAndSettle();
        expect(
          find.text(language == AppLanguage.en ? 'Rejected' : '已拒絕'),
          findsWidgets,
        );
        expect(find.text('已拒绝'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('策略组语言切换更新译名并保留未保存内容', (tester) async {
    final _Api api = _Api()..value = '中文组名';
    await _pumpPage(
      tester,
      const SubscriptionStrategyPage(),
      api,
      locale: const Locale('zh'),
    );
    expect(find.text('中文组名'), findsWidgets);
    await tester.tap(find.text('配置策略'));
    await tester.pumpAndSettle();
    final editable = tester.widgetList<EditableText>(find.byType(EditableText));
    final hosts = editable.firstWhere(
      (field) => field.controller.text == 'fixture.test 127.0.0.1',
    );
    hosts.controller.text = 'draft.test 127.0.0.2';
    api.value = 'Main nodes';
    await _pumpPage(
      tester,
      const SubscriptionStrategyPage(),
      api,
      locale: const Locale('en'),
    );
    expect(hosts.controller.text, 'draft.test 127.0.0.2');
    await tester.tap(find.text('分组策略'));
    await tester.pumpAndSettle();
    expect(find.text('Main nodes'), findsWidgets);
    expect(api.calls, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('换账户同一帧内返回的商品不能写进新账户商店缓存', (tester) async {
    final AppLanguage language = L10n.current;
    addTearDown(() => L10n.current = language);
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Completer<ShopCatalog> pending = Completer<ShopCatalog>();
    final _Api first = _Api()..shop = () => pending.future;
    final _Api second = _Api()..value = '新账户商品';
    final _Auth auth = _Auth(first)
      ..stage = AuthStage.loggedIn
      ..accountKey = 'shop-first@example.test';
    final _Connection connection = _Connection();
    final _Announcements announcements = _Announcements();
    final _Update update = _Update();
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
        platform: _Platform(),
        settingsStore: _Settings(),
        child: const EcyCloudApp(),
      ),
    );
    auth.notifyListeners();
    await tester.pump();
    unawaited(
      tester
          .state<NavigatorState>(find.byType(Navigator).first)
          .push<void>(
            MaterialPageRoute<void>(builder: (_) => const ShopPage()),
          ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    auth
      ..api = second
      ..accountKey = 'shop-second@example.test'
      ..notifyListeners();
    pending.complete(
      ShopCatalog.fromJson(<String, dynamic>{
        'products': <Object>[
          <String, dynamic>{
            'id': 1,
            'name': '旧账户私有商品',
            'type': 'plan',
            'class_expire': 30,
          },
        ],
      }),
    );
    await tester.idle();
    await tester.pump();
    unawaited(
      tester
          .state<NavigatorState>(find.byType(Navigator).first)
          .push<void>(
            MaterialPageRoute<void>(builder: (_) => const ShopPage()),
          ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('旧账户私有商品'), findsNothing);
    expect(find.text('新账户商品'), findsOneWidget);
    expect(second.calls, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('登录进入两步验证时保留登录表单和验证码弹窗', (tester) async {
    final AppLanguage language = L10n.current;
    addTearDown(() => L10n.current = language);
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _Auth auth = _Auth(_Api())..stage = AuthStage.loggedOut;
    final _Connection connection = _Connection();
    final _Announcements announcements = _Announcements();
    final _Update update = _Update();
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
        platform: _Platform(),
        settingsStore: _Settings(),
        child: const EcyCloudApp(),
      ),
    );
    auth.notifyListeners();
    await tester.pump();
    L10n.current = AppLanguage.zhCN;
    final NavigatorState navigator = tester.state(find.byType(Navigator).first);
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(builder: (_) => const LoginPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(find.byType(TextField).at(0), 'audit@example.test');
    await tester.enterText(find.byType(TextField).at(1), 'audit-password');
    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('两步验证'), findsOneWidget);
    expect(tester.state(find.byType(Navigator).first), same(navigator));
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('audit@example.test'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('旧账户删除响应不能停用新账户连接或改变其状态', (tester) async {
    final _Api api = _Api();
    final _Connection connection = _Connection();
    await _pumpPage(
      tester,
      const DeleteAccountPage(),
      api,
      connection: connection,
    );
    final _Auth auth =
        AppScope.of(tester.element(find.byType(DeleteAccountPage))).auth
            as _Auth;
    auth.stage = AuthStage.loggedIn;
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('提交删除请求').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pump();
    auth.api = _Api();
    await tester.pumpWidget(const SizedBox.shrink());
    api.deletion.complete(
      AccountStatus.fromJson(<String, dynamic>{
        'email': 'first@example.test',
        'enable': -1,
      }),
    );
    await tester.pump();
    expect(connection.disconnects, 0);
    expect(auth.stage, AuthStage.loggedIn);
    expect(tester.takeException(), isNull);
  });

  for (final AuthStage next in <AuthStage>[
    AuthStage.loggedOut,
    AuthStage.accountRestricted,
    AuthStage.loggedIn,
  ]) {
    testWidgets('账户边界变化 $next 必须销毁已打开的私人页面', (tester) async {
      final AppLanguage language = L10n.current;
      addTearDown(() => L10n.current = language);
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final _Api api = _Api();
      final _Auth auth = _Auth(api)
        ..stage = AuthStage.loggedIn
        ..accountKey = 'first@example.test';
      final _Connection connection = _Connection();
      final _Announcements announcements = _Announcements();
      final _Update update = _Update();
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
          platform: _Platform(),
          settingsStore: _Settings(),
          child: const EcyCloudApp(),
        ),
      );
      auth.notifyListeners();
      await tester.pump();
      final NavigatorState navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(builder: (_) => const BalanceRecordsPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('第一版'), findsOneWidget);
      auth.notifyListeners();
      await tester.pump();
      expect(find.text('第一版'), findsOneWidget);
      expect(tester.state(find.byType(Navigator).first), same(navigator));

      final Completer<BalanceListPage> pending = Completer<BalanceListPage>();
      api.balance = () => pending.future;
      await tester.pump(const Duration(seconds: 60));
      auth
        ..stage = next
        ..accountKey = next == AuthStage.loggedIn ? 'second@example.test' : null
        ..notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(BalanceRecordsPage), findsNothing);
      pending.complete(
        BalanceListPage.fromJson(<String, dynamic>{
          'items': <Object>[
            <String, dynamic>{'order_no': '旧账户迟到数据'},
          ],
        }),
      );
      await tester.pump();
      expect(find.text('旧账户迟到数据'), findsNothing);
      expect(tester.takeException(), isNull);
      final int calls = api.calls;
      await tester.pump(const Duration(seconds: 60));
      expect(api.calls, calls);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  const Map<String, Widget> pages = <String, Widget>{
    '解锁': UnlockPage(),
    '工单': TicketsPage(),
    '邀请': InvitePage(),
    '余额': BalanceRecordsPage(),
    '购买': PurchasesPage(),
    '登录': LoginLogsPage(),
    '操作': OperationLogsPage(),
    '设备': DevicesPage(),
    '流量': TrafficLogPage(),
    '充值': RechargePage(),
    '商店': ShopPage(),
  };
  for (final MapEntry<String, Widget> entry in pages.entries) {
    for (final bool narrow in <bool>[false, true]) {
      testWidgets('${entry.key}在${narrow ? '窄屏深色' : '宽屏浅色'}自动更新且关闭后停止', (
        tester,
      ) async {
        final _Api api = _Api();
        await _pumpPage(tester, entry.value, api, narrow: narrow);
        if (entry.value is UnlockPage || entry.value is TicketsPage) {
          final Rect search = tester.getRect(find.byType(SearchField));
          final Rect description = tester.getRect(find.byType(Card).first);
          expect(description.top - search.bottom, 12);
        }
        expect(api.calls, 1);
        expect(find.textContaining('第一版'), findsWidgets);
        api.value = '第二版';
        await tester.pump(const Duration(seconds: 60));
        await tester.pumpAndSettle();
        expect(api.calls, 2);
        expect(find.textContaining('第二版'), findsWidgets);
        expect(find.textContaining('第一版'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 60));
        expect(api.calls, 2);
      });
    }
  }

  testWidgets('面板下发版本号后不再定时拉取，只在本页版本变化时静默重取', (tester) async {
    UserProfile profile(Map<String, String> revisions) =>
        UserProfile.fromJson(<String, dynamic>{
          'id': 7,
          'email': 'member@example.test',
          'revisions': revisions,
        });
    final _Api api = _Api();
    final _Auth auth = _Auth(api)
      ..profileValue = profile(<String, String>{'unlock': 'revision-1'});
    await _pumpPage(tester, const UnlockPage(), api, auth: auth);
    final int initial = api.calls;
    await tester.pump(const Duration(seconds: 180));
    await tester.pumpAndSettle();
    expect(api.calls, initial);

    api.value = '新版本结果';
    auth
      ..profileValue = profile(<String, String>{'unlock': 'revision-2'})
      ..notifyListeners();
    await tester.pumpAndSettle();
    expect(api.calls, initial + 1);
    expect(find.text('新版本结果'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    auth
      ..profileValue = profile(<String, String>{
        'shop': 'revision-9',
        'unlock': 'revision-2',
      })
      ..notifyListeners();
    await tester.pumpAndSettle();
    expect(api.calls, initial + 1);

    auth
      ..profileValue = profile(<String, String>{})
      ..notifyListeners();
    await tester.pump(const Duration(seconds: 60));
    await tester.pumpAndSettle();
    expect(api.calls, initial + 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('解锁刷新失败保留结果，下一周期恢复', (tester) async {
    final _Api api = _Api();
    await _pumpPage(tester, const UnlockPage(), api);
    api.error = ApiException('测试断网');
    await tester.pump(const Duration(seconds: 60));
    await tester.pumpAndSettle();
    expect(find.text('第一版'), findsOneWidget);
    expect(find.text('测试断网'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    api.error = null;
    api.value = '恢复结果';
    await tester.pump(const Duration(seconds: 60));
    await tester.pumpAndSettle();
    expect(find.text('恢复结果'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('解锁自动刷新保留搜索和页码，旧请求不能覆盖新的搜索', (tester) async {
    final _Api api = _Api();
    await _pumpPage(tester, const UnlockPage(), api);
    tester.widget<ListToolbar>(find.byType(ListToolbar)).onSearchChanged('香港');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    tester.widget<ListToolbar>(find.byType(ListToolbar)).onPageChanged(2);
    await tester.pumpAndSettle();
    final Completer<UnlockListPage> pending = Completer<UnlockListPage>();
    api.unlock = (page, search) => pending.future;
    await tester.pump(const Duration(seconds: 60));
    expect(api.queries.last, (2, '香港'));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    api.unlock = (page, search) async =>
        api.unlockResult(page: page, text: '最新搜索');
    tester.widget<ListToolbar>(find.byType(ListToolbar)).onSearchChanged('德国');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(api.queries.last, (1, '德国'));
    pending.complete(api.unlockResult(page: 2, text: '过期结果'));
    await tester.pumpAndSettle();
    expect(find.text('最新搜索'), findsOneWidget);
    expect(find.text('过期结果'), findsNothing);
    expect(tester.widget<ListToolbar>(find.byType(ListToolbar)).currentPage, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('解锁慢请求不叠加轮询，关闭页面后返回也不更新', (tester) async {
    final _Api api = _Api();
    await _pumpPage(tester, const UnlockPage(), api);
    final Completer<UnlockListPage> pending = Completer<UnlockListPage>();
    api.unlock = (page, search) => pending.future;
    await tester.pump(const Duration(seconds: 60));
    await tester.pump(const Duration(seconds: 120));
    expect(api.calls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(api.unlockResult());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 60));
    expect(api.calls, 2);
  });

  testWidgets('过期的手动搜索失败不覆盖新搜索的空结果', (tester) async {
    final _Api api = _Api();
    await _pumpPage(tester, const UnlockPage(), api);
    final Completer<UnlockListPage> pending = Completer<UnlockListPage>();
    api.unlock = (page, search) => pending.future;
    tester.widget<ListToolbar>(find.byType(ListToolbar)).onSearchChanged('旧搜索');
    await tester.pump(const Duration(milliseconds: 300));
    api.unlock = (page, search) async =>
        UnlockListPage.fromJson(<String, dynamic>{'results': <Object>[]});
    tester.widget<ListToolbar>(find.byType(ListToolbar)).onSearchChanged('新搜索');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(api.queries.last, (1, '新搜索'));
    expect(find.text('没有匹配结果'), findsOneWidget);
    pending.completeError(ApiException('旧搜索失败'));
    await tester.pumpAndSettle();
    expect(find.text('旧搜索失败'), findsNothing);
    expect(find.text('没有匹配结果'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('关闭页面后请求失败不触发页面更新', (tester) async {
    final _Api api = _Api();
    await _pumpPage(tester, const UnlockPage(), api);
    final Completer<UnlockListPage> pending = Completer<UnlockListPage>();
    api.unlock = (page, search) => pending.future;
    tester.widget<ListToolbar>(find.byType(ListToolbar)).onSearchChanged('搜索');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox.shrink());
    pending.completeError(ApiException('页面关闭后的错误'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('工单详情自动更新且保留正在查看的消息页', (tester) async {
    final _Api api = _Api();
    await _pumpPage(tester, const TicketsPage(), api);
    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byType(ListToolbar),
      500,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(tester.widget<ListToolbar>(find.byType(ListToolbar)).lastPage, 3);
    tester.widget<ListToolbar>(find.byType(ListToolbar)).onPageChanged(2);
    await tester.pumpAndSettle();
    api.value = '新回复';
    await tester.pump(const Duration(seconds: 60));
    await tester.pumpAndSettle();
    expect(find.text('新回复 (#1)'), findsOneWidget);
    expect(tester.widget<ListToolbar>(find.byType(ListToolbar)).currentPage, 2);
    expect(find.text('回复11'), findsOneWidget);
    tester.widget<ListToolbar>(find.byType(ListToolbar)).onPageChanged(3);
    await tester.pumpAndSettle();
    expect(find.text('回复21'), findsOneWidget);
    expect(find.text('回复30'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('充值自动刷新不清空输入内容', (tester) async {
    final _Api api = _Api();
    await _pumpPage(tester, const RechargePage(), api);
    await tester.enterText(find.byType(TextField).first, 'MY-CODE');
    api.value = '充值更新';
    await tester.pump(const Duration(seconds: 60));
    await tester.pumpAndSettle();
    expect(find.text('MY-CODE'), findsOneWidget);
    expect(find.textContaining('充值更新'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('商店首次加载错误正常显示，自动重试后恢复商品', (tester) async {
    final _Api api = _Api()..error = ApiException('商店暂时不可用');
    await _pumpPage(tester, const ShopPage(), api);
    expect(find.text('商店暂时不可用'), findsOneWidget);
    api.error = null;
    await tester.pump(const Duration(seconds: 60));
    await tester.pumpAndSettle();
    expect(find.text('商店暂时不可用'), findsNothing);
    expect(find.textContaining('第一版'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('分流规则列表跟随配置通知更新', (tester) async {
    final _Connection connection = _Connection();
    await _pumpPage(
      tester,
      const RuleProvidersPage(),
      _Api(),
      connection: connection,
    );
    connection.rules = const <RuleProviderRef>[
      RuleProviderRef(name: '新增规则', relativePath: 'ECYCloud-Rules/test.mrs'),
    ];
    connection.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('新增规则'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('邀请记录用切换按钮且搜索分页在卡片外', (tester) async {
    for (final bool narrow in <bool>[true, false]) {
      await _pumpPage(tester, const InvitePage(), _Api(), narrow: narrow);
      await _expectToolbarsOutsideCards(tester);
      expect(find.text('暂无邀请用户'), findsOneWidget);
      expect(find.text('暂无返利记录'), findsNothing);
      await tester.ensureVisible(find.text('返利记录'));
      await tester.tap(find.text('返利记录'));
      await tester.pumpAndSettle();
      expect(find.text('暂无返利记录'), findsOneWidget);
      expect(find.text('暂无邀请用户'), findsNothing);
      await tester.ensureVisible(find.text('提现记录'));
      await tester.tap(find.text('提现记录'));
      await tester.pumpAndSettle();
      expect(find.text('暂无提现记录'), findsOneWidget);
      expect(find.text('暂无返利记录'), findsNothing);
      await _expectToolbarsOutsideCards(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}

Future<void> _expectToolbarsOutsideCards(WidgetTester tester) async {
  expect(find.byType(ListToolbar), findsOneWidget);
  final List<Rect> cards = <Rect>[
    for (final Element card in find.byType(Card).evaluate())
      tester.getRect(find.byWidget(card.widget)),
  ];
  expect(cards, isNotEmpty);
  for (final Element toolbar in find.byType(ListToolbar).evaluate()) {
    final Rect toolbarRect = tester.getRect(find.byWidget(toolbar.widget));
    for (final Rect card in cards) {
      expect(card.overlaps(toolbarRect), isFalse);
    }
  }
}
