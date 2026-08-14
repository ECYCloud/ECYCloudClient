import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models/account.dart';
import '../../state/auth_controller.dart';
import '../app_scope.dart';
import 'login_page.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _repassword = TextEditingController();
  final TextEditingController _invite = TextEditingController();
  final TextEditingController _emailCode = TextEditingController();

  AuthOptions? _options;
  String? _loadError;
  bool _obscure = true;
  bool _obscureRe = true;
  bool _entering = false;
  bool _loadingOptions = true;
  int _sendCooldown = 0;
  Timer? _cooldownTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_loadOptions()));
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _repassword.dispose();
    _invite.dispose();
    _emailCode.dispose();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    final AuthController auth = AppScope.of(context).auth;
    setState(() {
      _loadingOptions = true;
      _loadError = null;
    });
    final AuthOptions? options = await auth.fetchAuthOptions();
    if (!mounted) {
      return;
    }
    if (options == null) {
      setState(() {
        _loadingOptions = false;
        _loadError = auth.error ?? '无法加载注册选项';
      });
      return;
    }
    setState(() {
      _options = options;
      _loadingOptions = false;
    });
  }

  Future<void> _submit(AuthController auth) async {
    if (!_formKey.currentState!.validate() || _entering) {
      return;
    }
    final AuthOptions? options = _options;
    if (options == null || options.registrationClosed) {
      return;
    }

    final bool ok = await auth.register(
      name: _name.text.trim(),
      email: _email.text.trim(),
      passwd: _password.text,
      repasswd: _repassword.text,
      code: _invite.text.trim(),
      emailcode: _emailCode.text.trim(),
    );
    if (!mounted) {
      return;
    }
    if (ok) {
      setState(() => _entering = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('注册成功'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(milliseconds: 900),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (!mounted) {
        return;
      }
      final NavigatorState nav = Navigator.of(context);
      auth.enterShell();
      nav.popUntil((Route<dynamic> route) => route.isFirst);
    }
  }

  Future<void> _sendCode(AuthController auth) async {
    final String email = _email.text.trim();
    if (email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先填写邮箱'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (_sendCooldown > 0 || auth.busy || _entering) {
      return;
    }

    final bool ok = await auth.sendRegisterVerify(email: email);
    if (!mounted || !ok) {
      return;
    }

    _startCooldown();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('验证码已发送，请查收邮件'),
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

  @override
  Widget build(BuildContext context) {
    final AuthController auth = AppScope.of(context).auth;
    final ThemeData theme = Theme.of(context);
    final AuthOptions? options = _options;

    return Scaffold(
      appBar: AppBar(title: const Text('注册账号')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: _loadingOptions
                ? const Center(child: CircularProgressIndicator())
                : _loadError != null
                ? Column(
                    children: <Widget>[
                      AuthErrorBanner(message: _loadError!),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _loadOptions,
                        child: const Text('重试'),
                      ),
                    ],
                  )
                : options!.registrationClosed
                ? AuthErrorBanner(message: '当前未开放注册')
                : ListenableBuilder(
                    listenable: auth,
                    builder: (BuildContext context, _) {
                      return Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Text(
                              '创建账号',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 24),
                            TextFormField(
                              controller: _name,
                              autocorrect: false,
                              decoration: const InputDecoration(
                                labelText: '用户名',
                                prefixIcon: Icon(Icons.person_outline),
                              ),
                              validator: (String? value) =>
                                  (value == null || value.trim().isEmpty)
                                  ? '请填写用户名'
                                  : null,
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _email,
                              keyboardType: TextInputType.emailAddress,
                              autocorrect: false,
                              enableSuggestions: false,
                              decoration: const InputDecoration(
                                labelText: '邮箱',
                                prefixIcon: Icon(Icons.mail_outline),
                              ),
                              validator: (String? value) =>
                                  (value == null || value.trim().isEmpty)
                                  ? '请填写邮箱'
                                  : null,
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _password,
                              obscureText: _obscure,
                              autocorrect: false,
                              enableSuggestions: false,
                              inputFormatters: <TextInputFormatter>[
                                asciiOnlyFormatter,
                              ],
                              decoration: InputDecoration(
                                labelText: '密码',
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
                              validator: (String? value) {
                                if (value == null || value.isEmpty) {
                                  return '请填写密码';
                                }
                                if (value.length < 8) {
                                  return '密码至少 8 位';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _repassword,
                              obscureText: _obscureRe,
                              autocorrect: false,
                              enableSuggestions: false,
                              inputFormatters: <TextInputFormatter>[
                                asciiOnlyFormatter,
                              ],
                              decoration: InputDecoration(
                                labelText: '确认密码',
                                prefixIcon: const Icon(Icons.lock_outline),
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _obscureRe
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                  ),
                                  onPressed: () =>
                                      setState(() => _obscureRe = !_obscureRe),
                                ),
                              ),
                              validator: (String? value) {
                                if (value == null || value.isEmpty) {
                                  return '请再次填写密码';
                                }
                                if (value != _password.text) {
                                  return '两次密码不一致';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _invite,
                              autocorrect: false,
                              enableSuggestions: false,
                              inputFormatters: <TextInputFormatter>[
                                asciiOnlyFormatter,
                              ],
                              decoration: InputDecoration(
                                labelText: options.inviteRequired
                                    ? '邀请码'
                                    : '邀请码（可选）',
                                prefixIcon: const Icon(Icons.card_giftcard_outlined),
                              ),
                              validator: (String? value) {
                                if (options.inviteRequired &&
                                    (value == null || value.trim().isEmpty)) {
                                  return '请填写邀请码';
                                }
                                return null;
                              },
                            ),
                            if (options.emailVerify) ...<Widget>[
                              const SizedBox(height: 16),
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
                                        return TextFormField(
                                          controller: _emailCode,
                                          focusNode: focusNode,
                                          keyboardType:
                                              TextInputType.visiblePassword,
                                          autocorrect: false,
                                          enableSuggestions: false,
                                          inputFormatters: <TextInputFormatter>[
                                            OtpCodeFormatter(),
                                          ],
                                          decoration: const InputDecoration(
                                            labelText: '邮箱验证码',
                                            prefixIcon: Icon(
                                              Icons.pin_outlined,
                                            ),
                                          ),
                                          validator: (String? value) =>
                                              (value == null ||
                                                  value.trim().isEmpty)
                                              ? '请填写验证码'
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
                                          auth.busy ||
                                              _entering ||
                                              _sendCooldown > 0
                                          ? null
                                          : () => _sendCode(auth),
                                      child: Text(
                                        _sendCooldown > 0
                                            ? '${_sendCooldown}s'
                                            : '获取验证码',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            if (auth.error != null) ...<Widget>[
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
                                  : const Text('注册'),
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
