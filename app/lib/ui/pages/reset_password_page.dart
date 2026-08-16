import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/auth_controller.dart';
import '../app_scope.dart';
import 'login_page.dart';
import '../../l10n/l10n.dart';

class ResetPasswordPage extends StatefulWidget {
  const ResetPasswordPage({super.key});

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final GlobalKey<FormState> _emailFormKey = GlobalKey<FormState>();
  final GlobalKey<FormState> _confirmFormKey = GlobalKey<FormState>();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _token = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _repassword = TextEditingController();

  bool _stepConfirm = false;
  bool _obscure = true;
  bool _obscureRe = true;
  bool _entering = false;

  @override
  void dispose() {
    _email.dispose();
    _token.dispose();
    _password.dispose();
    _repassword.dispose();
    super.dispose();
  }

  Future<void> _request(AuthController auth) async {
    if (!_emailFormKey.currentState!.validate()) {
      return;
    }
    final bool ok = await auth.requestPasswordReset(
      email: _email.text.trim(),
    );
    if (!mounted || !ok) {
      return;
    }
    setState(() => _stepConfirm = true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(L10n.t('重置邮件已发送，请查收')),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _tokenFromInput(String raw) {
    final String trimmed = raw.trim();
    final Match? match = RegExp(
      r'/password/token/([^/?#]+)',
    ).firstMatch(trimmed);
    return match?.group(1) ?? trimmed;
  }

  Future<void> _confirm(AuthController auth) async {
    if (!_confirmFormKey.currentState!.validate() || _entering) {
      return;
    }
    final bool ok = await auth.confirmPasswordReset(
      email: _email.text.trim(),
      token: _tokenFromInput(_token.text),
      password: _password.text,
      repasswd: _repassword.text,
    );
    if (!mounted) {
      return;
    }
    if (ok) {
      setState(() => _entering = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.t('重置成功')),
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

  @override
  Widget build(BuildContext context) {
    final AuthController auth = AppScope.of(context).auth;
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(L10n.t('重置密码'))),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: ListenableBuilder(
              listenable: auth,
              builder: (BuildContext context, _) {
                return _stepConfirm
                    ? Form(
                        key: _confirmFormKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Text(
                              L10n.t('设置新密码'),
                              textAlign: TextAlign.center,
                              style: theme.textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              L10n.t('可粘贴邮件中的完整重置链接，或只填 token'),
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 24),
                            TextFormField(
                              controller: _token,
                              autocorrect: false,
                              enableSuggestions: false,
                              inputFormatters: <TextInputFormatter>[
                                asciiOnlyFormatter,
                              ],
                              decoration: InputDecoration(
                                labelText: L10n.t('重置链接或 Token'),
                                prefixIcon: Icon(Icons.key_outlined),
                              ),
                              validator: (String? value) =>
                                  (value == null || value.trim().isEmpty)
                                  ? L10n.t('请填写重置链接或 token')
                                  : null,
                            ),
                            const SizedBox(height: 16),
                            EmailOtpIme(
                              builder:
                                  (BuildContext context, FocusNode focusNode) {
                                return TextFormField(
                                  controller: _password,
                                  focusNode: focusNode,
                                  obscureText: _obscure,
                                  keyboardType: TextInputType.visiblePassword,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  inputFormatters: <TextInputFormatter>[
                                    asciiOnlyFormatter,
                                  ],
                                  decoration: InputDecoration(
                                    labelText: L10n.t('新密码'),
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
                                      return L10n.t('请填写密码');
                                    }
                                    if (value.length < 8) {
                                      return L10n.t('密码至少 8 位');
                                    }
                                    return null;
                                  },
                                );
                              },
                            ),
                            const SizedBox(height: 16),
                            EmailOtpIme(
                              builder:
                                  (BuildContext context, FocusNode focusNode) {
                                return TextFormField(
                                  controller: _repassword,
                                  focusNode: focusNode,
                                  obscureText: _obscureRe,
                                  keyboardType: TextInputType.visiblePassword,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  inputFormatters: <TextInputFormatter>[
                                    asciiOnlyFormatter,
                                  ],
                                  decoration: InputDecoration(
                                    labelText: L10n.t('确认密码'),
                                    prefixIcon: const Icon(Icons.lock_outline),
                                    suffixIcon: IconButton(
                                      icon: Icon(
                                        _obscureRe
                                            ? Icons.visibility_outlined
                                            : Icons.visibility_off_outlined,
                                      ),
                                      onPressed: () => setState(
                                        () => _obscureRe = !_obscureRe,
                                      ),
                                    ),
                                  ),
                                  validator: (String? value) {
                                    if (value == null || value.isEmpty) {
                                      return L10n.t('请再次填写密码');
                                    }
                                    if (value != _password.text) {
                                      return L10n.t('两次密码不一致');
                                    }
                                    return null;
                                  },
                                );
                              },
                            ),
                            if (auth.error != null) ...<Widget>[
                              const SizedBox(height: 8),
                              AuthErrorBanner(message: auth.error!),
                            ],
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: auth.busy || _entering
                                  ? null
                                  : () => _confirm(auth),
                              child: auth.busy || _entering
                                  ? const SizedBox(
                                      height: 18,
                                      width: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Text(L10n.t('确认重置')),
                            ),
                            TextButton(
                              onPressed: _entering
                                  ? null
                                  : () => setState(() => _stepConfirm = false),
                              child: Text(L10n.t('返回上一步')),
                            ),
                          ],
                        ),
                      )
                    : Form(
                        key: _emailFormKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Text(
                              L10n.t('找回密码'),
                              textAlign: TextAlign.center,
                              style: theme.textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              L10n.t('输入注册邮箱，我们会发送重置链接'),
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 24),
                            TextFormField(
                              controller: _email,
                              keyboardType: TextInputType.emailAddress,
                              autocorrect: false,
                              enableSuggestions: false,
                              decoration: InputDecoration(
                                labelText: L10n.t('邮箱'),
                                prefixIcon: Icon(Icons.mail_outline),
                              ),
                              validator: (String? value) =>
                                  (value == null || value.trim().isEmpty)
                                  ? L10n.t('请填写邮箱')
                                  : null,
                            ),
                            if (auth.error != null) ...<Widget>[
                              const SizedBox(height: 8),
                              AuthErrorBanner(message: auth.error!),
                            ],
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: auth.busy
                                  ? null
                                  : () => _request(auth),
                              child: auth.busy
                                  ? const SizedBox(
                                      height: 18,
                                      width: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Text(L10n.t('发送重置邮件')),
                            ),
                            TextButton(
                              onPressed: () => setState(() => _stepConfirm = true),
                              child: Text(L10n.t('已有重置 token？')),
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
