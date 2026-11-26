import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ecycloud_client/core/logger.dart';
import 'package:ecycloud_client/data/models/user_profile.dart';
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:ecycloud_client/data/store/traffic_rank_store.dart';
import 'package:ecycloud_client/domain/kernel/clash_api_client.dart';
import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/l10n/app_language.dart';
import 'package:ecycloud_client/l10n/l10n.dart';
import 'package:ecycloud_client/state/announcement_controller.dart';
import 'package:ecycloud_client/state/auth_controller.dart';
import 'package:ecycloud_client/state/connection_controller.dart';
import 'package:ecycloud_client/state/update_controller.dart';
import 'package:ecycloud_client/ui/app_scope.dart';
import 'package:ecycloud_client/ui/pages/home_page.dart';
import 'package:ecycloud_client/ui/pages/logs_page.dart';
import 'package:ecycloud_client/ui/pages/nodes_page.dart';
import 'package:ecycloud_client/ui/node_labels.dart';
import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/app_header.dart';
import 'package:ecycloud_client/ui/widgets/app_text_selection.dart';
import 'package:ecycloud_client/ui/widgets/connection_status_badge.dart';
import 'package:ecycloud_client/ui/widgets/page_header.dart';
import 'package:ecycloud_client/ui/widgets/section_card.dart';
import 'package:ecycloud_client/ui/widgets/user_avatar.dart';

