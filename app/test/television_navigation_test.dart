import 'package:ecycloud_client/data/models/account.dart';
import 'package:ecycloud_client/data/store/credential_store.dart';
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/state/announcement_controller.dart';
import 'package:ecycloud_client/state/auth_controller.dart';
import 'package:ecycloud_client/state/connection_controller.dart';
import 'package:ecycloud_client/state/update_controller.dart';
import 'package:ecycloud_client/ui/app_scope.dart';
import 'package:ecycloud_client/l10n/app_language.dart';
import 'package:ecycloud_client/ui/pages/language_setup_page.dart';
import 'package:ecycloud_client/ui/pages/legal_document_page.dart';
import 'package:ecycloud_client/ui/pages/login_page.dart';
import 'package:ecycloud_client/ui/pages/register_page.dart';
import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/app_alert_dialog.dart';
import 'package:ecycloud_client/ui/widgets/app_sidebar.dart';
import 'package:ecycloud_client/ui/widgets/rich_html_view.dart';
import 'package:ecycloud_client/ui/widgets/television_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Auth extends ChangeNotifier implements AuthController {
  @override
  String get siteOrigin => 'https://example.com';
  @override
  bool get busy => false;
  @override
  bool get sendingCode => false;
  @override
  String? get error => null;
  @override
  AuthStage get stage => AuthStage.loggedOut;
  @override
  Future<AuthOptions?> fetchAuthOptions() async => const AuthOptions(
    regMode: 'invite',
    emailVerify: true,
    enableChangeEmail: true,
    enableKill: true,
    apiOrigin: 'https://example.com',
    siteOrigin: 'https://example.com',
  );
  @override
  Future<RememberedLogin?> loadRememberedLogin() async => null;
  @override
  Future<void> clearRememberedLogin() async {}
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

