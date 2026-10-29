import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:ecycloud_client/data/models/account.dart';
import 'package:ecycloud_client/data/models/user_profile.dart';
import 'package:ecycloud_client/data/models/shop.dart';
import 'package:ecycloud_client/data/models/ticket.dart';
import 'package:ecycloud_client/core/logger.dart';
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/domain/kernel/kernel_controller.dart';
import 'package:ecycloud_client/ui/shell.dart';
import 'package:ecycloud_client/ui/widgets/app_sidebar.dart';
import 'package:ecycloud_client/ui/widgets/app_header.dart';
import 'package:ecycloud_client/ui/pages/devices_page.dart';
import 'package:ecycloud_client/ui/pages/connections_page.dart';
import 'package:ecycloud_client/state/announcement_controller.dart';
import 'package:ecycloud_client/state/auth_controller.dart';
import 'package:ecycloud_client/state/connection_controller.dart';
import 'package:ecycloud_client/state/update_controller.dart';
import 'package:ecycloud_client/ui/app_scope.dart';
import 'package:ecycloud_client/ui/pages/account_page.dart';
import 'package:ecycloud_client/ui/pages/purchases_page.dart';
import 'package:ecycloud_client/ui/pages/unlock_page.dart';
import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/list_toolbar.dart';
import 'package:ecycloud_client/ui/widgets/search_field.dart';
import 'package:ecycloud_client/ui/widgets/section_card.dart';
import 'package:ecycloud_client/ui/widgets/simple_data_table.dart';
import 'package:ecycloud_client/ui/widgets/app_scaffold.dart';
import 'package:ecycloud_client/ui/widgets/app_text_selection.dart';
import 'package:ecycloud_client/ui/widgets/rich_html_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const String _hint = '您可以在这里查看节点的流媒体和各大AI平台解锁情况。';
String _clipboard = '';

