import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../data/api/api_exception.dart';
import '../../data/api/panel_api_client.dart';
import '../../data/models/account.dart';
import '../../state/auth_controller.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/option_dropdown.dart';
import '../widgets/page_header.dart';
import '../widgets/section_card.dart';
import '../widgets/switch_tile.dart';
import 'login_page.dart';

class EditAccountPage extends StatefulWidget {
  const EditAccountPage({super.key});

  @override
  State<EditAccountPage> createState() => _EditAccountPageState();
}

class _EditAccountPageState extends State<EditAccountPage> {
  final TextEditingController _username = TextEditingController();
  final TextEditingController _oldPwd = TextEditingController();
  final TextEditingController _pwd = TextEditingController();
  final TextEditingController _repwd = TextEditingController();
  final TextEditingController _oldEmailCode = TextEditingController();
  final TextEditingController _newEmail = TextEditingController();
  final TextEditingController _newEmailCode = TextEditingController();
  final TextEditingController _gaCode = TextEditingController();

  AuthOptions? _options;
  EditAccountOptions? _editOptions;
  Map<String, bool> _mailPrefs = <String, bool>{};
  int _gaEnableDraft = 0;
  bool _loadingOptions = true;
  bool _busy = false;
  int _oldEmailCountdown = 0;
  int _newEmailCountdown = 0;
  Timer? _oldCooldownTimer;
  Timer? _newCooldownTimer;
  Timer? _tgPollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadOptions());
    });
  }

  @override
  void dispose() {
    _oldCooldownTimer?.cancel();
    _newCooldownTimer?.cancel();
    _tgPollTimer?.cancel();
    _username.dispose();
    _oldPwd.dispose();
    _pwd.dispose();
    _repwd.dispose();
    _oldEmailCode.dispose();
    _newEmail.dispose();
    _newEmailCode.dispose();
    _gaCode.dispose();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    final PanelApiClient? api = AppScope.of(context).auth.api;
    final AuthOptions? options =
        await AppScope.of(context).auth.fetchAuthOptions();
    EditAccountOptions? edit;
    if (api != null) {
      try {
        edit = await api.fetchEditOptions();
      } on Object {
        edit = null;
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _options = options;
      _editOptions = edit;
      _gaEnableDraft = edit?.gaEnable ?? 0;
      _mailPrefs = Map<String, bool>.from(
        edit?.mailNotifyPreferences ?? const <String, bool>{},
      );
      _loadingOptions = false;
    });
    if (edit != null && edit.enableTelegram && !edit.telegramBound) {
      _startTelegramPoll();
    }
  }

  void _startTelegramPoll() {
    _tgPollTimer?.cancel();
    _tgPollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_pollTelegram());
    });
  }

  Future<void> _pollTelegram() async {
    final PanelApiClient? api = AppScope.of(context).auth.api;
    final EditAccountOptions? current = _editOptions;
    if (api == null || current == null || current.telegramBound) {
      _tgPollTimer?.cancel();
      return;
    }
    try {
      final ({bool bound, String imValue, int telegramId}) result =
          await api.telegramBindCheck();
      if (!mounted || !result.bound) {
        return;
      }
      _tgPollTimer?.cancel();
      setState(() {
        _editOptions = current.copyWith(
          telegramId: result.telegramId > 0
              ? result.telegramId
              : current.telegramId,
          imValue: result.imValue,
          bindToken: '',
        );
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Telegram 绑定成功'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on Object {
      // 轮询失败忽略
    }
  }

  Future<void> _run(
    Future<String> Function(PanelApiClient api) action, {
    VoidCallback? onSuccess,
    bool logoutAfter = false,
  }) async {
    final PanelApiClient? api = AppScope.of(context).auth.api;
    if (api == null || _busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final String msg = await action(api);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg.isEmpty ? '操作成功' : msg),
          behavior: SnackBarBehavior.floating,
        ),
      );
      onSuccess?.call();
      if (logoutAfter) {
        await AppScope.of(context).auth.logout();
      } else {
        await AppScope.of(context).auth.refreshProfile();
      }
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating),
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制$label'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _saveGa() async {
    final EditAccountOptions? edit = _editOptions;
    if (edit == null) {
      return;
    }
    final int enable = _gaEnableDraft;
    if (enable == 1) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('您确定要开启两步验证吗？'),
          content: const Text(
            '开启后每次登录都需要输入验证器上的 6 位验证码。请确认已完成测试并通过验证。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) {
        return;
      }
    }
    await _run(
      (PanelApiClient api) => api.gaSet(enable),
      onSuccess: () {
        setState(() {
          _editOptions = edit.copyWith(gaEnable: enable);
          _gaEnableDraft = enable;
        });
      },
    );
  }

  Future<void> _resetGa() async {
    final EditAccountOptions? edit = _editOptions;
    final PanelApiClient? api = AppScope.of(context).auth.api;
    if (edit == null || api == null || _busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final ({String message, String gaToken, String gaUrl}) result =
          await api.gaReset();
      if (!mounted) {
        return;
      }
      setState(() {
        _editOptions = edit.copyWith(
          gaToken: result.gaToken,
          gaUrl: result.gaUrl,
        );
        _busy = false;
      });
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.message.isEmpty ? '两步验证密钥已重置' : result.message,
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _confirmTelegramUnbind(EditAccountOptions edit) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        final ColorScheme scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          title: const Text('您确定要解除Telegram绑定吗？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text.rich(
                TextSpan(
                  style: Theme.of(context).textTheme.bodyMedium,
                  children: <InlineSpan>[
                    const TextSpan(text: '注意：您点击 '),
                    TextSpan(
                      text: '确定',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppTheme.danger,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const TextSpan(
                      text: ' 按钮之后系统会解除你本站账号与Telegram Bot的绑定。',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '解绑之后您就不能通过Telegram Bot使用相关功能了。当然您随时可以回来这个页面重新绑定。',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (edit.telegramUnbindKick) ...<Widget>[
                const SizedBox(height: 10),
                Text(
                  '注意：如果你加入了 Telegram 用户群或频道，解绑后您将被自动移出用户群和频道，重新绑定后可再次申请加入。',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppTheme.danger,
                  ),
                ),
              ],
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(foregroundColor: scheme.onSurface),
              child: const Text('确定'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) {
      return;
    }

    final PanelApiClient? api = AppScope.of(context).auth.api;
    if (api == null || _busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final ({String message, String bindToken}) result =
          await api.telegramReset();
      if (!mounted) {
        return;
      }
      setState(() {
        _editOptions = edit.copyWith(
          telegramId: 0,
          imValue: '',
          bindToken: result.bindToken,
        );
        _busy = false;
      });
      _startTelegramPoll();
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.message.isEmpty ? '已解绑' : result.message),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating),
      );
    }
  }

  void _startCountdown(bool oldEmail) {
    if (oldEmail) {
      _oldCooldownTimer?.cancel();
      setState(() => _oldEmailCountdown = 60);
      _oldCooldownTimer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        if (_oldEmailCountdown <= 1) {
          t.cancel();
          setState(() => _oldEmailCountdown = 0);
          return;
        }
        setState(() => _oldEmailCountdown -= 1);
      });
    } else {
      _newCooldownTimer?.cancel();
      setState(() => _newEmailCountdown = 60);
      _newCooldownTimer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        if (_newEmailCountdown <= 1) {
          t.cancel();
          setState(() => _newEmailCountdown = 0);
          return;
        }
        setState(() => _newEmailCountdown -= 1);
      });
    }
  }

  List<MapEntry<String, String>> _visibleMailKeys(EditAccountOptions opts) {
    final Map<String, dynamic> s = opts.mailNotifySettings;
    final List<MapEntry<String, String>> keys = <MapEntry<String, String>>[
      const MapEntry<String, String>('account_expire', '账户过期'),
      const MapEntry<String, String>('vip_expire', 'VIP过期'),
    ];
    final Object? limitMode = s['notify_limit_mode'];
    final bool showTrafficGroup = limitMode?.toString() != 'false' ||
        s['notify_exhaust_mode'] == true ||
        s['notify_free_user_traffic_reset'] == true ||
        s['notify_traffic_reset'] == true;
    if (showTrafficGroup) {
      if (limitMode?.toString() != 'false') {
        keys.add(const MapEntry<String, String>('traffic_low', '流量不足'));
      }
      if (s['notify_exhaust_mode'] == true) {
        keys.add(const MapEntry<String, String>('traffic_exhausted', '流量耗尽'));
      }
      if (s['notify_free_user_traffic_reset'] == true) {
        keys.add(
          const MapEntry<String, String>('free_traffic_reset', '免费用户流量重置'),
        );
      }
      if (s['notify_traffic_reset'] == true) {
        keys.add(
          const MapEntry<String, String>('vip_traffic_reset', 'VIP用户流量重置'),
        );
      }
    }
    if (s['recharge_send_email'] == true) {
      keys.add(const MapEntry<String, String>('recharge', '充值余额'));
    }
    if (s['shop_send_email'] == true) {
      keys.add(const MapEntry<String, String>('shop_purchase', '购买商品'));
    }
    if (s['mail_ticket'] == true) {
      keys
        ..add(const MapEntry<String, String>('ticket_create', '管理员创建工单'))
        ..add(const MapEntry<String, String>('ticket_reply', '管理员回复工单'));
    }
    keys
      ..add(const MapEntry<String, String>('announcement', '公告通知'))
      ..add(const MapEntry<String, String>('marketing', '营销邮件'));
    return keys;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AuthController auth = AppScope.of(context).auth;
    final String currentUserName = auth.profile?.userName ?? '';
    final String currentEmail = auth.profile?.email ?? '';
    final bool enableChangeEmail = _options?.enableChangeEmail == true;
    final bool emailVerify = _options?.emailVerify == true;
    final EditAccountOptions? edit = _editOptions;

    return Scaffold(
      body: Column(
        children: <Widget>[
          const SafeArea(
            bottom: false,
            child: PageHeader(
              title: '修改信息',
              showBackButton: true,
              showUserAvatar: true,
            ),
          ),
          Expanded(
            child: _loadingOptions
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.all(14),
                    children: <Widget>[
                SectionCard(
                  icon: Icons.badge_outlined,
                  title: '修改用户名',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text.rich(
                        TextSpan(
                          style: theme.textTheme.bodyMedium,
                          children: <InlineSpan>[
                            const TextSpan(text: '当前用户名：'),
                            TextSpan(
                              text: currentUserName,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _username,
                        decoration: const InputDecoration(
                          labelText: '新用户名',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton(
                          onPressed: _busy
                              ? null
                              : () => unawaited(
                                  _run(
                                    (PanelApiClient api) =>
                                        api.updateUsername(_username.text.trim()),
                                  ),
                                ),
                          child: const Text('保存'),
                        ),
                      ),
                    ],
                  ),
                ),
                if (enableChangeEmail) ...<Widget>[
                  const SizedBox(height: 10),
                  SectionCard(
                    icon: Icons.mail_outline,
                    title: '修改邮箱',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text.rich(
                          TextSpan(
                            style: theme.textTheme.bodyMedium,
                            children: <InlineSpan>[
                              const TextSpan(text: '当前邮箱：'),
                              TextSpan(
                                text: currentEmail,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (emailVerify) ...<Widget>[
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: <Widget>[
                              Expanded(
                                child: EmailOtpIme(
                                  builder:
                                      (
                                        BuildContext context,
                                        FocusNode focusNode,
                                      ) {
                                    return TextField(
                                      controller: _oldEmailCode,
                                      focusNode: focusNode,
                                      keyboardType:
                                          TextInputType.visiblePassword,
                                      inputFormatters: <TextInputFormatter>[
                                        OtpCodeFormatter(),
                                      ],
                                      decoration: const InputDecoration(
                                        labelText: '原邮箱验证码',
                                        prefixIcon: Icon(Icons.pin_outlined),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(width: 12),
                              SizedBox(
                                height: loginFieldHeight(theme),
                                child: OutlinedButton(
                                  onPressed: _busy || _oldEmailCountdown > 0
                                      ? null
                                      : () => unawaited(
                                          _run(
                                            (PanelApiClient api) =>
                                                api.sendOldEmailVerify(),
                                            onSuccess: () =>
                                                _startCountdown(true),
                                          ),
                                        ),
                                  child: Text(
                                    _oldEmailCountdown > 0
                                        ? '${_oldEmailCountdown}s'
                                        : '发送',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                        ],
                        TextField(
                          controller: _newEmail,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(
                            labelText: '新邮箱',
                            prefixIcon: Icon(Icons.mail_outline),
                          ),
                        ),
                        if (emailVerify) ...<Widget>[
                          const SizedBox(height: 12),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: <Widget>[
                              Expanded(
                                child: EmailOtpIme(
                                  builder:
                                      (
                                        BuildContext context,
                                        FocusNode focusNode,
                                      ) {
                                    return TextField(
                                      controller: _newEmailCode,
                                      focusNode: focusNode,
                                      keyboardType:
                                          TextInputType.visiblePassword,
                                      inputFormatters: <TextInputFormatter>[
                                        OtpCodeFormatter(),
                                      ],
                                      decoration: const InputDecoration(
                                        labelText: '新邮箱验证码',
                                        prefixIcon: Icon(Icons.pin_outlined),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(width: 12),
                              SizedBox(
                                height: loginFieldHeight(theme),
                                child: OutlinedButton(
                                  onPressed: _busy || _newEmailCountdown > 0
                                      ? null
                                      : () => unawaited(
                                          _run(
                                            (PanelApiClient api) =>
                                                api.sendNewEmailVerify(
                                                  email: _newEmail.text.trim(),
                                                ),
                                            onSuccess: () =>
                                                _startCountdown(false),
                                          ),
                                        ),
                                  child: Text(
                                    _newEmailCountdown > 0
                                        ? '${_newEmailCountdown}s'
                                        : '发送',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton(
                            onPressed: _busy
                                ? null
                                : () => unawaited(
                                    _run(
                                      (PanelApiClient api) => api.updateEmail(
                                        newemail: _newEmail.text.trim(),
                                        oldEmailcode: _oldEmailCode.text.trim(),
                                        newEmailcode: _newEmailCode.text.trim(),
                                      ),
                                    ),
                                  ),
                            child: const Text('换绑邮箱'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                SectionCard(
                  icon: Icons.lock_outline,
                  title: '修改密码',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      TextField(
                        controller: _oldPwd,
                        obscureText: true,
                        inputFormatters: <TextInputFormatter>[
                          asciiOnlyFormatter,
                        ],
                        decoration: const InputDecoration(
                          labelText: '当前密码',
                          prefixIcon: Icon(Icons.lock_outline),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _pwd,
                        obscureText: true,
                        inputFormatters: <TextInputFormatter>[
                          asciiOnlyFormatter,
                        ],
                        decoration: const InputDecoration(
                          labelText: '新密码',
                          prefixIcon: Icon(Icons.lock_outline),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _repwd,
                        obscureText: true,
                        inputFormatters: <TextInputFormatter>[
                          asciiOnlyFormatter,
                        ],
                        decoration: const InputDecoration(
                          labelText: '确认新密码',
                          prefixIcon: Icon(Icons.lock_outline),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '修改密码后需重新登录',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton(
                          onPressed: _busy
                              ? null
                              : () => unawaited(
                                  _run(
                                    (PanelApiClient api) => api.updatePassword(
                                      oldpwd: _oldPwd.text,
                                      pwd: _pwd.text,
                                      repwd: _repwd.text,
                                    ),
                                    logoutAfter: true,
                                  ),
                                ),
                          child: const Text('修改密码'),
                        ),
                      ),
                    ],
                  ),
                ),
                if (edit != null) ...<Widget>[
                  const SizedBox(height: 10),
                  SectionCard(
                    icon: Icons.phonelink_lock_outlined,
                    title: '两步验证',
                    action: TextButton(
                      onPressed: _busy ? null : () => unawaited(_resetGa()),
                      child: const Text('重置密钥'),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text(
                          '请使用验证器扫描下方二维码。在测试通过前请不要启用。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (edit.gaUrl.isNotEmpty)
                          Center(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: theme.colorScheme.outlineVariant,
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: QrImageView(
                                  data: edit.gaUrl,
                                  version: QrVersions.auto,
                                  size: 180,
                                  backgroundColor: Colors.white,
                                  eyeStyle: const QrEyeStyle(
                                    eyeShape: QrEyeShape.square,
                                    color: Colors.black,
                                  ),
                                  dataModuleStyle: const QrDataModuleStyle(
                                    dataModuleShape: QrDataModuleShape.square,
                                    color: Colors.black,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        SelectableText(
                          '密钥：${edit.gaToken}',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                edit.gaUrl,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                            IconButton(
                              tooltip: '复制密钥',
                              onPressed: () =>
                                  unawaited(_copy('密钥', edit.gaToken)),
                              icon: const Icon(Icons.key, size: 18),
                            ),
                            IconButton(
                              tooltip: '复制 otpauth',
                              onPressed: () =>
                                  unawaited(_copy('otpauth 链接', edit.gaUrl)),
                              icon: const Icon(Icons.link, size: 18),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _gaCode,
                          inputFormatters: <TextInputFormatter>[
                            OtpCodeFormatter(),
                          ],
                          decoration: const InputDecoration(
                            labelText: '测试验证码',
                            prefixIcon: Icon(Icons.pin_outlined),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton(
                            onPressed: _busy
                                ? null
                                : () => unawaited(
                                    _run(
                                      (PanelApiClient api) =>
                                          api.gaCheck(_gaCode.text.trim()),
                                    ),
                                  ),
                            child: const Text('测试'),
                          ),
                        ),
                        const SizedBox(height: 12),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('验证设置'),
                          subtitle: Text(
                            '已保存：${edit.gaEnable == 1 ? '要求验证' : '不要求'}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          trailing: OptionDropdown<int>(
                            value: _gaEnableDraft,
                            width: 120,
                            enabled: !_busy,
                            options: const <int, String>{
                              0: '不要求',
                              1: '要求验证',
                            },
                            onChanged: (int value) {
                              setState(() => _gaEnableDraft = value);
                            },
                          ),
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FilledButton(
                            onPressed:
                                _busy ? null : () => unawaited(_saveGa()),
                            child: const Text('保存'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (edit.enableTelegram) ...<Widget>[
                    const SizedBox(height: 10),
                    SectionCard(
                      icon: Icons.chat_outlined,
                      title: '绑定 Telegram Bot',
                      child: edit.telegramBound
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                _TelegramBoundLine(edit: edit),
                                if (edit.telegramUnbindKick) ...<Widget>[
                                  const SizedBox(height: 8),
                                  Text(
                                    '解绑后将被移出 Telegram 用户群/频道。',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.error,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 12),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: OutlinedButton(
                                    onPressed: _busy
                                        ? null
                                        : () => unawaited(
                                            _confirmTelegramUnbind(edit),
                                          ),
                                    child: const Text('解除绑定'),
                                  ),
                                ),
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                Text(
                                  '绑定后可通过 Telegram Bot 签到、查询等。绑定码约 10 分钟有效。',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                SelectableText(
                                  '绑定码：${edit.bindToken}',
                                  style: theme.textTheme.bodySmall,
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: <Widget>[
                                    OutlinedButton.icon(
                                      onPressed: () => unawaited(
                                        _copy('绑定码', edit.bindToken),
                                      ),
                                      icon: const Icon(Icons.copy, size: 16),
                                      label: const Text('复制绑定码'),
                                    ),
                                    FilledButton.icon(
                                      onPressed: edit.telegramBot.isEmpty
                                          ? null
                                          : () {
                                              final String url =
                                                  'https://t.me/${edit.telegramBot}?start=${edit.bindToken}';
                                              unawaited(
                                                AppScope.of(context)
                                                    .platform
                                                    .openUrl(url),
                                              );
                                            },
                                      icon: const Icon(Icons.open_in_new,
                                          size: 16),
                                      label: Text(
                                        edit.telegramBot.isEmpty
                                            ? '一键绑定'
                                            : '一键绑定 @${edit.telegramBot}',
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  SectionCard(
                    icon: Icons.notifications_outlined,
                    title: '邮件通知偏好',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        for (final MapEntry<String, String> entry
                            in _visibleMailKeys(edit))
                          SwitchTile(
                            contentPadding: EdgeInsets.zero,
                            title: entry.value,
                            value: _mailPrefs[entry.key] ?? true,
                            onChanged: (bool value) {
                              setState(() {
                                _mailPrefs[entry.key] = value;
                              });
                            },
                          ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton(
                            onPressed: _busy
                                ? null
                                : () => unawaited(
                                    _run(
                                      (PanelApiClient api) =>
                                          api.updateMailNotify(_mailPrefs),
                                      onSuccess: () {
                                        setState(() {
                                          _editOptions = edit.copyWith(
                                            mailNotifyPreferences:
                                                Map<String, bool>.from(
                                              _mailPrefs,
                                            ),
                                          );
                                        });
                                      },
                                    ),
                                  ),
                            child: const Text('保存偏好'),
                          ),
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

/// 对齐网站 [User::imValue]：用户名 → t.me，Telegram ID → tg://user?id=
class _TelegramBoundLine extends StatelessWidget {
  const _TelegramBoundLine({required this.edit});

  final EditAccountOptions edit;

  @override
  Widget build(BuildContext context) {
    final int id = edit.telegramId;
    final String im = edit.imValue.trim();
    final bool hasUsername =
        im.isNotEmpty && im != '未设置用户名' && im != '$id';

    final List<Widget> links = <Widget>[
      if (hasUsername)
        _TelegramLink(label: '@$im', url: 'https://t.me/$im'),
      if (id > 0) _TelegramLink(label: '$id', url: 'tg://user?id=$id'),
    ];

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        const Text('当前绑定：'),
        for (int i = 0; i < links.length; i++) ...<Widget>[
          if (i > 0) const Text(' / '),
          links[i],
        ],
        if (links.isEmpty) Text(im.isEmpty ? '$id' : im),
      ],
    );
  }
}

class _TelegramLink extends StatelessWidget {
  const _TelegramLink({required this.label, required this.url});

  final String label;
  final String url;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => unawaited(AppScope.of(context).platform.openUrl(url)),
        child: Tooltip(
          message: url,
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: scheme.primary,
              decoration: TextDecoration.underline,
              decorationColor: scheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}
