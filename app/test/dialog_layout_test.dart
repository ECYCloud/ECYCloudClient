import 'dart:async';

import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:ecycloud_client/data/models/announcement.dart';
import 'package:ecycloud_client/data/models/shop.dart';
import 'package:ecycloud_client/data/models/user_profile.dart';
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/state/announcement_controller.dart';
import 'package:ecycloud_client/state/auth_controller.dart';
import 'package:ecycloud_client/state/connection_controller.dart';
import 'package:ecycloud_client/state/update_controller.dart';
import 'package:ecycloud_client/ui/app_scope.dart';
import 'package:ecycloud_client/ui/pages/account_page.dart';
import 'package:ecycloud_client/ui/pages/shop_page.dart';
import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/app_alert_dialog.dart';
import 'package:ecycloud_client/ui/widgets/announcement_dialog.dart';
import 'package:ecycloud_client/ui/widgets/profile_format_dialog.dart';
import 'package:ecycloud_client/ui/widgets/rich_html_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class _Api extends PanelApiClient {
  _Api()
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
    'base_price': '200.00',
    'has_traffic_reset_fee': true,
    'traffic_current_shop_name': '原套餐',
    'traffic_used': 168075165696,
    'traffic_total': 847783329792,
    'traffic_billing_base_price': '16.44',
    'traffic_reset_fee': '3.26',
    'traffic_usage_percent': 19.83,
    'traffic_fee_percent': 19.83,
    'hasValidOrder': 1,
    'upgradeMsg': '剩余价值抵扣后无需支付，返还溢出价值。' * 5,
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

class _Announcements extends ChangeNotifier implements AnnouncementController {
  @override
  final List<Announcement> items = <Announcement>[
    Announcement(
      id: 2,
      title: '测试公告',
      date: '2026-10-11',
      updatedAt: '2026-10-11',
      content: '<p>公告正文需要占满弹窗内容区域并保持左右等距。</p>' * 50,
    ),
    const Announcement(
      id: 3,
      title: '下一条公告',
      date: '2026-10-10',
      updatedAt: '2026-10-10',
      content: '<p>下一条正文</p>',
    ),
  ];

