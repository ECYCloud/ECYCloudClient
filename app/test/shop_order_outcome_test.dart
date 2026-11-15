import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:ecycloud_client/data/models/shop.dart';
import 'package:ecycloud_client/data/models/user_profile.dart';
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/state/announcement_controller.dart';
import 'package:ecycloud_client/state/auth_controller.dart';
import 'package:ecycloud_client/state/connection_controller.dart';
import 'package:ecycloud_client/state/update_controller.dart';
import 'package:ecycloud_client/ui/app_scope.dart';
import 'package:ecycloud_client/ui/pages/shop_page.dart';
import 'package:ecycloud_client/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Api extends PanelApiClient {
  _Api({this.billingBaseType = '', this.rechargedToBalance = false})
    : super(
        baseUrl: 'https://fixture.invalid',
        configBaseUrl: 'https://fixture.invalid',
        device: const DeviceInfo(
          platform: 'windows',
          deviceId: 'fixture',
          deviceName: '',
          deviceModel: '',
          osVersion: '',
          appVersion: '',
        ),
      );

  final String billingBaseType;
  final bool rechargedToBalance;

  @override
  Future<ShopCatalog> fetchShopProducts() async =>
      ShopCatalog.fromJson(<String, dynamic>{
        'products': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 1,
            'name': '测试套餐',
            'type': 'plan',
            'price': '200.00',
            'class_expire': 365,
            'auto_renew': 1,
            'in_stock': true,
          },
        ],
      });

  @override
  Future<PlanQuote> fetchPlanQuote({
    required int shop,
    String coupon = '',
  }) async => PlanQuote.fromJson(<String, dynamic>{
    'name': '测试套餐',
    'total': '0.00',
    'has_traffic_reset_fee': true,
    'traffic_current_shop_name': '原套餐',
    'traffic_used': 1024,
    'traffic_total': 2048,
    'traffic_billing_base_price': '16.44',
    'traffic_billing_base_type': billingBaseType,
    'traffic_reset_fee': '3.26',
    'traffic_usage_percent': 19.83,
    'traffic_fee_percent': 19.83,
  });

  @override
  Future<ShopPurchaseResult> buyPlan({
    required int shop,
    required String coupon,
    required bool autoRenew,
    required bool disableOthers,
    String epayType = '',
  }) async => ShopPurchaseResult.fromEnvelope(<String, dynamic>{
    'msg': '',
    'data': <String, dynamic>{
      'tradeno': '2026110300001',
      'payment_url': 'https://pay.example.invalid/submit',
    },
  });

  @override
  Future<PaymentStatus> fetchPaymentStatus(String tradeNo) async =>
      PaymentStatus.fromJson(<String, dynamic>{
        'paid': true,
        'total': 20,
        'card_key': '',
        'recharged_to_balance': rechargedToBalance,
      });
}

class _Auth extends ChangeNotifier implements AuthController {
  _Auth(this.api);

  @override
  final PanelApiClient api;
  @override
  String? get accountKey => null;
  @override
  UserProfile? get profile => null;
  @override
  String get siteOrigin => 'https://fixture.invalid';
  @override
  Future<void> refreshProfile() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Connection implements ConnectionController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Platform implements PlatformService {
  @override
  bool get isTelevision => false;
  @override
  bool get supportsPayScheme => false;
  @override
  Future<bool> openUrl(String url) async => true;
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

Future<void> _openOrder(WidgetTester tester, _Api api) async {
  tester.view.physicalSize = const Size(1000, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final _Auth auth = _Auth(api);
  final AnnouncementController announcements = AnnouncementController();
  addTearDown(api.close);
  addTearDown(auth.dispose);
  addTearDown(announcements.dispose);
  await tester.pumpWidget(
    AppScope(
      auth: auth,
      connection: _Connection(),
      announcements: announcements,
      update: _Update(),
      platform: _Platform(),
      settingsStore: _Settings(),
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: ShopPage()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('购买'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('购买'));
  await tester.pumpAndSettle();
}

Future<void> _payAndWait(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, '购买').last);
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(seconds: 6));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  test('接口字段按服务端键名解析', () {
    final PaymentStatus status = PaymentStatus.fromJson(<String, dynamic>{
      'paid': true,
      'total': 1,
      'card_key': '',
      'recharged_to_balance': true,
    });
    expect(status.rechargedToBalance, isTrue);
    expect(
      PaymentStatus.fromJson(<String, dynamic>{'paid': true})
          .rechargedToBalance,
      isFalse,
    );
    expect(
      PlanQuote.fromJson(<String, dynamic>{
        'traffic_billing_base_type': 'previous_plan',
      }).trafficBillingBaseType,
      'previous_plan',
    );
  });

  testWidgets('转入余额的订单不显示支付成功', (WidgetTester tester) async {
    await _openOrder(tester, _Api(rechargedToBalance: true));
    await _payAndWait(tester);
    expect(
      find.textContaining('商品未能交付，款项已转入余额。', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('支付成功', findRichText: true), findsNothing);
    await tester.tap(find.text('我知道了'));
    await tester.pumpAndSettle();
  });

  testWidgets('正常到账的订单仍显示支付成功', (WidgetTester tester) async {
    await _openOrder(tester, _Api());
    await _payAndWait(tester);
    expect(
      find.textContaining('支付成功，订单已到账。', findRichText: true),
      findsOneWidget,
    );
    await tester.tap(find.text('我知道了'));
    await tester.pumpAndSettle();
  });

  for (final String type in <String>['actual_price', '30day_price', '']) {
    testWidgets('按新套餐计费（$type）标注新套餐', (WidgetTester tester) async {
      await _openOrder(tester, _Api(billingBaseType: type));
      expect(find.text('新套餐：测试套餐 计费基准价：16.44 元'), findsOneWidget);
      expect(find.text('流量重置费：16.44 x 19.83% = 3.26 元'), findsOneWidget);
    });
  }

  testWidgets('按旧套餐计费不标注新套餐', (WidgetTester tester) async {
    await _openOrder(tester, _Api(billingBaseType: 'previous_plan'));
    expect(find.textContaining('新套餐：'), findsNothing);
    expect(find.text('计费基准价：16.44 元'), findsOneWidget);
    expect(find.text('流量重置费：16.44 x 19.83% = 3.26 元'), findsOneWidget);
    expect(find.text('费用规则：按已用流量比例计算，50% 封顶'), findsOneWidget);
  });

  testWidgets('补收此前少收的费用不展示公式', (WidgetTester tester) async {
    await _openOrder(tester, _Api(billingBaseType: 'fee_shortfall'));
    expect(find.text('此前更换套餐时未收齐的流量重置费：3.26 元'), findsOneWidget);
    expect(find.textContaining('新套餐：'), findsNothing);
    expect(find.textContaining('现有套餐：'), findsNothing);
    expect(find.textContaining('流量重置费：'), findsOneWidget);
    expect(find.textContaining('费用规则'), findsNothing);
  });
}