class _Platform implements PlatformService {
  _Platform(this.isTelevision);
  @override
  final bool isTelevision;
  @override
  Future<void> setImeEnabled({required bool enabled}) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pumpLogin(
  WidgetTester tester, {
  bool television = true,
  bool dark = false,
  Widget home = const LoginPage(),
  Size size = const Size(1280, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final _Auth auth = _Auth();
  addTearDown(auth.dispose);
  final ThemeData theme = dark ? AppTheme.dark() : AppTheme.light();
  await tester.pumpWidget(
    AppScope(
      auth: auth,
      connection: _Connection(),
      announcements: _Announcements(),
      update: _Update(),
      platform: _Platform(television),
      settingsStore: _Settings(),
      child: MaterialApp(
        theme: television ? AppTheme.withTelevisionFocus(theme) : theme,
        builder: (context, child) => television
            ? MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  padding: AppTheme.televisionPadding(
                    MediaQuery.paddingOf(context),
                  ),
                ),
                child: TelevisionNavigation(child: SafeArea(child: child!)),
              )
            : child!,
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

EditableText _field(WidgetTester tester, int index) =>
    tester.widget<EditableText>(find.byType(EditableText).at(index));

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

final String _longHtml = List<String>.generate(
  120,
  (int index) => '<p>第 $index 段</p>',
).join();

ScrollPosition _position(WidgetTester tester, Finder within) => tester
    .state<ScrollableState>(
      find.descendant(of: within, matching: find.byType(Scrollable)).first,
    )
    .position;

void main() {
  for (final bool dark in <bool>[false, true]) {
    testWidgets('电视${dark ? '深色' : '浅色'}登录可离开邮箱、显示密码并点击登录', (tester) async {
      await _pumpLogin(tester, dark: dark);
      expect(_field(tester, 0).focusNode.hasFocus, isTrue);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_field(tester, 1).focusNode.hasFocus, isTrue);
      await _key(tester, LogicalKeyboardKey.arrowUp);
      expect(_field(tester, 0).focusNode.hasFocus, isTrue);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.arrowRight);
      await _key(tester, LogicalKeyboardKey.select);
      expect(_field(tester, 1).obscureText, isFalse);
      await _key(tester, LogicalKeyboardKey.arrowLeft);
      expect(_field(tester, 1).focusNode.hasFocus, isTrue);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.select);
      expect(find.text('请填写邮箱'), findsOneWidget);
      expect(find.text('请填写密码'), findsOneWidget);
    });
  }

  testWidgets('电视在最底端按下绕回最顶部', (tester) async {
    await _pumpLogin(tester);
    FocusNode? last;
    while (FocusManager.instance.primaryFocus != last) {
      last = FocusManager.instance.primaryFocus;
      await _key(tester, LogicalKeyboardKey.arrowDown);
      if (_field(tester, 0).focusNode.hasFocus) {
        break;
      }
    }
    expect(_field(tester, 0).focusNode.hasFocus, isTrue);
  });

  testWidgets('电视在最顶部的输入框按上绕回最底部', (tester) async {
    await _pumpLogin(tester);
    expect(_field(tester, 0).focusNode.hasFocus, isTrue);
    final double top = FocusManager.instance.primaryFocus!.rect.top;
    await _key(tester, LogicalKeyboardKey.arrowUp);
    expect(_field(tester, 0).focusNode.hasFocus, isFalse);
    expect(FocusManager.instance.primaryFocus!.rect.top, greaterThan(top));
  });

  testWidgets('电视列表滚到底后按下绕回列表上方的工具栏', (tester) async {
    await _pumpLogin(
      tester,
      home: Scaffold(
        body: Column(
          children: <Widget>[
            TextButton(
              autofocus: true,
              onPressed: () {},
              child: const Text('工具栏'),
            ),
            Expanded(
              child: ListView(
                children: <Widget>[
                  for (int i = 0; i < 30; i++)
                    TextButton(onPressed: () {}, child: Text('第 $i 项')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    String focused() =>
        (FocusManager.instance.primaryFocus!.context!
                    .findAncestorWidgetOfExactType<TextButton>()!
                    .child!
                as Text)
            .data!;
    await _key(tester, LogicalKeyboardKey.arrowUp);
    expect(focused(), '第 29 项');
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(), '工具栏');
  });

  testWidgets('电视菜单按钮同样按电视规则移动并绕回', (tester) async {
    await _pumpLogin(
      tester,
      home: Scaffold(
        body: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            TextButton(onPressed: () {}, child: const Text('顶部')),
            MenuAnchor(
              menuChildren: <Widget>[
                MenuItemButton(onPressed: () {}, child: const Text('菜单项')),
              ],
              builder: (context, controller, child) => TextButton(
                autofocus: true,
                onPressed: controller.open,
                child: const Text('菜单'),
              ),
            ),
          ],
        ),
      ),
    );
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(
      FocusManager.instance.primaryFocus!.context!
          .findAncestorWidgetOfExactType<TextButton>()!
          .child,
      isA<Text>().having((text) => text.data, 'data', '顶部'),
    );
  });

  testWidgets('电视页面只剩同一行按钮时按上下不横跳', (tester) async {
    final FocusNode first = FocusNode();
    addTearDown(first.dispose);
    await _pumpLogin(
      tester,
      home: Scaffold(
        body: Row(
          children: <Widget>[
            TextButton(
              focusNode: first,
              autofocus: true,
              onPressed: () {},
              child: const Text('刷新'),
            ),
            TextButton(onPressed: () {}, child: const Text('头像')),
          ],
        ),
      ),
    );
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(first.hasFocus, isTrue);
    await _key(tester, LogicalKeyboardKey.arrowUp);
    expect(first.hasFocus, isTrue);
  });

  testWidgets('电视用方向键移入输入框不弹出键盘，按确认键才弹出', (tester) async {
    await _pumpLogin(tester);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_field(tester, 1).focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isFalse);
    await _key(tester, LogicalKeyboardKey.select);
    expect(tester.testTextInput.isVisible, isTrue);
  });

  testWidgets('电视确认键可以重新打开已关闭的输入法', (tester) async {
    await _pumpLogin(tester);
    for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
      LogicalKeyboardKey.select,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.numpadEnter,
    ]) {
      tester.testTextInput.hide();
      expect(tester.testTextInput.isVisible, isFalse);
      await _key(tester, key);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(_field(tester, 0).focusNode.hasFocus, isTrue);
    }
  });

  testWidgets('电视验证码登录可从输入框移到获取验证码按钮', (tester) async {
    await _pumpLogin(tester);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.enter);
    expect(find.text('获取验证码'), findsOneWidget);
    await _key(tester, LogicalKeyboardKey.arrowUp);
    await _key(tester, LogicalKeyboardKey.arrowUp);
    await _key(tester, LogicalKeyboardKey.arrowUp);
    await _key(tester, LogicalKeyboardKey.arrowLeft);
    expect(_field(tester, 1).focusNode.hasFocus, isTrue);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    await _key(tester, LogicalKeyboardKey.enter);
    expect(find.text('请先填写邮箱'), findsOneWidget);
  });

  testWidgets('电视邮箱输入法下一项进入密码框', (tester) async {
    await _pumpLogin(tester);
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();
    expect(_field(tester, 1).focusNode.hasFocus, isTrue);
  });

  testWidgets('普通设备仍使用方向键移动输入光标', (tester) async {
    await _pumpLogin(tester, television: false);
    await tester.enterText(find.byType(TextField).first, 'user@example.com');
    await _key(tester, LogicalKeyboardKey.arrowLeft);
    expect(_field(tester, 0).focusNode.hasFocus, isTrue);
    expect(_field(tester, 0).controller.selection.baseOffset, 15);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_field(tester, 0).focusNode.hasFocus, isTrue);
  });

  testWidgets('电视注册页返回键与第一个输入框上下互通', (tester) async {
    // 1080p 电视按 2 倍密度换算后的逻辑尺寸
    await _pumpLogin(
      tester,
      home: const RegisterPage(),
      size: const Size(960, 540),
    );
    await _key(tester, LogicalKeyboardKey.arrowDown);
    final FocusNode back = FocusManager.instance.primaryFocus!;
    expect(
      back.context!.findAncestorWidgetOfExactType<IconButton>(),
      isNotNull,
    );
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_field(tester, 0).focusNode.hasFocus, isTrue);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_field(tester, 1).focusNode.hasFocus, isTrue);
    await _key(tester, LogicalKeyboardKey.arrowUp);
    await _key(tester, LogicalKeyboardKey.arrowUp);
    expect(back.hasFocus, isTrue);
  });

