import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ecycloud_client/ui/pages/login_page.dart';
import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/multiline_content_field.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: AppTheme.light().copyWith(platform: TargetPlatform.windows),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('连接/工单按钮使用主题默认样式，不再套自定义矮按钮', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FilledButton.icon(
              key: const Key('connect'),
              onPressed: () {},
              icon: const Icon(Icons.play_arrow, size: 16),
              label: const Text('连接'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              key: const Key('ticket'),
              onPressed: () {},
              icon: const Icon(Icons.add, size: 16),
              label: const Text('创建工单'),
            ),
          ],
        ),
      ),
    );

    final Size connect = tester.getSize(find.byKey(const Key('connect')));
    final Size ticket = tester.getSize(find.byKey(const Key('ticket')));
    expect(connect.height, ticket.height);

    final String themeSrc = File('lib/ui/theme.dart').readAsStringSync();
    final String homeSrc = File(
      'lib/ui/pages/home_page.dart',
    ).readAsStringSync();
    final String ticketsSrc = File(
      'lib/ui/pages/tickets_page.dart',
    ).readAsStringSync();
    expect(themeSrc.contains('actionButtonStyle'), isFalse);
    expect(homeSrc.contains('actionButtonStyle'), isFalse);
    expect(ticketsSrc.contains('actionButtonStyle'), isFalse);
  });

  testWidgets('多行内容框仍是圆角矩形输入', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(
        SizedBox(
          width: 460,
          child: MultilineContentField(
            controller: TextEditingController(text: '短内容'),
            labelText: '内容',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('内容'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(MultilineContentField),
        matching: find.byType(TextField),
      ),
      findsOneWidget,
    );
  });

  test('滚动条边距走全局主题，卡密描述与公告共用同一滚动容器', () {
    final String theme = File('lib/ui/theme.dart').readAsStringSync();
    final String announcement = File(
      'lib/ui/widgets/announcement_dialog.dart',
    ).readAsStringSync();
    final String field = File(
      'lib/ui/widgets/multiline_content_field.dart',
    ).readAsStringSync();
    final String shop = File('lib/ui/pages/shop_page.dart').readAsStringSync();
    final String body = File(
      'lib/ui/widgets/clipped_scroll_body.dart',
    ).readAsStringSync();
    expect(theme.contains('mainAxisMargin: 4'), isTrue);
    expect(theme.contains('crossAxisMargin: 2'), isTrue);
    expect(theme.contains('interactive: true'), isTrue);
    expect(theme.contains('overlayScrollPadding'), isTrue);
    expect(announcement.contains('ClippedScrollBody'), isTrue);
    expect(announcement.contains('OverlayScrollView'), isTrue);
    expect(shop.contains('ClippedScrollBody'), isTrue);
    final int desc = shop.indexOf("L10n.t('商品描述')");
    expect(desc, greaterThanOrEqualTo(0));
    final int tileStart = shop.lastIndexOf('ExpansionTile(', desc);
    final int bodyStart = shop.indexOf('ClippedScrollBody(', desc);
    expect(tileStart, greaterThanOrEqualTo(0));
    expect(bodyStart, greaterThan(tileStart));
    final String descHeader = shop.substring(tileStart, bodyStart);
    expect(descHeader.contains('childrenPadding'), isFalse);
    expect(descHeader.contains('CrossAxisAlignment.stretch'), isTrue);
    expect(
      descHeader.contains('backgroundColor: scheme.primary.withValues'),
      isTrue,
    );
    expect(shop.contains('filled: false'), isTrue);
    expect(field.contains('_ScrollRail'), isFalse);
    expect(field.contains('alignLabelWithHint: true'), isTrue);
    expect(field.contains('labelText: labelText'), isTrue);
    expect(body.contains('maxHeight = 360'), isTrue);
    expect(body.contains('OverlayScrollView'), isTrue);
    expect(body.contains('pointerSignalResolver'), isTrue);
  });

  test('SingleChildScrollView 只允许出现在 OverlayScrollView 内；列表必须留 gutter', () {
    final RegExp listCtor = RegExp(r'ListView(?:\.\w+)?\s*\(');
    const Set<String> tokens = <String>{
      'overlayScrollGutter',
      'overlayScrollPadding',
      'overlayScrollPaddingBottom',
      'pageScrollPadding',
      'overlayGutterOf',
      'EdgeInsets.all(24)',
      'EdgeInsets.all(32)',
    };
    final List<String> missing = <String>[];
    for (final FileSystemEntity entity in Directory(
      'lib/ui',
    ).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      final String rel = entity.path.replaceAll('\\', '/');
      final List<String> lines = entity.readAsStringSync().split('\n');
      for (int i = 0; i < lines.length; i++) {
        if (lines[i].contains('SingleChildScrollView(') &&
            !rel.endsWith('/widgets/overlay_scroll_view.dart')) {
          missing.add('$rel:${i + 1}: raw SingleChildScrollView');
          continue;
        }
        if (!listCtor.hasMatch(lines[i])) {
          continue;
        }
        if (rel.endsWith('/widgets/overlay_scroll_view.dart')) {
          continue;
        }
        final String window = lines
            .sublist(i, i + 12 > lines.length ? lines.length : i + 12)
            .join('\n');
        if (tokens.any(window.contains)) {
          continue;
        }
        missing.add('$rel:${i + 1}');
      }
    }
    expect(missing, isEmpty, reason: missing.join('\n'));
  });

  test('验证码 formatter：只保留大写字母数字，且不靠丢弃组字来对抗 IME', () {
    final OtpCodeFormatter fmt = OtpCodeFormatter();
    const TextEditingValue empty = TextEditingValue.empty;

    // 组字中不能返回 oldValue：引擎仍持有 composing，IME 提交时文本会再来一遍（ab -> ABABAB）
    final TextEditingValue composing = fmt.formatEditUpdate(
      const TextEditingValue(text: 'AB'),
      const TextEditingValue(
        text: 'AB测',
        composing: TextRange(start: 2, end: 3),
      ),
    );
    expect(composing.text, 'AB');

    final TextEditingValue ok = fmt.formatEditUpdate(
      empty,
      const TextEditingValue(
        text: 'ab12cd',
        selection: TextSelection.collapsed(offset: 6),
      ),
    );
    expect(ok.text, 'AB12CD');

    final TextEditingValue junk = fmt.formatEditUpdate(
      empty,
      const TextEditingValue(text: 'a测b'),
    );
    expect(junk.text, 'AB');
  });

  testWidgets('获取验证码按钮与验证码输入框等高', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: TextFormField(
                decoration: const InputDecoration(
                  labelText: '验证码',
                  prefixIcon: Icon(Icons.pin_outlined),
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              height: loginFieldHeight(AppTheme.light()),
              child: OutlinedButton(
                onPressed: () {},
                child: const Text('获取验证码'),
              ),
            ),
          ],
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(OutlinedButton)).height,
      tester.getSize(find.byType(TextFormField)).height,
    );
  });

  test('密码框只收可见 ASCII；邮箱框不限制字符集', () {
    final TextEditingValue password = asciiOnlyFormatter.formatEditUpdate(
      TextEditingValue.empty,
      const TextEditingValue(text: 'p测ass'),
    );
    expect(password.text, 'pass');

    final String login = File(
      'lib/ui/pages/login_page.dart',
    ).readAsStringSync();
    final int emailField = login.indexOf("labelText: L10n.t('邮箱')");
    expect(emailField, greaterThanOrEqualTo(0));
    final String emailBlock = login.substring(
      login.lastIndexOf('TextField(', emailField),
      emailField,
    );
    expect(emailBlock.contains('asciiOnlyFormatter'), isFalse);
    expect(emailBlock.contains('setImeEnabled'), isFalse);
  });

  test('登录页注册入口进入应用内注册页', () {
    final String src = File('lib/ui/pages/login_page.dart').readAsStringSync();
    expect(src, contains('RegisterPage()'));
    expect(src, contains('_openRegister'));
    expect(src, contains('TextInputType.visiblePassword'));
  });

  test('邮箱验证码获焦关 IME，邮箱页不整页关闭', () {
    final String login = File(
      'lib/ui/pages/login_page.dart',
    ).readAsStringSync();
    final String register = File(
      'lib/ui/pages/register_page.dart',
    ).readAsStringSync();
    final String reset = File(
      'lib/ui/pages/reset_password_page.dart',
    ).readAsStringSync();
    expect(login, contains('class EmailOtpIme'));
    expect(login, contains('OtpCodeFormatter()'));
    expect(register, contains('EmailOtpIme('));
    expect(register, contains('OtpCodeFormatter()'));
    expect(login, contains('setImeEnabled(enabled: !_focusNode.hasFocus)'));
    expect(register.contains('setImeEnabled(enabled: false)'), isFalse);
    expect(reset.contains('setImeEnabled'), isFalse);
    expect(login.contains("MethodChannel('ecycloud/platform')"), isFalse);
    expect(login.contains('dart:ffi'), isFalse);
    expect(login.contains('LoadKeyboardLayout'), isFalse);
    expect(login.contains('preferAsciiKeyboardLayout'), isFalse);
    expect(File('lib/platform/windows/window_ime.dart').existsSync(), isFalse);
    expect(File('lib/platform/windows/ascii_ime.dart').existsSync(), isFalse);

    final String native = File(
      'windows/runner/platform_channel.cpp',
    ).readAsStringSync();
    expect(native, contains('ImmAssociateContextEx'));
    expect(native, contains('IACE_DEFAULT'));
    expect(native.contains('SetWindowLongPtrW'), isFalse);
    expect(native.contains('LoadKeyboardLayout'), isFalse);
    expect(native.contains('ActivateKeyboardLayout'), isFalse);
    expect(native.contains('ImmDisableIME'), isFalse);
    expect(
      File('windows/runner/CMakeLists.txt').readAsStringSync(),
      contains('imm32.lib'),
    );
  });

  test('公告/工单 HTML 链接使用手型光标并悬停显示地址', () {
    final String src = File(
      'lib/ui/widgets/rich_html_view.dart',
    ).readAsStringSync();
    expect(src, contains('SystemMouseCursors.click'));
    expect(src, contains('Tooltip'));
    expect(src, contains("tagsToExtend: <String>{'a'}"));
    expect(src, contains('TagExtension.inline'));
    expect(src, contains('ShellNavigator.openTab'));
    expect(src, contains("'/user/ticket' => ShellNavigator.ticketsTab"));
    expect(src, contains('Style.fromThemeData'));
    expect(src, contains("'*': uiFont"));
    expect(src, contains('doNotRenderTheseTags'));
    expect(src, contains('SafeUrl.canOpenLink'));
    expect(src, contains('SafeUrl.canLoad'));
  });
}
