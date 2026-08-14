import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/api/api_exception.dart';
import '../../data/models/account.dart';
import '../../state/auth_controller.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/page_header.dart';
import '../widgets/section_card.dart';
import 'tickets_page.dart';

class AccountStatusPage extends StatefulWidget {
  const AccountStatusPage({super.key});

  @override
  State<AccountStatusPage> createState() => _AccountStatusPageState();
}

class _AccountStatusPageState extends State<AccountStatusPage> {
  bool _busy = false;

  Future<void> _cancelDeletion(AuthController auth) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('确认取消删除请求吗？'),
        content: const Text('取消后，您的账户将恢复正常状态。'),
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

    setState(() => _busy = true);
    try {
      final String message = await auth.cancelAccountDeletion();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
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

  Future<void> _logout(AuthController auth) async {
    setState(() => _busy = true);
    try {
      await auth.logout();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AuthController auth = AppScope.of(context).auth;

    return ListenableBuilder(
      listenable: auth,
      builder: (BuildContext context, _) {
        final AccountStatus? status = auth.accountStatus;
        return Scaffold(
          body: Column(
            children: <Widget>[
              const PageHeader(title: '账户状态', showBackButton: false),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(14),
                  children: <Widget>[
                    if (status == null)
                      const SectionCard(
                        icon: Icons.info_outline,
                        title: '账户状态',
                        child: Text('无法获取账户状态'),
                      )
                    else if (status.isPendingDeletion)
                      _PendingDeletionCard(
                        status: status,
                        busy: _busy,
                        onCancel: () => unawaited(_cancelDeletion(auth)),
                      )
                    else if (status.isBanned)
                      _BannedCard(status: status)
                    else
                      const SectionCard(
                        icon: Icons.info_outline,
                        title: '账户状态',
                        child: Text('当前账户状态正常。'),
                      ),
                    const SizedBox(height: 10),
                    ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                      iconColor: Theme.of(context).colorScheme.error,
                      textColor: Theme.of(context).colorScheme.error,
                      leading: const Icon(Icons.logout),
                      title: const Text('退出登录'),
                      onTap: _busy ? null : () => unawaited(_logout(auth)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PendingDeletionCard extends StatelessWidget {
  const _PendingDeletionCard({
    required this.status,
    required this.busy,
    required this.onCancel,
  });

  final AccountStatus status;
  final bool busy;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      icon: Icons.delete_outline,
      title: '您的账户已提交删除请求',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('提交删除时间：${status.submitAccountDeletionTime ?? '未知'}'),
          const SizedBox(height: 6),
          Text('预计删除时间：${status.deletionTime ?? '未知'}'),
          const SizedBox(height: 6),
          const Text(
            '状态说明：您的账户将在30天后被彻底删除。在此期间，您可以取消删除请求以恢复账户。',
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: busy ? null : onCancel,
              icon: const Icon(Icons.history, size: 18),
              label: const Text('取消删除'),
            ),
          ),
        ],
      ),
    );
  }
}

class _BannedCard extends StatelessWidget {
  const _BannedCard({required this.status});

  final AccountStatus status;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SectionCard(
      icon: Icons.block,
      title: '你的账户已被封禁',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('封禁原因：${status.banReason ?? '特殊原因被封禁'}'),
          const SizedBox(height: 6),
          if (status.banPermanent ||
              (status.banTimeText == null || status.banTimeText!.isEmpty))
            const Text('封禁期限：永久封禁')
          else ...<Widget>[
            Text('封禁时长：${status.banTimeText}'),
            const SizedBox(height: 6),
            Text('封禁开始时间：${status.banStartTime ?? '未知'}'),
            const SizedBox(height: 6),
            Text('封禁结束时间：${status.banEndTime ?? '未知'}'),
          ],
          const SizedBox(height: 12),
          if (status.ticketEnabled)
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Text(
                  '如果我们错误地禁用了您的账户，请 ',
                  style: theme.textTheme.bodySmall,
                ),
                TextButton(
                  style: AppTheme.inlineTextLink(theme.colorScheme),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (BuildContext context) =>
                            const TicketsPage(showBackButton: true),
                      ),
                    );
                  },
                  child: const Text('发送工单'),
                ),
                Text(
                  ' 与我们联系。',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            )
          else if (status.supportEmail.isNotEmpty)
            InkWell(
              onTap: () => unawaited(
                AppScope.of(context).platform.openUrl(
                  'mailto:${status.supportEmail}',
                ),
              ),
              child: Text.rich(
                TextSpan(
                  style: theme.textTheme.bodySmall,
                  children: <InlineSpan>[
                    const TextSpan(text: '如果我们错误地禁用了您的账户，请通过邮箱：'),
                    TextSpan(
                      text: status.supportEmail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const TextSpan(text: ' 与我们联系。'),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
