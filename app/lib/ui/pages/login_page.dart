import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_config.dart';
import '../../data/store/credential_store.dart';
import '../../l10n/l10n.dart';
import '../../domain/platform/platform_service.dart';
import '../../state/auth_controller.dart';
import '../app_scope.dart';
import '../widgets/field_subtext.dart';
import '../widgets/overlay_scroll_view.dart';
import 'register_page.dart';
import 'reset_password_page.dart';

/// 组字中不能回退到 oldValue：引擎仍持有 composing，IME 提交时同一段文本会再来一遍
class OtpCodeFormatter extends TextInputFormatter {
  static final RegExp _nonAlphanumeric = RegExp(r'[^A-Za-z0-9]');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final String clipped = newValue.text
        .replaceAll(_nonAlphanumeric, '')
        .toUpperCase();
    final String limited = clipped.length > 6
        ? clipped.substring(0, 6)
        : clipped;
    return TextEditingValue(
      text: limited,
      selection: TextSelection.collapsed(offset: limited.length),
    );
  }
}

final TextInputFormatter asciiOnlyFormatter = FilteringTextInputFormatter.deny(
  RegExp(r'[^\x20-\x7E]'),
);

/// 仅验证码获焦时关掉本窗口 IME（对齐密码框英文输入）；勿整页关闭，否则国际邮箱无法输入
class EmailOtpIme extends StatefulWidget {
  const EmailOtpIme({super.key, required this.builder});

  final Widget Function(BuildContext context, FocusNode focusNode) builder;

  @override
  State<EmailOtpIme> createState() => _EmailOtpImeState();
}

class _EmailOtpImeState extends State<EmailOtpIme> {
  final FocusNode _focusNode = FocusNode();
  PlatformService? _platform;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_syncIme);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _platform = AppScope.of(context).platform;
  }

  void _syncIme() {
    final PlatformService? platform = _platform;
    if (platform == null) {
      return;
    }
    unawaited(platform.setImeEnabled(enabled: !_focusNode.hasFocus));
  }

  @override
  void dispose() {
    _focusNode.removeListener(_syncIme);
    final PlatformService? platform = _platform;
    if (platform != null) {
      unawaited(platform.setImeEnabled(enabled: true));
    }
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _focusNode);
}