class _Auth extends ChangeNotifier implements AuthController {
  _Auth([this.api]);
  @override
  final PanelApiClient? api;
  @override
  bool get busy => false;
  @override
  bool get hasUnreadTicketReply => false;
  @override
  AuthStage get stage => AuthStage.loggedIn;
  @override
  String? get accountKey => null;
  @override
  VoidCallback? onDeviceKickNotice;
  @override
  Future<void> refreshProfile() async {}
  @override
  Future<void> refreshPanelClientAddress() async {}
  @override
  UserProfile? get profile => null;
  @override
  String get siteOrigin => 'https://example.test';
  @override
  Future<AuthOptions?> fetchAuthOptions() async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Platform implements PlatformService {
  @override
  String get platformId => 'windows';
  @override
  bool get supportsTun => true;
  @override
  bool get requiresTun => false;
  @override
  bool get supportsSystemProxy => true;
  @override
  bool get supportsTray => false;
  @override
  bool get supportsLaunchAtLogin => true;
  @override
  bool get supportsPerAppProxy => false;
  @override
  bool get isTelevision => false;
  @override
  Stream<TrayAction> get trayActions => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings implements SettingsStore {
  @override
  AppSettings load() => const AppSettings.defaults();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Kernel implements KernelController {
  @override
  Future<void> bindSession(String cacheKey) async {}

  @override
  Future<void> dispose() async {}
  @override
  Stream<KernelStatus> get statusStream => const Stream.empty();
  @override
  Stream<String> get kernelLog => const Stream.empty();
  @override
  KernelStatus get status => const KernelStatus.stopped();
  @override
  bool get cacheReady => false;
  @override
  bool get upgradable => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Connection extends ConnectionController {
  _Connection({
    required super.platform,
    required super.kernel,
    required super.settingsStore,
    required this.connected,
    this.connectionRows,
  });
  final bool connected;
  final List<Map<String, dynamic>>? connectionRows;
  @override
  ConnectionPhase get state =>
      connected ? ConnectionPhase.connected : super.state;
  @override
  List<Map<String, dynamic>> get connections => connected
      ? connectionRows ??
            [
              for (int i = 1; i <= 3; i++)
                {
                  'metadata': {
                    'host': 'selection$i.example.test',
                    'destinationPort': '443',
                    'network': 'tcp',
                    'process': 'process$i.exe',
                  },
                  'rule': 'DomainSuffix-$i',
                  'chains': ['节点$i'],
                  'upload': 2048 * i,
                  'download': 4096 * i,
                },
            ]
      : super.connections;
}

class _Api implements PanelApiClient {
  @override
  Future<ShopCatalog> fetchShopProducts() async => ShopCatalog.fromJson({
    'money': 98.76,
    'notice': '<p>商店测试说明</p>',
    'default_duration': 30,
    'products': [
      for (int i = 1; i <= 3; i++)
        {
          'id': i,
          'name': '测试商品$i',
          'type': 'plan',
          'price': '12.34',
          'class_expire': 30,
          'in_stock': true,
          'description': '<p>套餐使用说明$i</p>',
        },
    ],
  });
  @override
  Future<InviteSummary> fetchInviteSummary({
    int invitedPage = 1,
    int invitedLength = 10,
    String invitedSearch = '',
    int paybackPage = 1,
    int paybackLength = 10,
    String paybackSearch = '',
    int withdrawPage = 1,
    int withdrawLength = 10,
    String withdrawSearch = '',
  }) async => InviteSummary.fromJson({
    'code': 'INVITE-TEST',
    'invite_url': 'https://example.test/invite/TEST',
    'code_payback': 0.25,
    'rebate_frequency_limit': 100,
  });
  @override
  Future<TicketListPage> fetchTickets({
    int page = 1,
    int length = 10,
    String search = '',
  }) async => TicketListPage.fromJson({});
  @override
  Future<UnlockListPage> fetchUnlockResults({
    int page = 1,
    int length = 10,
    String search = '',
  }) async => UnlockListPage.fromJson({
    'total': 1,
    'results': [
      {
        'node_name': '解锁测试节点',
        'unlock_item': {'DisneyPlus': 'Yes (DE)', 'TikTok': 'Yes (DE)'},
      },
    ],
  });
  @override
  DeviceInfo get device => const DeviceInfo(
    platform: 'windows',
    deviceId: 'self',
    deviceName: 'device',
    deviceModel: 'model',
    osVersion: 'Windows',
    appVersion: '1.0',
  );
  @override
  Future<PurchaseListPage> fetchPurchases({
    int page = 1,
    int length = 10,
    String search = '',
  }) async => PurchaseListPage.fromJson({
    'total': 2,
    'purchases': [
      for (int i = 1; i <= 2; i++)
        {
          'id': i,
          'order_no': 'P-100$i',
          'shop_name': '月付套餐$i',
          'price': 12.34,
          'content': '<p>商品详情$i</p><p>第二行详情</p><p>第三行详情</p><p>第四行详情</p>',
          'datetime': '2026-09-0$i 12:34:56',
          'exp_time': '2026-10-0$i 12:34:56',
          'can_toggle': true,
          'auto_renew': false,
        },
    ],
  });
  @override
  Future<DeviceListPage> fetchDevices({
    int page = 1,
    int length = 10,
    String search = '',
  }) async => DeviceListPage.fromJson({
    'total': 2,
    'items': [
      for (int i = 1; i <= 2; i++)
        {
          'device_id': i == 1 ? 'self' : 'other',
          'device': 'Windows 设备$i',
          'ip': '192.0.2.$i',
          'location': '设备位置$i',
          'online': true,
          'datetime': '2026-09-0$i 12:34:56',
          'app_version': '1.0.$i',
        },
    ],
  });
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _dragSelect(WidgetTester tester, Finder text) async {
  final paragraph = _paragraph(tester, text);
  final Rect box = paragraph
      .getBoxesForSelection(
        TextSelection(
          baseOffset: 0,
          extentOffset: paragraph.text.toPlainText().length,
        ),
      )
      .first
      .toRect()
      .shift(paragraph.localToGlobal(Offset.zero));
  final TestGesture gesture = await tester.startGesture(
    Offset(box.left + 2, box.center.dy),
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump(const Duration(milliseconds: 300));
  await gesture.moveTo(Offset(box.right - 2, box.center.dy));
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

bool _selected(WidgetTester tester, Finder text) {
  final RenderParagraph para = _paragraph(tester, text);
  return para.selections.any((TextSelection s) => s.isValid && !s.isCollapsed);
}

RenderParagraph _paragraph(WidgetTester tester, Finder text) =>
    tester.renderObject<RenderParagraph>(
      tester.widget(text) is RichText
          ? text
          : find.descendant(
              of: text,
              matching: find.byType(RichText, skipOffstage: false),
              skipOffstage: false,
            ),
    );

Future<void> _pump(
  WidgetTester tester,
  Widget page, {
  PanelApiClient? api,
  bool shell = false,
  double width = 1400,
  bool dark = false,
  bool connected = false,
  List<Map<String, dynamic>>? connectionRows,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final _Auth auth = _Auth(api);
  addTearDown(auth.dispose);
  final platform = _Platform();
  final settings = _Settings();
  final connection = _Connection(
    platform: platform,
    kernel: _Kernel(),
    settingsStore: settings,
    connected: connected,
    connectionRows: connectionRows,
  );
  final announcements = AnnouncementController();
  final update = UpdateController(connection: connection, platform: platform);
  addTearDown(connection.dispose);
  addTearDown(announcements.dispose);
  addTearDown(update.dispose);
  await tester.pumpWidget(
    AppScope(
      auth: auth,
      connection: connection,
      announcements: announcements,
      update: update,
      platform: platform,
      settingsStore: settings,
      child: MaterialApp(
        theme: (dark ? AppTheme.dark() : AppTheme.light()).copyWith(
          platform: TargetPlatform.windows,
        ),
        home: shell ? page : AppScaffold(body: page),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _expectSelectable(WidgetTester tester, Finder text) async {
  expect(text, findsOneWidget);
  await tester.ensureVisible(text);
  await tester.pump(const Duration(milliseconds: 100));
  await _dragSelect(tester, text);
  expect(_selected(tester, text), isTrue, reason: text.toString());
  await _expectCopy(tester, text);
}

Future<void> _expectCopy(WidgetTester tester, Finder text) async {
  final paragraph = _paragraph(tester, text);
  final expected = paragraph.selections
      .where((selection) => selection.isValid && !selection.isCollapsed)
      .map((selection) => selection.textInside(paragraph.text.toPlainText()))
      .join();
  final selectionBox = paragraph
      .getBoxesForSelection(paragraph.selections.first)
      .first
      .toRect();
  final rightClick = await tester.startGesture(
    paragraph.localToGlobal(selectionBox.center),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await tester.pump(const Duration(milliseconds: 300));
  await rightClick.up();
  await tester.pump();
  expect(find.text('Select all'), findsNothing);
  expect(find.text('Copy'), findsOneWidget, reason: text.toString());
  await tester.tap(find.text('Copy'), kind: PointerDeviceKind.mouse);
  await tester.pump();
  expect(_clipboard, expected, reason: '复制不得夹带相邻单元格或隐藏页面的文字：$text');
}

void main() {
  for (final double width in <double>[390, 1400]) {
    for (final bool dark in <bool>[false, true]) {
      testWidgets('连接滚动后筛选与搜索固定：$width，深色 $dark', (tester) async {
        await _pump(
          tester,
          const ConnectionsPage(),
          connected: true,
          connectionRows: <Map<String, dynamic>>[
            for (int i = 1; i <= 80; i++)
              <String, dynamic>{
                'metadata': <String, String>{
                  'host': 'selection$i.example.test',
                  'destinationPort': '443',
                },
              },
          ],
          width: width,
          dark: dark,
        );
        await tester.pumpAndSettle();
        final Finder filter = find.byWidgetPredicate(
          (widget) => widget is SegmentedButton,
        );
        final Finder search = find.byType(SearchField);
        final Rect filterBefore = tester.getRect(filter);
        final Rect searchBefore = tester.getRect(search);
        final Rect cardBounds = tester.getRect(
          find
              .ancestor(
                of: find.text('selection1.example.test:443'),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(cardBounds.right, searchBefore.right);
        final ScrollableState scroll = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
        await tester.pumpAndSettle();
        expect(scroll.position.pixels, greaterThan(0));
        expect(tester.getRect(filter), filterBefore);
        expect(tester.getRect(search), searchBefore);
        await tester.enterText(
          find.byType(TextField),
          'selection80.example.test',
        );
        await tester.pumpAndSettle();
        expect(find.text('selection80.example.test:443'), findsOneWidget);
        await tester.tap(find.text('已关闭 0'));
        await tester.pumpAndSettle();
        expect(find.text('没有符合条件的连接'), findsOneWidget);
        expect(tester.getRect(filter).topLeft, filterBefore.topLeft);
        expect(tester.getRect(search).top, searchBefore.top);
        expect(tester.takeException(), isNull);
      });
    }
  }
  setUp(() {
    _clipboard = '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            _clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
  });
  testWidgets('真实外壳内商店和解锁的正文可选', (tester) async {
    await _pump(tester, const Shell(), shell: true);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(
      find.descendant(of: find.byType(AppSidebar), matching: find.text('商店')),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await _expectSelectable(tester, find.text('暂无商品'));
    await tester.tap(
      find.descendant(of: find.byType(AppSidebar), matching: find.text('解锁')),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await _expectSelectable(tester, find.text(_hint));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final dark in [false, true]) {
    testWidgets('真实外壳所有问题页面拖选并右键复制：深色 $dark', (tester) async {
      Logger.instance.info('测试', '日志选区回归内容 $dark');
      await _pump(
        tester,
        const Shell(),
        shell: true,
        api: _Api(),
        dark: dark,
        connected: true,
      );
      await tester.pump(const Duration(milliseconds: 500));
      for (final entry in <String, List<String>>{
        '商店': ['当前余额', '¥ 98.76', '测试商品1', '测试商品2', '测试商品3'],
        '连接': [
          'selection1.example.test:443',
          'process1.exe',
          'DomainSuffix-1',
          'selection2.example.test:443',
        ],
        '日志': ['日志选区回归内容 $dark'],
        '设置': ['开机自启', '启动后自动连接', '日志落盘级别', '储存路径'],
        '邀请': [
          '邀请信息',
          '邀请他人注册时，请将以下链接发送给被邀请者',
          'INVITE-TEST',
          'https://example.test/invite/TEST',
          '返利比例',
        ],
        '解锁': [_hint],
        '节点': ['面板未下发节点分组'],
      }.entries) {
        await tester.tap(
          find.descendant(
            of: find.byType(AppSidebar),
            matching: find.text(entry.key),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await _expectSelectable(
          tester,
          find
              .descendant(
                of: find.byType(AppHeader),
                matching: find.byType(Text),
              )
              .first,
        );
        for (final label in entry.value) {
          await _expectSelectable(tester, find.text(label).first);
        }
        if (entry.key == '商店') {
          await _expectSelectable(tester, _richText('商店测试说明'));
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final width in [1400.0, 1000.0, 390.0]) {
    for (final page in <(String, Widget, String, String)>[
      ('解锁检测', const UnlockPage(), 'Yes (DE)', 'Yes (DE)'),
      ('购买记录', const PurchasesPage(), 'P-1001', '月付套餐1'),
      ('在线客户端', const DevicesPage(), 'Windows 设备1', '192.0.2.1'),
    ]) {
      testWidgets('${page.$1}切换选区后清除旧高亮：宽度 $width', (tester) async {
        await _pump(tester, page.$2, api: _Api(), width: width);
        await tester.pumpAndSettle();
        final first = find.text(page.$3).first;
        final second = find.text(page.$4).last;
        final mouse = await tester.createGesture(
          pointer: 42,
          kind: PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        for (final clicks in [1, 2, 3]) {
          for (final target in [first, second]) {
            await tester.ensureVisible(target);
            await tester.pump(
              kDoubleTapTimeout + const Duration(milliseconds: 10),
            );
            if (clicks == 1) {
              await _dragSelect(tester, target);
            } else {
              final paragraph = _paragraph(tester, target);
              final box = paragraph
                  .getBoxesForSelection(
                    TextSelection(
                      baseOffset: 0,
                      extentOffset: paragraph.text.toPlainText().length,
                    ),
                  )
                  .first
                  .toRect();
              final at = paragraph.localToGlobal(
                box.centerLeft + const Offset(3, 0),
              );
              await mouse.moveTo(at);
              for (var i = 0; i < clicks; i++) {
                await mouse.down(at);
                await tester.pump(const Duration(milliseconds: 50));
                await mouse.up();
                await tester.pump(const Duration(milliseconds: 50));
              }
            }
            expect(
              _selected(tester, target),
              isTrue,
              reason: '$clicks 击：$target',
            );
          }
          expect(
            _selected(tester, first),
            isFalse,
            reason: '$clicks 击切换后旧选区必须清除',
          );
          await _expectCopy(tester, second);
        }
      }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
    }

    testWidgets('购买记录有数据时各列可选：宽度 $width', (tester) async {
      await _pump(tester, const PurchasesPage(), api: _Api(), width: width);
      await tester.pumpAndSettle();
      for (final label in [
        'P-1001',
        '月付套餐1',
        '2026-09-01 12:34:56',
        '2026-10-01 12:34:56',
        'P-1002',
      ]) {
        await _expectSelectable(tester, find.text(label));
      }
      await _expectSelectable(tester, find.text('订单号').first);
      await _expectSelectable(tester, find.text('¥ 12.34').first);
      await _expectSelectable(tester, _richText('商品详情1'));
      await tester.ensureVisible(find.text('查看详情').first);
      await tester.tap(find.text('查看详情').first);
      await tester.pumpAndSettle();
      await _expectSelectable(tester, _richText('第四行详情').first);
    });

    testWidgets('在线客户端设备名称和当前设备标签可选：宽度 $width', (tester) async {
      await _pump(tester, const DevicesPage(), api: _Api(), width: width);
      await tester.pumpAndSettle();
      for (final label in [
        'Windows 设备1',
        '当前设备',
        '192.0.2.1',
        '设备位置1',
        '1.0.1',
        '2026-09-01 12:34:56',
        'Windows 设备2',
      ]) {
        await _expectSelectable(tester, find.text(label));
      }
    });
  }

  testWidgets('常驻页面切换后只选择当前页面正文', (tester) async {
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);
    await _pump(
      tester,
      ValueListenableBuilder<int>(
        valueListenable: index,
        builder: (context, value, _) => IndexedStack(
          index: value,
          children: const [
            AppTextSelection(child: Center(child: Text('hidden page content'))),
            AppTextSelection(
              child: Center(child: Text('visible page content')),
            ),
          ],
        ),
      ),
    );
    await _dragSelect(tester, find.text('hidden page content'));
    expect(_selected(tester, find.text('hidden page content')), isTrue);
    index.value = 1;
    await tester.pump();
    await _expectSelectable(tester, find.text('visible page content'));
    expect(
      _selected(tester, find.text('hidden page content', skipOffstage: false)),
      isFalse,
    );
  });

  testWidgets('解锁检测页的说明文字可以拖选', (tester) async {
    await _pump(tester, const Scaffold(body: UnlockPage()));
    await _expectSelectable(tester, find.text(_hint));
  });

  testWidgets('账户信息页的条目文字可以拖选', (tester) async {
    await _pump(tester, const AccountPage());
    await _expectSelectable(tester, find.text('修改信息'));
  });

  testWidgets('购买记录页空表文案可以拖选', (tester) async {
    await _pump(tester, const PurchasesPage());
    await _expectSelectable(tester, find.text('暂无购买记录'));
  });

  testWidgets('工具条加宽表时单元格可以拖选', (tester) async {
    await _pump(
      tester,
      Scaffold(
        body: ListView(
          children: <Widget>[
            ListToolbar(
              currentPage: 1,
              lastPage: 1,
              total: 1,
              searchHint: '订单号 / 商品名',
              onSearchChanged: (_) {},
              onPageChanged: (_) {},
            ),
            const SimpleDataTable(
              minWidth: 1280,
              columns: <String>['订单号', '商品名称'],
              rows: <List<Widget>>[
                <Widget>[TableText('P-1001'), TableText('月付套餐')],
              ],
            ),
          ],
        ),
      ),
    );
    await _expectSelectable(tester, find.text('月付套餐'));
    await _expectSelectable(tester, find.text('P-1001'));
  });

  testWidgets('列表工具条不得截走正文的拖选', (tester) async {
    await _pump(
      tester,
      Scaffold(
        body: ListView(
          children: <Widget>[
            ListToolbar(
              currentPage: 1,
              lastPage: 1,
              total: 0,
              searchHint: '搜索节点',
              onSearchChanged: (_) {},
              onPageChanged: (_) {},
            ),
            const SectionCard(child: Text(_hint)),
          ],
        ),
      ),
    );
    await _expectSelectable(tester, find.text(_hint));
  });

  testWidgets('宽表的单元格与表外正文都可以拖选', (tester) async {
    await _pump(
      tester,
      Scaffold(
        body: ListView(
          children: const <Widget>[
            SectionCard(child: Text(_hint)),
            SimpleDataTable(
              minWidth: 1280,
              columns: <String>['节点', 'Netflix'],
              rows: <List<Widget>>[
                <Widget>[TableText('香港 01', bold: true), TableText('Yes (DE)')],
              ],
            ),
          ],
        ),
      ),
    );
    await _expectSelectable(tester, find.text('Yes (DE)'));
    await _expectSelectable(tester, find.text(_hint));
  });

  testWidgets('外壳选区套住页面选区后，内层仍可拖选', (tester) async {
    await _pump(
      tester,
      AppTextSelection(
        child: const Scaffold(
          body: InfoRow(label: '邮箱', value: 'user@example.com'),
        ),
      ),
    );
    await _expectSelectable(tester, find.text('user@example.com'));
  });

  testWidgets('富文本正文可以拖选', (tester) async {
    await _pump(tester, const RichHtmlView('<p>announcement content</p>'));
    final Finder text = find.byWidgetPredicate(
      (widget) =>
          widget is RichText &&
          widget.text.toPlainText() == 'announcement content',
    );
    expect(text, findsOneWidget);
    await _dragSelect(tester, text);
    final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
      text,
    );
    expect(
      paragraph.selections.any((selection) => !selection.isCollapsed),
      isTrue,
    );
  });
}

Finder _richText(String text) => find.byWidgetPredicate(
  (widget) => widget is RichText && widget.text.toPlainText() == text,
);
