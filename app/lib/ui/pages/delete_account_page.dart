import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/api/api_exception.dart';
import '../../data/api/panel_api_client.dart';
import '../../data/models/account.dart';
import '../../state/auth_controller.dart';
import '../../state/connection_controller.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/page_header.dart';
import '../widgets/section_card.dart';
import 'login_page.dart';
import '../../l10n/l10n.dart';

class DeleteAccountPage extends StatefulWidget {
  const DeleteAccountPage({super.key});

  @override
  State<DeleteAccountPage> createState() => _DeleteAccountPageState();
}

class _DeleteAccountPageState extends State<DeleteAccountPage> {
  final TextEditingController _emailCode = TextEditingController();
  final TextEditingController _passwd = TextEditingController();

  AuthOptions? _options;
  bool _loading = true;
  bool _busy = false;
  int _sendCooldown = 0;
  Timer? _cooldownTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadOptions());
    });
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _emailCode.dispose();
    _passwd.dispose();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    final AuthOptions? options = await AppScope.of(
      context,
    ).auth.fetchAuthOptions();
    if (!mounted) {
      return;
    }
    setState(() {
      _options = options;
      _loading = false;
    });
  }

  Future<void> _sendCode() async {
    if (_sendCooldown > 0 || _busy) {
      return;
    }
    final PanelApiClient? api = AppScope.of(context).auth.api;
    if (api == null) {
      return;
    }

    setState(() => _busy = true);
    try {
      final String message = await api.sendKillEmailCode();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      _startCooldown();
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
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

  Future<void> _submit() async {
    final AuthOptions? options = _options;
    if (options == null || _busy) {
      return;
    }

    if (options.emailVerify) {
      if (_emailCode.text.trim().isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(L10n.t('请先输入邮箱验证码'))));
        return;
      }
    } else if (_passwd.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(L10n.t('请先输入登录密码'))));
      return;
    }

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(L10n.t('确认提交删除请求吗？')),
        content: Text(L10n.t('提交后，您的账户将被禁用，并在 30 天后彻底删除。在此期间可取消删除。')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L10n.t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L10n.t('确定')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    final AuthController auth = AppScope.of(context).auth;
    final ConnectionController connection = AppScope.of(context).connection;
    final PanelApiClient? api = auth.api;
    if (api == null) {
      return;
    }

    setState(() => _busy = true);
    try {
      final AccountStatus status = await api.killAccount(
        emailCode: options.emailVerify ? _emailCode.text.trim() : null,
        passwd: options.emailVerify ? null : _passwd.text,
      );
      await connection.disconnect();
      auth.enterRestricted(status);
      if (!mounted) {
        return;
      }
      Navigator.of(context).popUntil((Route<dynamic> route) => route.isFirst);
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AuthOptions? options = _options;
    final String email = AppScope.of(context).auth.profile?.email ?? '';

    return Scaffold(
      body: Column(
        children: <Widget>[
          SafeArea(
            bottom: false,
            child: PageHeader(title: L10n.t('删除账号'), showBackButton: true),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: AppTheme.pageScrollPadding,
                    children: <Widget>[
                      if (options == null || !options.enableKill)
                        SectionCard(
                          icon: Icons.block,
                          title: L10n.t('功能已关闭'),
                          child: Text(L10n.t('管理员已关闭账号删除功能。如需删除账号，请联系管理员。')),
                        )
                      else ...<Widget>[
                        SectionCard(
                          icon: Icons.warning_amber_outlined,
                          title: L10n.t('注意！'),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                L10n.t(
                                  '提交删除账号请求后，您的账户将被禁用，并在 30 天后从系统中彻底删除。在此期间，您可以登录并取消删除请求以恢复账户。',
                                ),
                              ),
                              SizedBox(height: 8),
                              Text(
                                L10n.t('删除后，账号及相关数据（包括余额、有效套餐等）都将被删除，请谨慎操作！'),
                              ),
                              SizedBox(height: 8),
                              Text(
                                L10n.t('当然账号删除后如果您还想继续使用本服务，您随时可以回来重新注册账号。'),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        SectionCard(
                          icon: Icons.verified_user_outlined,
                          title: options.emailVerify
                              ? L10n.t('输入邮箱验证码以验证身份')
                              : L10n.t('输入登录密码以验证身份'),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              if (options.emailVerify) ...<Widget>[
                                Text(
                                  L10n.t('删除账号验证码将发送到 {0} 邮箱', <Object>[email]),
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                ),
                                const SizedBox(height: 10),
                                EmailOtpIme(
                                  builder:
                                      (
                                        BuildContext context,
                                        FocusNode focusNode,
                                      ) {
                                        return TextField(
                                          controller: _emailCode,
                                          focusNode: focusNode,
                                          enabled: !_busy,
                                          keyboardType:
                                              TextInputType.visiblePassword,
                                          textCapitalization:
                                              TextCapitalization.characters,
                                          inputFormatters: <TextInputFormatter>[
                                            OtpCodeFormatter(),
                                          ],
                                          decoration: InputDecoration(
                                            labelText: L10n.t('邮箱验证码（必填）'),
                                          ),
                                        );
                                      },
                                ),
                              ] else
                                EmailOtpIme(
                                  builder:
                                      (
                                        BuildContext context,
                                        FocusNode focusNode,
                                      ) {
                                        return TextField(
                                          controller: _passwd,
                                          focusNode: focusNode,
                                          enabled: !_busy,
                                          obscureText: true,
                                          keyboardType:
                                              TextInputType.visiblePassword,
                                          autocorrect: false,
                                          enableSuggestions: false,
                                          inputFormatters: <TextInputFormatter>[
                                            asciiOnlyFormatter,
                                          ],
                                          decoration: InputDecoration(
                                            labelText: L10n.t('登录密码（必填）'),
                                          ),
                                        );
                                      },
                                ),
                              const SizedBox(height: 14),
                              Wrap(
                                spacing: 12,
                                runSpacing: 8,
                                children: <Widget>[
                                  if (options.emailVerify)
                                    OutlinedButton.icon(
                                      onPressed: _busy || _sendCooldown > 0
                                          ? null
                                          : () => unawaited(_sendCode()),
                                      icon: const Icon(
                                        Icons.mail_outline,
                                        size: 18,
                                      ),
                                      label: Text(
                                        _sendCooldown > 0
                                            ? L10n.t('获取验证码 ({0}s)', <Object>[
                                                _sendCooldown,
                                              ])
                                            : L10n.t('获取验证码'),
                                      ),
                                    ),
                                  FilledButton.icon(
                                    onPressed: _busy
                                        ? null
                                        : () => unawaited(_submit()),
                                    icon: const Icon(Icons.check, size: 18),
                                    label: Text(L10n.t('提交删除请求')),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