void main() {
  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.android,
  ]) {
    for (final bool dark in <bool>[false, true]) {
      testWidgets('$platform 首页按钮和背景对齐、排行选择复制与点击滚动收起，深色 $dark', (
        WidgetTester tester,
      ) async {
        final bool touch = platform == TargetPlatform.android;
        tester.view.physicalSize = touch
            ? const Size(390, 700)
            : const Size(900, 500);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final _Auth auth = _Auth();
        final _Connection connection = _Connection();
        final AnnouncementController announcements = AnnouncementController();
        final ShellChromeBar chrome = ShellChromeBar();
        addTearDown(auth.dispose);
        addTearDown(connection.dispose);
        addTearDown(announcements.dispose);
        addTearDown(chrome.dispose);
        await tester.pumpWidget(
          AppScope(
            auth: auth,
            connection: connection,
            announcements: announcements,
            update: _Update(),
            platform: _Platform(),
            settingsStore: _Settings(),
            child: MaterialApp(
              // 主题是 static final，首次创建时的平台决定触控补边；这里按真机运行时的默认值补齐
              theme: (dark ? AppTheme.dark() : AppTheme.light()).copyWith(
                platform: platform,
                materialTapTargetSize: touch
                    ? MaterialTapTargetSize.padded
                    : MaterialTapTargetSize.shrinkWrap,
              ),
              home: Scaffold(
                body: Stack(
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.only(
                        top: AppTheme.headerHeight,
                      ),
                      child: AppTextSelection(
                        child: ShellChrome(
                          active: true,
                          bar: chrome,
                          child: const HomePage(),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: AppHeader(bar: chrome),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final Finder bell = find.byIcon(Icons.notifications_outlined);
        final Finder refresh = find.byIcon(Icons.refresh).first;
        final Rect bellBounds = tester.getRect(bell);
        final Rect avatarBounds = tester.getRect(find.byType(UserAvatarButton));
        expect(bellBounds.size, tester.getSize(refresh));
        expect(
          tester.getSize(
            find.ancestor(of: bell, matching: find.byType(IconButton)).first,
          ),
          tester.getSize(
            find.ancestor(of: refresh, matching: find.byType(IconButton)).first,
          ),
        );
        expect(bellBounds.center.dy, closeTo(avatarBounds.center.dy, 0.1));
        expect(bellBounds.right, lessThan(avatarBounds.left));
        const String message =
            '统计数据仅储存于本地，只保留最近两天的数据，只统计当前设备的流量使用，不同设备之间的流量数据不同步。';
        final Finder icon = find.byWidgetPredicate(
          (widget) =>
              widget is Icon &&
              widget.icon == Icons.error_outline &&
              widget.semanticLabel == message,
        );
        await tester.ensureVisible(icon);
        await tester.pump();
        final Rect titleBounds = tester.getRect(find.text('流量排行'));
        final Rect iconBounds = tester.getRect(icon);
        expect(iconBounds.top, closeTo(titleBounds.top, 0.1));
        expect(
          iconBounds.left,
          // 触控端也按桌面端按钮盒排版，标题与图标的间距两端一致
          closeTo(
            titleBounds.right + (AppTheme.pointerTapTarget - 14) / 2,
            0.1,
          ),
        );
        expect(iconBounds.size, const Size.square(14));
        final Finder button = find
            .ancestor(of: icon, matching: find.byType(IconButton))
            .first;
        expect(tester.getSize(button), Size.square(AppTheme.minTapTarget));
        final Rect inkBounds = tester.getRect(
          find
              .descendant(
                of: button,
                matching: find.byWidgetPredicate(
                  (Widget widget) => widget is InkResponse,
                ),
              )
              .first,
        );
        // 按压轮廓两端都是 32，触控端只把点击范围补到 48
        expect(inkBounds.size, const Size.square(AppTheme.pointerTapTarget));
        expect(inkBounds.center.dx, closeTo(iconBounds.center.dx, 0.1));
        expect(inkBounds.center.dy, closeTo(iconBounds.center.dy, 0.1));
        final Finder cardFinder = find
            .ancestor(of: icon, matching: find.byType(SectionCard))
            .first;
        final SectionCard card = tester.widget<SectionCard>(cardFinder);
        expect(card.title, '流量排行');
        expect(card.titleTrailing, isNotNull);
        expect(card.action, isNull);
        final Rect cardBounds = tester.getRect(cardFinder);
        final Finder connectionBadge = find.byType(ConnectionStatusBadge);
        final Finder connectionCard = find
            .ancestor(of: connectionBadge, matching: find.byType(Card))
            .first;
        final Finder connectButton = find
            .descendant(
              of: connectionCard,
              matching: find.byWidgetPredicate(
                (Widget widget) => widget is FilledButton,
              ),
            )
            .first;
        expect(
          tester.getRect(connectionBadge).left,
          closeTo(cardBounds.left + 24, 0.1),
        );
        if (touch) {
          final Rect modeBounds = tester.getRect(
            find.byType(SegmentedButton<String>).first,
          );
          expect(
            modeBounds.expandToInclude(tester.getRect(connectButton)).center.dx,
            closeTo(cardBounds.center.dx, 0.1),
          );
        } else {
          expect(
            tester.getRect(connectButton).right,
            closeTo(cardBounds.right - 24, 0.1),
          );
        }
        final ScrollController controller = tester
            .widget<SingleChildScrollView>(
              find.byType(SingleChildScrollView).first,
            )
            .controller!;
        controller.jumpTo(controller.offset - 40);
        await tester.pump();
        await tester.tap(icon);
        await tester.pumpAndSettle();
        expect(find.text(message), findsOneWidget);
        expect(
          tester.getRect(find.text(message)).top,
          greaterThan(tester.getRect(icon).bottom),
        );
        await tester.tap(icon);
        await tester.pumpAndSettle();
        expect(find.text(message), findsNothing);
        await tester.tap(icon);
        await tester.pumpAndSettle();
        await tester.tapAt(
          tester.getTopLeft(find.text(message)) + const Offset(10, 5),
        );
        await tester.pumpAndSettle();
        expect(find.text(message), findsOneWidget);
        if (touch) {
          String? copied;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (MethodCall call) async {
              if (call.method == 'Clipboard.setData') {
                copied = (call.arguments as Map)['text'] as String;
              }
              return null;
            },
          );
          addTearDown(() {
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              SystemChannels.platform,
              null,
            );
          });
          await tester.longPressAt(
            tester.getTopLeft(find.text(message)) + const Offset(20, 8),
          );
          await tester.pumpAndSettle();
          expect(find.text(message), findsOneWidget);
          await tester.tap(find.text('Copy'));
          await tester.pumpAndSettle();
          expect(copied, isNotEmpty);
          expect(message, contains(copied!));
          expect(find.text(message), findsOneWidget);
          await tester.tap(find.text('流量排行'));
          await tester.pumpAndSettle();
          expect(find.text(message), findsNothing);
          await tester.tap(icon);
          await tester.pumpAndSettle();
        }
        await tester.tapAt(Offset(tester.view.physicalSize.width - 2, 20));
        await tester.pumpAndSettle();
        expect(find.text(message), findsNothing);
        for (final double delta in <double>[20, -20]) {
          await tester.tap(icon);
          await tester.pumpAndSettle();
          expect(find.text(message), findsOneWidget);
          if (!touch) {
            await tester.sendEventToBinding(
              PointerScrollEvent(
                position: tester.getCenter(icon),
                scrollDelta: Offset(0, delta),
              ),
            );
          } else {
            await tester.timedDragFrom(
              Offset(tester.view.physicalSize.width - 2, 350),
              Offset(0, -delta),
              const Duration(milliseconds: 100),
            );
          }
          await tester.pumpAndSettle();
          expect(find.text(message), findsNothing);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }, variant: TargetPlatformVariant(<TargetPlatform>{platform}));
    }
  }
  for (final language in [AppLanguage.en, AppLanguage.zhTW]) {
    for (final narrow in [false, true]) {
      testWidgets(
        '实际首页和节点页翻译 ${language.name} 窄屏 $narrow',
        (tester) async {
          final previous = L10n.current;
          L10n.current = language;
          addTearDown(() => L10n.current = previous);
          tester.view.physicalSize = narrow
              ? const Size(390, 844)
              : const Size(1100, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final profile = UserProfile.fromJson({
            'id': 1,
            'class': 1,
            'enable_checkin': true,
            'traffic_reset': '不重置',
            'last_ss_time': '从未使用喵',
            'last_check_in_time': '从未签到',
          });
          final auth = _Auth()..profile = profile;
          final connection = _Connection();
          final announcements = AnnouncementController();
          addTearDown(auth.dispose);
          addTearDown(connection.dispose);
          addTearDown(announcements.dispose);
          Future<void> showPage(Widget page, ConnectionController current) =>
              tester.pumpWidget(
                AppScope(
                  auth: auth,
                  connection: current,
                  announcements: announcements,
                  update: _Update(),
                  platform: _Platform(),
                  settingsStore: _Settings(),
                  child: MaterialApp(
                    theme: narrow ? AppTheme.dark() : AppTheme.light(),
                    home: Scaffold(body: page),
                  ),
                ),
              );
          await showPage(const HomePage(), connection);
          await tester.pump();
          expect(find.text(L10n.t('不重置')), findsOneWidget);
          expect(find.text(L10n.t('从未使用喵')), findsOneWidget);
          expect(find.text(L10n.t('从未签到')), findsOneWidget);
          expect(profile.trafficReset, '不重置');
          final notice = language == AppLanguage.en
              ? 'Shows traffic usage across all devices.'
              : '統計所有裝置的流量使用情況';
          final usageHelp = find.byWidgetPredicate(
            (widget) =>
                widget is Icon &&
                widget.icon == Icons.error_outline &&
                widget.semanticLabel == notice,
          );
          await tester.ensureVisible(usageHelp);
          await tester.pumpAndSettle();
          await tester.tap(usageHelp);
          await tester.pumpAndSettle();
          expect(find.text(notice), findsOneWidget);
          // 与流量排行的提示一样出在图标下方，不压住同一行的流量明细按钮
          final Rect noticeBounds = tester.getRect(find.text(notice));
          expect(
            noticeBounds.top,
            greaterThan(tester.getRect(usageHelp).bottom),
          );
          expect(
            noticeBounds.overlaps(
              tester.getRect(find.textContaining(L10n.t('流量明细'))),
            ),
            isFalse,
          );
          await tester.tap(usageHelp);
          await tester.pumpAndSettle();
          expect(find.text(notice), findsNothing);
          expect(tester.takeException(), isNull);
          final nodes = _NodeConnection();
          addTearDown(nodes.dispose);
          addTearDown(() => NodeLabels.configure(''));
          final label = language == AppLanguage.en ? 'Main nodes' : '主節點';
          NodeLabels.configure(
            '',
            {'node-1': 'Fixture A', 'node-2': 'Fixture B'},
            {'主节点': label},
          );
          await showPage(const NodesPage(), nodes);
          await tester.pump();
          expect(find.text(label), findsOneWidget);
          expect(find.text('主节点'), findsNothing);
          expect(find.textContaining('Fixture A'), findsWidgets);
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Fixture B'));
          await tester.pump();
          expect(nodes.selected, ('主节点', 'node-2'));
          expect(tester.takeException(), isNull);
          Logger.instance.info('kernel', 'Match using 主节点[node-1]');
          await showPage(const LogsPage(), nodes);
          await tester.pump();
          expect(find.text('Match using $label[Fixture A]'), findsWidgets);
          expect(find.textContaining('Match using 主节点['), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        variant: TargetPlatformVariant({
          narrow ? TargetPlatform.android : TargetPlatform.windows,
        }),
      );
    }
  }

  Future<_PagedConnection> showPagedNodes(
    WidgetTester tester,
    Size size,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final auth = _Auth();
    final connection = _PagedConnection();
    final announcements = AnnouncementController();
    addTearDown(auth.dispose);
    addTearDown(connection.dispose);
    addTearDown(announcements.dispose);
    await tester.pumpWidget(
      AppScope(
        auth: auth,
        connection: connection,
        announcements: announcements,
        update: _Update(),
        platform: _Platform(),
        settingsStore: _Settings(),
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: NodesPage()),
        ),
      ),
    );
    await tester.pump();
    return connection;
  }

  // 修复前：取到一页后列表变长，为算滚动条会把新增的行连同末尾那一行预先量一遍，
  // 以「构建到末尾一行」为准就会不等滚动一页接一页取到底
  // 与 OpenWrt 首页同一阈值：令牌剩余 7 天以内才在连接卡片下方提示
  testWidgets('登录令牌 7 天内到期时首页提示到期时间，更晚到期不提示', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _Auth auth = _Auth();
    final _Connection connection = _Connection();
    final AnnouncementController announcements = AnnouncementController();
    addTearDown(auth.dispose);
    addTearDown(connection.dispose);
    addTearDown(announcements.dispose);
    Future<void> pumpHome(DateTime? expiresAt) async {
      auth.sessionExpiresAt = expiresAt;
      await tester.pumpWidget(
        AppScope(
          auth: auth,
          connection: connection,
          announcements: announcements,
          update: _Update(),
          platform: _Platform(),
          settingsStore: _Settings(),
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: HomePage()),
          ),
        ),
      );
      await tester.pump();
    }

    final DateTime soon = DateTime.now().add(const Duration(days: 2));
    await pumpHome(soon.toUtc());
    final String local = soon.toLocal().toIso8601String();
    expect(
      find.text(
        '登录将于 ${local.substring(0, 10)} ${local.substring(11, 19)} 到期，到期后连接会断开，请在此之前退出并重新登录。',
      ),
      findsOneWidget,
    );

    await pumpHome(DateTime.now().add(const Duration(days: 30)));
    expect(find.textContaining('到期，到期后连接会断开'), findsNothing);
    await pumpHome(null);
    expect(find.textContaining('到期，到期后连接会断开'), findsNothing);
  });

  testWidgets('节点页只在滚到分组末尾时向面板取下一页', (WidgetTester tester) async {
    final _PagedConnection connection = await showPagedNodes(
      tester,
      const Size(390, 844),
    );
    await tester.tap(find.text('主节点'));
    for (int frame = 0; frame < 200; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(connection.loads, isEmpty);

    final ScrollPosition position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    for (int step = 0; step < 40 && connection.loads.isEmpty; step++) {
      position.jumpTo(position.maxScrollExtent);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(connection.loads, <String>['']);
    for (int frame = 0; frame < 800; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(connection.loads, <String>['']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('分组还有未列出的成员时，停止输入 400 毫秒后才向面板搜索', (WidgetTester tester) async {
    final _PagedConnection connection = await showPagedNodes(
      tester,
      const Size(1100, 800),
    );
    await tester.tap(find.byTooltip('搜索节点名称'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Ab');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.enterText(find.byType(TextField), 'Abc ');
    await tester.pump(const Duration(milliseconds: 350));
    expect(connection.loads, isEmpty);
    await tester.pump(const Duration(milliseconds: 100));
    expect(connection.loads, <String>['abc']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _Auth extends ChangeNotifier implements AuthController {
  @override
  String get siteOrigin => 'https://example.invalid';
  @override
  UserProfile? profile;
  @override
  DateTime? sessionExpiresAt;
  @override
  Future<void> refreshProfile() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Connection extends ChangeNotifier implements ConnectionController {
  @override
  Listenable get statsUpdates => this;
  @override
  List<String> get preflightProblems => <String>[];
  @override
  ConnectionPhase get state => ConnectionPhase.disconnected;
  @override
  String get routeMode => 'rule';
  @override
  List<ProxyGroup> get groupsForMode => <ProxyGroup>[];
  @override
  AppSettings get settings => const AppSettings.defaults();
  @override
  TrafficSample get traffic => const TrafficSample(0, 0);
  @override
  TrafficSample get trafficTotal => const TrafficSample(0, 0);
  @override
  List<TrafficSample> get trafficHistory => <TrafficSample>[];
  @override
  KernelStats get stats => KernelStats.empty;
  @override
  List<TrafficRankRow> trafficRankGroups(TrafficRankDay day) =>
      <TrafficRankRow>[];
  @override
  List<TrafficRankRow> trafficRankHosts(TrafficRankDay day) =>
      <TrafficRankRow>[];
  @override
  List<Map<String, dynamic>> get connections => const <Map<String, dynamic>>[];
  @override
  List<Map<String, dynamic>> get closedConnections =>
      const <Map<String, dynamic>>[];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NodeConnection extends _Connection {
  (String, String)? selected;
  @override
  List<ProxyGroup> get groupsForMode => const [
    ProxyGroup(
      name: '主节点',
      type: 'Selector',
      now: 'node-1',
      members: ['node-1', 'node-2'],
    ),
  ];
  @override
  bool get controlPlaneReady => true;
  @override
  Future<void> selectProxy(String group, String member) async =>
      selected = (group, member);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      switch (invocation.memberName) {
        #testingGroups ||
        #testingSpeedGroups ||
        #testingNodes ||
        #unreachableNodes ||
        #testingSpeedNodes ||
        #speedFailedNodes => <String>{},
        #delayOf || #speedOf => 0,
        #resolveNode => invocation.positionalArguments.first,
        #typeOf || #networkOf || #tlsOf || #udpOf => '',
        #groupByName || #groupIconOf || #nodesErrorOf => null,
        #loadingNodes || #hasMoreNodes || #nodeMatched => false,
        #memberTotalOf =>
          (invocation.positionalArguments.first as ProxyGroup).members.length,
        _ => super.noSuchMethod(invocation),
      };
}

class _PagedConnection extends _NodeConnection {
  final List<String> loads = <String>[];
  int listed = 300;
  @override
  List<ProxyGroup> get groupsForMode => <ProxyGroup>[
    ProxyGroup(
      name: '主节点',
      type: 'Selector',
      now: 'node-1',
      members: <String>[for (int id = 1; id <= listed; id++) 'node-$id'],
    ),
  ];
  @override
  int memberTotalOf(ProxyGroup group) => 5000;
  @override
  bool hasMoreNodes(String group, {String query = ''}) => true;
  bool fetching = false;
  @override
  bool loadingNodes(String group) => fetching;
  // 与控制器一致：一页没取完不再发下一次
  @override
  Future<void> loadMoreNodes(String group, {String query = ''}) async {
    if (fetching) {
      return;
    }
    loads.add(query);
    if (query.isNotEmpty) {
      return;
    }
    fetching = true;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    listed += 100;
    fetching = false;
    notifyListeners();
  }
}

class _Platform implements PlatformService {
  @override
  bool get isTelevision => false;
  @override
  bool get supportsSystemProxy => false;
  @override
  bool get requiresTun => false;
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
