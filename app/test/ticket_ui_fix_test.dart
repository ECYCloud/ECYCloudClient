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
  testWidgets('连接/工单按钮使用主题默认样式，不再套自定义矮按钮', (
    WidgetTester tester,
  ) async {
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
    final String homeSrc = File('lib/ui/pages/home_page.dart').readAsStringSync();
    final String ticketsSrc = File('lib/ui/pages/tickets_page.dart').readAsStringSync();
    expect(themeSrc.contains('actionButtonStyle'), isFalse);
    expect(homeSrc.contains('actionButtonStyle'), isFalse);
    expect(ticketsSrc.contains('actionButtonStyle'), isFalse);
  });

  testWidgets('多行内容框滚动条在独立轨道且使用箭头光标', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(
        SizedBox(
          width: 460,
          child: MultilineContentField(
            controller: TextEditingController(text: '${'测试内容' * 20}\n' * 12),
            labelText: '内容',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MultilineContentField), findsOneWidget);
    expect(find.byType(MouseRegion), findsWidgets);
    expect(find.byType(CustomPaint), findsWidgets);

    final MouseRegion rail = tester.widget<MouseRegion>(
      find
          .descendant(
            of: find.byType(MultilineContentField),
            matching: find.byType(MouseRegion),
          )
          .last,
    );
    expect(rail.cursor, SystemMouseCursors.basic);
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
      login.lastIndexOf('TextFormField(', emailField),
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
    final String src =
        File('lib/ui/widgets/rich_html_view.dart').readAsStringSync();
    expect(src, contains('SystemMouseCursors.click'));
    expect(src, contains('Tooltip'));
    expect(src, contains("tagsToExtend: <String>{'a'}"));
    expect(src, contains('TagExtension.inline'));
    expect(src, contains('ShellNavigator.openTickets'));
    expect(src, contains('Style.fromThemeData'));
    expect(src, contains("'*': uiFont"));
    expect(src, contains('doNotRenderTheseTags'));
    expect(src, contains('SafeUrl.canOpenLink'));
    expect(src, contains('SafeUrl.canLoad'));
  });
}