  @override
  bool get busy => false;
  @override
  bool get loaded => true;
  @override
  int get openIndex => 0;
  @override
  Future<void> refresh() async {}
  @override
  void markSeen() {}
  @override
  void markAnnouncementSeen(Announcement announcement) {}
  @override
  void dismissPopup(Announcement announcement) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final bool dark in <bool>[false, true]) {
    for (final (Size size, double textScale) in <(Size, double)>[
      (const Size(1000, 800), 1),
      (const Size(390, 600), 1),
      (const Size(390, 600), 1.5),
    ]) {
      for (final String kind in <String>['配置格式错误', '公告浏览', '自动公告', '续费确认']) {
        testWidgets(
          '$kind弹窗左右留白一致：$size，字号 $textScale，深色 $dark',
          (WidgetTester tester) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final _Api api = _Api();
            final _Auth auth = _Auth(api);
            final _Announcements announcements = _Announcements();
            addTearDown(api.close);
            addTearDown(auth.dispose);
            addTearDown(announcements.dispose);
            final String message = '配置错误详情应完整显示并保持左右等距。\n' * 50;
            await tester.pumpWidget(
              AppScope(
                auth: auth,
                connection: _Connection(),
                announcements: announcements,
                update: _Update(),
                platform: _Platform(),
                settingsStore: _Settings(),
                child: MaterialApp(
                  theme: dark ? AppTheme.dark() : AppTheme.light(),
                  builder: (BuildContext context, Widget? child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(textScale)),
                    child: child!,
                  ),
                  home: Scaffold(
                    body: Builder(
                      builder: (BuildContext context) => TextButton(
                        onPressed: () => unawaited(switch (kind) {
                          '配置格式错误' => showProfileFormatDialog(context, message),
                          '公告浏览' => showAnnouncementBrowser(
                            context,
                            controller: announcements,
                          ),
                          '自动公告' => showAnnouncementPopup(
                            context,
                            announcement: announcements.items.first,
                            controller: announcements,
                          ),
                          _ => togglePurchaseAutoRenewDialog(
                            context,
                            auth: auth,
                            purchaseId: 1,
                            enable: true,
                          ),
                        }),
                        child: const Text('打开弹窗'),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.tap(find.text('打开弹窗'));
            await tester.pumpAndSettle();
            final Finder dialog = find.byType(AppAlertDialog);
            final Rect bounds = tester.getRect(
              find
                  .descendant(
                    of: find.byType(Dialog),
                    matching: find.byType(Material),
                  )
                  .first,
            );
            final Finder body = switch (kind) {
              '配置格式错误' => find.text(message),
              '续费确认' => find.text('开启后将在套餐到期时自动续费。'),
              _ => find.byType(RichHtmlView),
            };
            final Rect content = tester.getRect(body);
            expect(
              bounds.right - content.right,
              closeTo(content.left - bounds.left, 0.01),
              reason: '正文不能叠加内层滚动容器的不对称留白',
            );
            if (textScale == 1) expect(content.left - bounds.left, 24);
            final Finder paragraphs = find.descendant(
              of: body,
              matching: find.byType(RichText),
            );
            expect(paragraphs, findsWidgets);
            for (final Element element in paragraphs.evaluate()) {
              final RenderParagraph paragraph =
                  element.findRenderObject()! as RenderParagraph;
              if (paragraph.text
                  .toPlainText()
                  .replaceAll('\uFFFC', '')
                  .trim()
                  .isNotEmpty) {
                expect(paragraph.textAlign, TextAlign.justify);
                final String text = paragraph.text.toPlainText();
                final List<TextBox> lines = paragraph.getBoxesForSelection(
                  TextSelection(baseOffset: 0, extentOffset: text.length),
                );
                if (!text.contains('\n') && lines.length > 1) {
                  expect(lines.first.left, closeTo(0, 0.5));
                  expect(
                    lines.first.right,
                    closeTo(paragraph.size.width, 0.5),
                  );
                }
              }
            }
            final Finder scrolls = find.descendant(
              of: dialog,
              matching: find.byType(Scrollable),
            );
            expect(scrolls, findsOneWidget);
            if (kind != '续费确认') {
              expect(
                tester.state<ScrollableState>(scrolls).position.maxScrollExtent,
                greaterThan(0),
              );
            }
            if (kind == '公告浏览') {
              final Finder previous = find.widgetWithText(TextButton, '上一条');
              final Finder next = find.widgetWithText(TextButton, '下一条');
              final Finder count = find.text('1 / 2');
              expect(previous.hitTestable(), findsOneWidget);
              expect(next.hitTestable(), findsOneWidget);
              final Rect previousRect = tester.getRect(previous);
              final Rect nextRect = tester.getRect(next);
              final Rect countRect = tester.getRect(count);
              final ScrollableState scroll = tester.state<ScrollableState>(
                scrolls,
              );
              scroll.position.jumpTo(scroll.position.maxScrollExtent);
              await tester.pumpAndSettle();
              expect(tester.getRect(previous), previousRect);
              expect(tester.getRect(next), nextRect);
              expect(tester.getRect(count), countRect);
              await tester.tap(next);
              await tester.pumpAndSettle();
              expect(find.text('下一条公告'), findsOneWidget);
            }
            await tester.tap(
              find.text(switch (kind) {
                '公告浏览' => '关闭',
                '续费确认' => '取消',
                _ => '我知道了',
              }),
            );
            await tester.pumpAndSettle();
            expect(dialog, findsNothing);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          },
          variant: TargetPlatformVariant(<TargetPlatform>{
            TargetPlatform.windows,
            TargetPlatform.macOS,
            TargetPlatform.linux,
            TargetPlatform.android,
          }),
        );
      }
      testWidgets(
        '套餐弹窗左右留白一致，滚动后控件仍可操作：$size，字号 $textScale，深色 $dark',
        (WidgetTester tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final _Api api = _Api();
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
                theme: dark ? AppTheme.dark() : AppTheme.light(),
                builder: (BuildContext context, Widget? child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(textScale)),
                  child: child!,
                ),
                home: const Scaffold(body: ShopPage()),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('购买'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('购买'));
          await tester.pumpAndSettle();

          final Finder dialog = find.byType(AppAlertDialog);
          expect(dialog, findsOneWidget);
          final Rect bounds = tester.getRect(
            find
                .descendant(
                  of: find.byType(Dialog),
                  matching: find.byType(Material),
                )
                .first,
          );
          final Rect block = tester.getRect(
            find
                .ancestor(
                  of: find.text('流量重置费用'),
                  matching: find.byType(Container),
                )
                .first,
          );
          expect(
            bounds.right - block.right,
            closeTo(block.left - bounds.left, 0.01),
            reason: '正文不能在弹窗内边距之外再叠加右侧滚动条留白',
          );
          if (textScale == 1) expect(block.left - bounds.left, 24);
          if (size.width < 640) {
            final ScrollableState scroll = tester.state<ScrollableState>(
              find
                  .descendant(of: dialog, matching: find.byType(Scrollable))
                  .first,
            );
            expect(scroll.position.maxScrollExtent, greaterThan(0));
          }
          final Finder apply = find.descendant(
            of: dialog,
            matching: find.widgetWithText(OutlinedButton, '应用'),
          );
          await tester.ensureVisible(apply);
          await tester.pumpAndSettle();
          await tester.tap(apply);
          await tester.pumpAndSettle();
          expect(find.text('请输入优惠码'), findsOneWidget);
          final Rect field = tester.getRect(find.byType(TextField));
          expect(
            bounds.right - tester.getRect(apply).right,
            closeTo(field.left - bounds.left, 0.01),
          );
          await tester.ensureVisible(find.byType(Switch));
          await tester.pumpAndSettle();
          await tester.tap(find.byType(Switch));
          await tester.pumpAndSettle();
          expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
          final Finder cancel = find.descendant(
            of: dialog,
            matching: find.widgetWithText(TextButton, '取消'),
          );
          expect(tester.getRect(cancel).bottom, lessThanOrEqualTo(size.height));
          await tester.tap(cancel);
          await tester.pumpAndSettle();
          expect(dialog, findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        variant: TargetPlatformVariant(<TargetPlatform>{
          TargetPlatform.windows,
          TargetPlatform.macOS,
          TargetPlatform.linux,
          TargetPlatform.android,
        }),
      );
    }
  }
}