/// 带 prefixIcon 的输入框，高度取图标的最小交互尺寸经 visualDensity 收缩后的值；
/// 与输入框并排的按钮必须读同一处，否则主题调密度时两者会错开
double loginFieldHeight(ThemeData theme) => theme.visualDensity
    .effectiveConstraints(
      const BoxConstraints(
        minWidth: kMinInteractiveDimension,
        minHeight: kMinInteractiveDimension,
      ),
    )
    .minHeight;

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _code = TextEditingController();

  bool _obscure = true;
  bool _entering = false;
  bool _emailCodeMode = false;
  bool _remember = false;
  int _sendCooldown = 0;
  Timer? _cooldownTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_restoreRemembered()),
    );
  }

  Future<void> _restoreRemembered() async {
    if (!mounted) {
      return;
    }
    final RememberedLogin? saved = await AppScope.of(
      context,
    ).auth.loadRememberedLogin();
    if (!mounted || saved == null) {
      return;
    }
    _email.text = saved.email;
    _password.text = saved.password;
    setState(() => _remember = true);
  }

  void _setRemember(AuthController auth, bool remember) {
    setState(() => _remember = remember);
    if (!remember) {
      unawaited(auth.clearRememberedLogin());
    }
  }

  Future<void> _persistRemember(AuthController auth) async {
    if (_remember) {
      await auth.saveRememberedLogin(
        email: _email.text.trim(),
        password: _password.text,
      );
    } else {
      await auth.clearRememberedLogin();
    }
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _email.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit(AuthController auth) async {
    if (!_formKey.currentState!.validate() || _entering) {
      return;
    }

    final bool ok = _emailCodeMode
        ? await auth.loginWithVerifyCode(
            email: _email.text.trim(),
            code: _code.text.trim(),
          )
        : await auth.login(email: _email.text.trim(), password: _password.text);
    if (!mounted) {
      return;
    }
    if (ok) {
      await _showSuccessAndEnter(auth);
      return;
    }
    if (!_emailCodeMode && auth.stage == AuthStage.needsTwoFactor) {
      final bool? verified = await _promptTwoFactor(auth);
      if (verified == true && mounted) {
        await _showSuccessAndEnter(auth);
      }
    }
  }

  Future<void> _sendCode(AuthController auth) async {
    final String email = _email.text.trim();
    if (email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.t('请先填写邮箱')),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (_sendCooldown > 0 || auth.busy || _entering) {
      return;
    }

    final bool ok = await auth.sendLoginVerify(email: email);
    if (!mounted || !ok) {
      return;
    }

    _startCooldown();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(L10n.t('验证码已发送，请查收邮件')),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _sendCooldown = 60);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_sendCooldown <= 1) {
        t.cancel();
        setState(() => _sendCooldown = 0);
        return;
      }
      setState(() => _sendCooldown -= 1);
    });
  }

  Future<void> _openForgotPassword() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const ResetPasswordPage(),
      ),
    );
  }

  Future<void> _openRegister() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const RegisterPage(),
      ),
    );
  }

  Future<bool?> _promptTwoFactor(AuthController auth) {
    return showDialog<bool>(
      context: context,
      builder: (BuildContext context) => _TwoFactorDialog(
        onVerify: (String code) => auth.login(
          email: _email.text.trim(),
          password: _password.text,
          twoFactorCode: code,
        ),
        errorOf: () => auth.error,
      ),
    );
  }

  Future<void> _showSuccessAndEnter(AuthController auth) async {
    await _persistRemember(auth);
    if (!mounted) {
      return;
    }
    setState(() => _entering = true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(L10n.t('登录成功')),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 900),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted) {
      return;
    }
    auth.enterShell();
  }

  @override
  Widget build(BuildContext context) {
    final AuthController auth = AppScope.of(context).auth;
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: OverlayScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: ListenableBuilder(
              listenable: auth,
              builder: (BuildContext context, _) {
                return Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Icon(
                        Icons.shield_outlined,
                        size: 56,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'ECY Cloud',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        L10n.t('使用 {0} 账号登录，登录后自动获取可用节点', <Object>[
                          AppConfig.siteHost,
                        ]),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 32),
                      TextField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autocorrect: false,
                        enableSuggestions: false,
                        autofillHints: const <String>[AutofillHints.email],
                        decoration: InputDecoration(
                          labelText: L10n.t('邮箱'),
                          prefixIcon: const Icon(Icons.mail_outline),
                        ),
                      ).validated(
                        () =>
                            _email.text.trim().isEmpty ? L10n.t('请填写邮箱') : null,
                      ),
                      const SizedBox(height: 16),
                      if (_emailCodeMode)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Expanded(
                              child: EmailOtpIme(
                                builder:
                                    (
                                      BuildContext context,
                                      FocusNode focusNode,
                                    ) {
                                      return TextField(
                                        controller: _code,
                                        focusNode: focusNode,
                                        keyboardType:
                                            TextInputType.visiblePassword,
                                        autocorrect: false,
                                        enableSuggestions: false,
                                        autofillHints: const <String>[
                                          AutofillHints.oneTimeCode,
                                        ],
                                        inputFormatters: <TextInputFormatter>[
                                          OtpCodeFormatter(),
                                        ],
                                        decoration: InputDecoration(
                                          labelText: L10n.t('验证码'),
                                          prefixIcon: const Icon(
                                            Icons.pin_outlined,
                                          ),
                                        ),
                                        onSubmitted: (_) =>
                                            auth.busy || _entering
                                            ? null
                                            : _submit(auth),
                                      ).validated(
                                        () => _code.text.trim().isEmpty
                                            ? L10n.t('请填写验证码')
                                            : null,
                                      );
                                    },
                              ),
                            ),
                            const SizedBox(width: 12),
                            SizedBox(
                              height: loginFieldHeight(theme),
                              child: OutlinedButton(
                                onPressed:
                                    auth.busy || _entering || _sendCooldown > 0
                                    ? null
                                    : () => _sendCode(auth),
                                child: Text(
                                  _sendCooldown > 0
                                      ? '${_sendCooldown}s'
                                      : L10n.t('获取验证码'),
                                ),
                              ),
                            ),
                          ],
                        )
                      else
                        EmailOtpIme(
                          builder: (BuildContext context, FocusNode focusNode) {
                            return TextField(
                              controller: _password,
                              focusNode: focusNode,
                              obscureText: _obscure,
                              keyboardType: TextInputType.visiblePassword,
                              autocorrect: false,
                              enableSuggestions: false,
                              autofillHints: const <String>[
                                AutofillHints.password,
                              ],
                              inputFormatters: <TextInputFormatter>[
                                asciiOnlyFormatter,
                              ],
                              decoration: InputDecoration(
                                labelText: L10n.t('密码'),
                                prefixIcon: const Icon(Icons.lock_outline),
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _obscure
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                  ),
                                  onPressed: () =>
                                      setState(() => _obscure = !_obscure),
                                ),
                              ),
                              onSubmitted: (_) =>
                                  auth.busy || _entering ? null : _submit(auth),
                            ).validated(
                              () => _password.text.isEmpty
                                  ? L10n.t('请填写密码')
                                  : null,
                            );
                          },
                        ),
                      const SizedBox(height: 8),
                      Row(
                        children: <Widget>[
                          Checkbox(
                            value: _remember,
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            mouseCursor: SystemMouseCursors.basic,
                            onChanged: (bool? value) =>
                                _setRemember(auth, value ?? false),
                          ),
                          InkWell(
                            onTap: () => _setRemember(auth, !_remember),
                            child: Text(L10n.t('记住账号密码')),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () => setState(
                              () => _emailCodeMode = !_emailCodeMode,
                            ),
                            child: Text(
                              _emailCodeMode
                                  ? L10n.t('密码登录')
                                  : L10n.t('邮箱验证码登录'),
                            ),
                          ),
                        ],
                      ),
                      if (auth.error != null &&
                          auth.stage != AuthStage.needsTwoFactor) ...<Widget>[
                        const SizedBox(height: 8),
                        AuthErrorBanner(message: auth.error!),
                      ],
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: auth.busy || _entering
                            ? null
                            : () => _submit(auth),
                        child: auth.busy || _entering
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(L10n.t('登录')),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: <Widget>[
                          TextButton(
                            onPressed: _openRegister,
                            child: Text('${L10n.t('注册账号')} ›'),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: _openForgotPassword,
                            child: Text(L10n.t('忘记密码？')),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _TwoFactorDialog extends StatefulWidget {
  const _TwoFactorDialog({required this.onVerify, required this.errorOf});

  final Future<bool> Function(String code) onVerify;
  final String? Function() errorOf;

  @override
  State<_TwoFactorDialog> createState() => _TwoFactorDialogState();
}

class _TwoFactorDialogState extends State<_TwoFactorDialog> {
  final TextEditingController _code = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify(String code) async {
    if (_busy || code.length != 6) {
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final bool ok = await widget.onVerify(code);
    if (!mounted) {
      return;
    }
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }

    _code.clear();
    setState(() {
      _busy = false;
      _error = widget.errorOf();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return AlertDialog(
      title: Text(L10n.t('两步验证'), textAlign: TextAlign.center),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            L10n.t('请输入您的两步验证码'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            autofocus: true,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            maxLength: 6,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
            style: theme.textTheme.titleLarge?.copyWith(letterSpacing: 8),
            decoration: const InputDecoration(counterText: ''),
            onChanged: (String value) {
              if (value.length == 6) {
                _verify(value);
              }
            },
          ),
          if (_busy) ...<Widget>[
            const SizedBox(height: 16),
            const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
          if (_error != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.error,
                fontSize: 13,
              ),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(L10n.t('取消')),
        ),
      ],
    );
  }
}

class AuthErrorBanner extends StatelessWidget {
  const AuthErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: scheme.onErrorContainer,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