  testWidgets('电视侧边栏到底后绕回顶部，不斜跳进内容区', (tester) async {
    await _pumpLogin(
      tester,
      home: Scaffold(
        body: Row(
          children: <Widget>[
            AppSidebar(
              selectedIndex: 0,
              onSelected: (_) {},
              items: <AppSidebarItem>[
                for (final String label in <String>['首页', '节点', '设置'])
                  AppSidebarItem(
                    icon: Icons.circle_outlined,
                    selectedIcon: Icons.circle,
                    label: label,
                  ),
              ],
            ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(onPressed: () {}, child: const Text('内容')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    bool focusedOn(String text) {
      final RenderBox box = tester.renderObject(find.text(text));
      return FocusManager.instance.primaryFocus!.rect.contains(
        box.localToGlobal(box.size.center(Offset.zero)),
      );
    }

    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedOn('首页'), isTrue);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedOn('设置'), isTrue);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedOn('首页'), isTrue);
    await _key(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedOn('设置'), isTrue);
  });

  testWidgets('电视语言页进入单选列表后仍能回到确定按钮', (tester) async {
    AppLanguage? chosen;
    await _pumpLogin(
      tester,
      home: LanguageSetupPage(
        initial: AppLanguage.values.last,
        onChosen: (language) => chosen = language,
      ),
    );
    await _key(tester, LogicalKeyboardKey.arrowUp);
    await _key(tester, LogicalKeyboardKey.arrowUp);
    await _key(tester, LogicalKeyboardKey.select);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.select);
    expect(chosen, AppLanguage.values[AppLanguage.values.length - 2]);
  });

  testWidgets('电视安全区内铺满整页的焦点不画焦点框', (tester) async {
    await _pumpLogin(
      tester,
      home: const Focus(autofocus: true, child: SizedBox.expand()),
    );
    expect(
      find.descendant(
        of: find.byType(IgnorePointer),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).border != null,
        ),
      ),
      findsNothing,
    );
  });

  testWidgets('电视服务条款页可用方向键滚动正文', (tester) async {
    await _pumpLogin(
      tester,
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (context) => LegalDocumentPage(
                  title: '服务条款',
                  emptyMessage: '',
                  loadContent: () async => _longHtml,
                ),
              ),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await _key(tester, LogicalKeyboardKey.select);
    final ScrollPosition position = _position(
      tester,
      find.byType(LegalDocumentPage),
    );
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(position.pixels, greaterThan(0));
    final double scrolled = position.pixels;
    await _key(tester, LogicalKeyboardKey.arrowUp);
    expect(position.pixels, lessThan(scrolled));
  });

  testWidgets('电视公告弹窗可从确认按钮滚动正文', (tester) async {
    await _pumpLogin(
      tester,
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            autofocus: true,
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AppAlertDialog(
                content: RichHtmlView(_longHtml),
                actions: <Widget>[
                  FilledButton(
                    autofocus: true,
                    onPressed: () {},
                    child: const Text('我知道了'),
                  ),
                ],
              ),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await _key(tester, LogicalKeyboardKey.select);
    final ScrollPosition position = _position(tester, find.byType(AlertDialog));
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(position.pixels, greaterThan(0));
  });

  testWidgets('电视弹窗内可从输入框切换到确认按钮', (tester) async {
    final FocusNode field = FocusNode();
    addTearDown(field.dispose);
    bool confirmed = false;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TelevisionNavigation(child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  content: TextField(autofocus: true, focusNode: field),
                  actions: <Widget>[
                    TextButton(
                      onPressed: () => confirmed = true,
                      child: const Text('确定'),
                    ),
                  ],
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(field.hasFocus, isTrue);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.select);
    expect(confirmed, isTrue);
  });
}
