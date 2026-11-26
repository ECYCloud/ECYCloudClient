import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ecycloud_client/data/models/account.dart';
import 'package:ecycloud_client/data/models/user_profile.dart';
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:ecycloud_client/domain/kernel/clash_api_client.dart';
import 'package:ecycloud_client/domain/kernel/kernel_controller.dart';
import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/state/announcement_controller.dart';
import 'package:ecycloud_client/state/auth_controller.dart';
import 'package:ecycloud_client/state/connection_controller.dart';
import 'package:ecycloud_client/state/update_controller.dart';
import 'package:ecycloud_client/ui/app_scope.dart';
import 'package:ecycloud_client/ui/format.dart';
import 'package:ecycloud_client/ui/pages/connections_page.dart';
import 'package:ecycloud_client/ui/pages/home_page.dart';
import 'package:ecycloud_client/ui/pages/logs_page.dart';
import 'package:ecycloud_client/ui/pages/nodes_page.dart';
import 'package:ecycloud_client/ui/pages/settings_page.dart';
import 'package:ecycloud_client/ui/shell.dart';
import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/app_sidebar.dart';
import 'package:ecycloud_client/ui/widgets/page_header.dart';

void main() {
  late List<Element> rebuilt;

  setUp(() {
    rebuilt = <Element>[];
    debugOnRebuildDirtyWidget = (Element element, bool _) =>
        rebuilt.add(element);
  });
  tearDown(() => debugOnRebuildDirtyWidget = null);

  Future<_Connection> pumpShell(
    WidgetTester tester, {
    ConnectionPhase? phase,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _Platform platform = _Platform();
    final _Settings settings = _Settings();
    final _Auth auth = _Auth();
    final _Connection connection = _Connection(
      platform: platform,
      kernel: _Kernel(),
      settingsStore: settings,
      phase: phase,
    );
    final AnnouncementController announcements = AnnouncementController();
    final UpdateController update = UpdateController(
      connection: connection,
      platform: platform,
    );
    addTearDown(auth.dispose);
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
          theme: AppTheme.light().copyWith(platform: TargetPlatform.windows),
          home: const Shell(),
        ),
      ),
    );
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return connection;
  }

  // 只推进时钟不画帧：期间有定时器、动画或监听要求重画，hasScheduledFrame 就会是 true
  Future<int> framesRequested(WidgetTester tester, {int seconds = 5}) async {
    int requested = 0;
    for (int second = 0; second < seconds; second++) {
      await tester.binding.delayed(const Duration(seconds: 1));
      if (tester.binding.hasScheduledFrame) {
        requested++;
      }
      await tester.pump();
    }
    return requested;
  }

  bool under<T extends Widget>(Element element) {
    bool found = element.widget is T;
    element.visitAncestorElements((Element ancestor) {
      found = found || ancestor.widget is T;
      return !found;
    });
    return found;
  }

  testWidgets('未连接时首页空闲：不排帧、不重建', (WidgetTester tester) async {
    await pumpShell(tester);
    rebuilt.clear();

    expect(await framesRequested(tester), 0);
    expect(rebuilt, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('切到其它页后，隐藏页不随连接控制器的通知重建', (WidgetTester tester) async {
    final _Connection connection = await pumpShell(tester);
    await tester.tap(
      find.descendant(of: find.byType(AppSidebar), matching: find.text('设置')),
    );
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    rebuilt.clear();

    connection.ping();
    await tester.pump();

    expect(rebuilt.where(under<SettingsPage>), isNotEmpty);
    for (final bool Function(Element) hidden in <bool Function(Element)>[
      under<HomePage>,
      under<NodesPage>,
      under<ConnectionsPage>,
      under<LogsPage>,
    ]) {
      expect(rebuilt.where(hidden), isEmpty);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('连接中切到其它页，首页的转圈动画不再排帧', (WidgetTester tester) async {
    await pumpShell(tester, phase: ConnectionPhase.connecting);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.tap(
      find.descendant(of: find.byType(AppSidebar), matching: find.text('设置')),
    );
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(await framesRequested(tester), 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('已连接时每秒的统计只重建统计卡片，整页与页头不动，每秒只排一帧', (WidgetTester tester) async {
    final _Connection connection = await pumpShell(
      tester,
      phase: ConnectionPhase.connected,
    );
    rebuilt.clear();

    int frames = 0;
    for (int second = 1; second <= 5; second++) {
      connection.sample(TrafficSample(1000 * second, 2000 * second));
      await tester.binding.delayed(const Duration(seconds: 1));
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pump();
      frames++;
      if (tester.binding.hasScheduledFrame) {
        frames++;
        await tester.pump();
      }
      expect(find.text(Format.speed(2000 * second)), findsOneWidget);
    }

    expect(frames, 5);
    expect(rebuilt.where(under<PageHeader>), isEmpty);
    expect(rebuilt.where((Element e) => e.widget is HomePage), isEmpty);
    expect(rebuilt.where(under<HomePage>), isNotEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('统计每秒刷新时，隐藏的首页与连接页不重建', (WidgetTester tester) async {
    final _Connection connection = await pumpShell(
      tester,
      phase: ConnectionPhase.connected,
    );
    await tester.tap(
      find.descendant(of: find.byType(AppSidebar), matching: find.text('设置')),
    );
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    rebuilt.clear();

    for (int second = 1; second <= 3; second++) {
      connection.sample(TrafficSample(1000 * second, 2000 * second));
      await tester.pump(const Duration(seconds: 1));
    }

    expect(rebuilt.where(under<HomePage>), isEmpty);
    expect(rebuilt.where(under<ConnectionsPage>), isEmpty);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _Connection extends ConnectionController {
  _Connection({
    required super.platform,
    required super.kernel,
    required super.settingsStore,
    required this.phase,
  });

  final ConnectionPhase? phase;
  final ValueNotifier<int> _ticks = ValueNotifier<int>(0);
  final DateTime _since = DateTime.now();
  TrafficSample _traffic = const TrafficSample(0, 0);

  bool get connected => phase == ConnectionPhase.connected;

  void ping() => notifyListeners();

  void sample(TrafficSample traffic) {
    _traffic = traffic;
    _ticks.value++;
  }

  @override
  Listenable get statsUpdates => _ticks;
  @override
  ConnectionPhase get state => phase ?? super.state;
  @override
  DateTime? get connectedAt => connected ? _since : super.connectedAt;
  @override
  TrafficSample get traffic => _traffic;

  @override
  void dispose() {
    _ticks.dispose();
    super.dispose();
  }
}

class _Auth extends ChangeNotifier implements AuthController {
  @override
  bool get busy => false;
  @override
  bool get hasUnreadTicketReply => false;
  @override
  AuthStage get stage => AuthStage.loggedIn;
  @override
  String? get accountKey => null;
  @override
  DateTime? get sessionExpiresAt => null;
  @override
  VoidCallback? onDeviceKickNotice;
  @override
  Future<void> refreshProfile() async {}
  @override
  Future<void> refreshPanelClientAddress() async {}
  @override
  UserProfile? get profile => null;
  @override
  Null get api => null;
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
  bool get isTelevision => false;
  @override
  Stream<TrayAction> get trayActions => const Stream<TrayAction>.empty();
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
  Stream<KernelStatus> get statusStream => const Stream<KernelStatus>.empty();
  @override
  Stream<String> get kernelLog => const Stream<String>.empty();
  @override
  KernelStatus get status => const KernelStatus.stopped();
  @override
  bool get cacheReady => false;
  @override
  bool get upgradable => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
