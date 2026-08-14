import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/api/api_exception.dart';
import '../../data/api/panel_api_client.dart';
import '../../data/models/account.dart';
import '../../data/models/user_profile.dart';
import '../../state/auth_controller.dart';
import '../app_scope.dart';
import '../widgets/page_header.dart';
import '../widgets/refresh_button.dart';
import '../widgets/section_card.dart';
import '../widgets/switch_tile.dart';
import '../widgets/tag_chip.dart';
import '../widgets/user_avatar.dart';
import 'balance_records_page.dart';
import 'delete_account_page.dart';
import 'edit_account_page.dart';
import 'invite_page.dart';
import 'login_logs_page.dart';
import 'purchases_page.dart';
import 'recharge_page.dart';
import 'subscription_strategy_page.dart';
import 'traffic_log_page.dart';
import 'usage_ips_page.dart';

Future<void> togglePurchaseAutoRenewDialog(
  BuildContext context, {
  required AuthController auth,
  required int purchaseId,
  required bool enable,
}) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(enable ? '确认开启自动续费？' : '确认关闭自动续费？'),
      content: Text(enable ? '开启后将在套餐到期时自动续费。' : '关闭后，您可以随时重新开启自动续费。'),
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
  if (confirmed != true || !context.mounted) {
    return;
  }

  final PanelApiClient? api = auth.api;
  if (api == null) {
    return;
  }

  try {
    final String message = await api.togglePurchaseAutoRenew(
      id: purchaseId,
      action: enable ? 'enable' : 'disable',
    );
    await auth.refreshProfile();
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message.isEmpty ? (enable ? '自动续费开启成功' : '自动续费关闭成功') : message,
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  } on ApiException catch (e) {
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating),
    );
  }
}

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  bool _enableKill = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadKillFlag());
    });
  }

  Future<void> _loadKillFlag() async {
    final AuthOptions? options =
        await AppScope.of(context).auth.fetchAuthOptions();
    if (!mounted || options == null) {
      return;
    }
    setState(() => _enableKill = options.enableKill);
  }

  @override
  Widget build(BuildContext context) {
    final AuthController auth = AppScope.of(context).auth;

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SafeArea(
            bottom: false,
            child: PageHeader(
              title: '账户信息',
              showBackButton: true,
              showUserAvatar: true,
              actions: <Widget>[
                RefreshButton(
                  tooltip: '刷新账号信息',
                  onRefresh: auth.refreshProfile,
                ),
              ],
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: auth,
              builder: (BuildContext context, _) {
                final UserProfile? profile = auth.profile;
                return ListView(
                  padding: const EdgeInsets.all(14),
                  children: <Widget>[
                    _UserCard(
                      profile: profile,
                      auth: auth,
                      enableKill: _enableKill,
                    ),
                    const SizedBox(height: 10),
                    SectionCard(
                      icon: Icons.menu,
                      title: '更多',
                      child: Column(
                        children: <Widget>[
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.edit_outlined, size: 20),
                            title: const Text('修改信息'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (BuildContext context) =>
                                    const EditAccountPage(),
                              ),
                            ),
                          ),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.tune, size: 20),
                            title: const Text('自定义策略'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (BuildContext context) =>
                                    const SubscriptionStrategyPage(),
                              ),
                            ),
                          ),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading:
                                const Icon(Icons.card_giftcard_outlined, size: 20),
                            title: const Text('邀请返利'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (BuildContext context) =>
                                    const InvitePage(),
                              ),
                            ),
                          ),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.data_usage, size: 20),
                            title: const Text('流量记录'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (BuildContext context) =>
                                    const TrafficLogPage(),
                              ),
                            ),
                          ),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.lan_outlined, size: 20),
                            title: const Text('使用 IP'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (BuildContext context) =>
                                    const UsageIpsPage(),
                              ),
                            ),
                          ),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.history, size: 20),
                            title: const Text('登录记录'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (BuildContext context) =>
                                    const LoginLogsPage(),
                              ),
                            ),
                          ),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(
                              Icons.account_balance_wallet_outlined,
                              size: 20,
                            ),
                            title: const Text('余额充值'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (BuildContext context) =>
                                    const RechargePage(),
                              ),
                            ),
                          ),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading:
                                const Icon(Icons.receipt_long_outlined, size: 20),
                            title: const Text('余额记录'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (BuildContext context) =>
                                    const BalanceRecordsPage(),
                              ),
                            ),
                          ),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading:
                                const Icon(Icons.shopping_bag_outlined, size: 20),
                            title: const Text('购买记录'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (BuildContext context) =>
                                    const PurchasesPage(),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _UserCard extends StatelessWidget {
  const _UserCard({
    required this.profile,
    required this.auth,
    required this.enableKill,
  });

  final UserProfile? profile;
  final AuthController auth;
  final bool enableKill;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final UserProfile? user = profile;

    if (user == null) {
      return const SectionCard(
        icon: Icons.person_outline,
        title: '账号',
        child: Text('—'),
      );
    }

    final UserPlan? plan = user.plan;

    return SectionCard(
      icon: Icons.person_outline,
      title: '账号',
      action: enableKill
          ? TextButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (BuildContext context) => const DeleteAccountPage(),
                ),
              ),
              icon: const Icon(Icons.block, size: 16),
              label: const Text('删除账号'),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              UserAvatar(profile: user, radius: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            user.displayName,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        const SizedBox(width: 6),
                        TagChip(label: 'ID ${user.id}'),
                      ],
                    ),
                    Text(
                      user.email,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Divider(height: 1),
          ),
          InfoRow(
            label: '余额',
            value: '¥ ${user.money.toStringAsFixed(2)}',
          ),
          InfoRow(
            label: '注册时间',
            value: user.regDate.isEmpty ? '—' : user.regDate,
          ),
          InfoRow(
            label: '套餐',
            value:
                plan?.name ??
                (user.userClass > 0 ? 'VIP ${user.userClass}' : '免费用户'),
          ),
          if (plan != null) ...<Widget>[
            InfoRow(label: '到期', value: plan.expireAt),
            InfoRow(label: '剩余天数', value: '${plan.remainingDays} 天'),
            InfoRow(label: '自动续费', value: plan.autoRenew ? plan.renewAt : '-'),
          ],
          InfoRow(
            label: '限速',
            value: user.speedLimitMbps <= 0
                ? '不限速'
                : '${user.speedLimitMbps.toStringAsFixed(0)} Mbps',
          ),
          InfoRow(
            label: '在线 IP',
            value: user.connectorLimit <= 0
                ? '${user.onlineIpCount} / 无限制'
                : '${user.onlineIpCount} / ${user.connectorLimit}',
          ),
          if (plan != null && plan.canToggleAutoRenew) ...<Widget>[
            const SizedBox(height: 4),
            SwitchTile(
              contentPadding: EdgeInsets.zero,
              title: '自动续费',
              subtitle: plan.autoRenew ? plan.renewAt : '已关闭',
              value: plan.autoRenew,
              onChanged: (bool value) => unawaited(
                togglePurchaseAutoRenewDialog(
                  context,
                  auth: auth,
                  purchaseId: plan.id,
                  enable: value,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
