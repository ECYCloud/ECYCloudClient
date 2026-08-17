import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/api/api_exception.dart';
import '../../data/api/panel_api_client.dart';
import '../../data/models/account.dart';
import '../app_scope.dart';
import '../widgets/list_toolbar.dart';
import '../widgets/option_dropdown.dart';
import '../widgets/page_header.dart';
import '../widgets/refresh_button.dart';
import '../widgets/section_card.dart';
import '../widgets/simple_data_table.dart';
import '../../l10n/l10n.dart';

class InvitePage extends StatefulWidget {
  const InvitePage({super.key});

  @override
  State<InvitePage> createState() => _InvitePageState();
}

class _InvitePageState extends State<InvitePage> {
  InviteSummary? _summary;
  String? _error;
  bool _busy = false;
  bool _started = false;

  int _invitedPage = 1;
  int _invitedPerPage = 10;
  String _invitedSearch = '';
  int _paybackPage = 1;
  int _paybackPerPage = 10;
  String _paybackSearch = '';
  int _withdrawPage = 1;
  int _withdrawPerPage = 10;
  String _withdrawSearch = '';

  Timer? _invitedDebounce;
  Timer? _paybackDebounce;
  Timer? _withdrawDebounce;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _invitedDebounce?.cancel();
    _paybackDebounce?.cancel();
    _withdrawDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final PanelApiClient? api = AppScope.of(context).auth.api;
    if (api == null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final InviteSummary summary = await api.fetchInviteSummary(
        invitedPage: _invitedPage,
        invitedLength: _invitedPerPage,
        invitedSearch: _invitedSearch,
        paybackPage: _paybackPage,
        paybackLength: _paybackPerPage,
        paybackSearch: _paybackSearch,
        withdrawPage: _withdrawPage,
        withdrawLength: _withdrawPerPage,
        withdrawSearch: _withdrawSearch,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _summary = summary;
        _invitedPage = summary.invitedCurrentPage;
        _invitedPerPage = summary.invitedPerPage;
        _paybackPage = summary.paybackCurrentPage;
        _paybackPerPage = summary.paybackPerPage;
        _withdrawPage = summary.withdrawCurrentPage;
        _withdrawPerPage = summary.withdrawPerPage;
        _busy = false;
      });
    } on Object catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = e is ApiException ? e.message : L10n.t('加载失败：{0}', <Object>[e]);
        _busy = false;
      });
    }
  }

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(L10n.t('已复制{0}', <Object>[label])),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _confirmReset() async {
    if (_busy) {
      return;
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(L10n.t('您确定要重置邀请链接吗？')),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text.rich(
                TextSpan(
                  children: <InlineSpan>[
                    TextSpan(text: L10n.t('注意：您点击 ')),
                    TextSpan(
                      text: L10n.t('确定'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: scheme.error,
                      ),
                    ),
                    TextSpan(text: L10n.t(' 按钮之后系统会立即重置您的邀请链接。此操作不可逆！')),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(L10n.t('重置后旧的邀请链接将失效，新的邀请链接将立即生效。')),
              const SizedBox(height: 8),
              Text(L10n.t('通过旧邀请链接注册的被邀请者，返利奖励仍有效，不会因邀请链接变更而受影响。')),
              const SizedBox(height: 8),
              Text(L10n.t('重置后请您将新的邀请链接发送给被邀请者。')),
            ],
          ),
        ),
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
    await _reset();
  }

  Future<void> _reset() async {
    final PanelApiClient? api = AppScope.of(context).auth.api;
    if (api == null || _busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final InviteResetResult result = await api.resetInviteCode();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.message.isEmpty
                ? L10n.t('已重置您的邀请链接，复制您的邀请链接发送给其他人！')
                : result.message,
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      await _load();
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _applyWithdraw() async {
    final InviteSummary? summary = _summary;
    final PanelApiClient? api = AppScope.of(context).auth.api;
    if (summary == null || api == null) {
      return;
    }
    final _WithdrawApplyResult? result = await showDialog<_WithdrawApplyResult>(
      context: context,
      builder: (BuildContext context) =>
          _WithdrawApplyDialog(summary: summary, api: api),
    );
    if (result == null || !mounted) {
      return;
    }
    try {
      final String msg = await api.applyWithdraw(
        amount: result.amount,
        channelId: result.channelId,
        accountInfo: result.accountInfo,
        saveAccount: result.saveAccount,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg.isEmpty ? L10n.t('提现成功') : msg),
          behavior: SnackBarBehavior.floating,
        ),
      );
      await AppScope.of(context).auth.refreshProfile();
      await _load();
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _cancelWithdraw(int recordId) async {
    final PanelApiClient? api = AppScope.of(context).auth.api;
    if (api == null) {
      return;
    }
    try {
      final String msg = await api.cancelWithdraw(recordId: recordId);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg.isEmpty ? L10n.t('已取消') : msg),
          behavior: SnackBarBehavior.floating,
        ),
      );
      await _load();
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final InviteSummary? summary = _summary;

    return Scaffold(
      body: Column(
        children: <Widget>[
          SafeArea(
            bottom: false,
            child: PageHeader(
              title: L10n.t('邀请返利'),
              showBackButton: true,
              showUserAvatar: true,
              actions: <Widget>[
                RefreshButton(tooltip: L10n.t('刷新'), onRefresh: _load),
              ],
            ),
          ),
          Expanded(
            child: _busy && summary == null
                ? const Center(child: CircularProgressIndicator())
                : _error != null && summary == null
                ? Center(child: Text(_error!))
                : summary == null
                ? const SizedBox.shrink()
                : ListView(
              padding: const EdgeInsets.all(14),
              children: <Widget>[
                SectionCard(
                  icon: Icons.link,
                  title: L10n.t('邀请信息'),
                  action: TextButton(
                    onPressed: _busy ? null : () => unawaited(_confirmReset()),
                    child: Text(L10n.t('重置链接 / 邀请码')),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(
                        L10n.t('邀请他人注册时，请将以下链接发送给被邀请者'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      _InviteCopyRow(
                        label: L10n.t('邀请链接'),
                        value: summary.inviteUrl,
                        onCopy: () => unawaited(_copy(L10n.t('邀请链接'), summary.inviteUrl)),
                      ),
                      const SizedBox(height: 8),
                      _InviteCopyRow(
                        label: L10n.t('邀请码'),
                        value: summary.code,
                        onCopy: () => unawaited(_copy(L10n.t('邀请码'), summary.code)),
                      ),
                      const Divider(height: 20),
                      InfoRow(
                        label: L10n.t('邀请人数'),
                        value: '${summary.invitedUsersCount}',
                      ),
                      InfoRow(
                        label: L10n.t('返利人数'),
                        value: '${summary.rebateUsersCount}',
                      ),
                      InfoRow(
                        label: L10n.t('累计返利'),
                        value: '¥ ${summary.paybacksSum.toStringAsFixed(2)}',
                      ),
                      InfoRow(
                        label: L10n.t('返利比例'),
                        value:
                            '${(summary.codePayback * 100).toStringAsFixed(0)}%',
                      ),
                      InfoRow(
                        label: L10n.t('每位受邀用户返利次数上限'),
                        value: '${summary.rebateFrequencyLimit}',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                SectionCard(
                  icon: Icons.account_balance_wallet_outlined,
                  title: L10n.t('提现'),
                  action: TextButton(
                    onPressed: _applyWithdraw,
                    child: Text(
                      summary.withdrawChannels.isEmpty ? L10n.t('提现到余额') : L10n.t('申请提现'),
                    ),
                  ),
                  child: Column(
                    children: <Widget>[
                      InfoRow(
                        label: L10n.t('可提现'),
                        value:
                            '¥ ${summary.withdrawBalance.toStringAsFixed(2)}',
                      ),
                      if (summary.enableWithdraw)
                        InfoRow(
                          label: L10n.t('提现中'),
                          value:
                              '¥ ${summary.pendingWithdraw.toStringAsFixed(2)}',
                        ),
                      InfoRow(
                        label: L10n.t('账户余额'),
                        value: '¥ ${summary.money.toStringAsFixed(2)}',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                SectionCard(
                  icon: Icons.people_outline,
                  title: L10n.t('邀请用户'),
                  child: Column(
                    children: <Widget>[
                      ListToolbar(
                        currentPage: summary.invitedCurrentPage,
                        lastPage: summary.invitedLastPage,
                        total: summary.invitedTotal,
                        perPage: _invitedPerPage,
                        searchHint: L10n.t('用户名 / 邮箱'),
                        onSearchChanged: (String value) {
                          _invitedDebounce?.cancel();
                          _invitedDebounce = Timer(
                            const Duration(milliseconds: 300),
                            () {
                              _invitedSearch = value.trim();
                              _invitedPage = 1;
                              unawaited(_load());
                            },
                          );
                        },
                        onPerPageChanged: (int value) {
                          _invitedPerPage = value;
                          _invitedPage = 1;
                          unawaited(_load());
                        },
                        onPageChanged: (int page) {
                          _invitedPage = page;
                          unawaited(_load());
                        },
                      ),
                      SimpleDataTable(
                        framed: false,
                        minWidth: 560,
                        columns: <String>[
                          L10n.t('用户ID'),
                          L10n.t('用户名'),
                          L10n.t('邮箱'),
                          L10n.t('注册时间'),
                        ],
                        emptyText: L10n.t('暂无邀请用户'),
                        rows: <List<Widget>>[
                          for (final InvitedUserItem user
                              in summary.invitedUsers)
                            <Widget>[
                              TableText('${user.id}'),
                              TableText(
                                user.userName.isEmpty ? '—' : user.userName,
                                bold: true,
                              ),
                              TableText(user.email),
                              TableText(user.regDate, muted: true),
                            ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                SectionCard(
                  icon: Icons.payments_outlined,
                  title: L10n.t('返利记录'),
                  child: Column(
                    children: <Widget>[
                      ListToolbar(
                        currentPage: summary.paybackCurrentPage,
                        lastPage: summary.paybackLastPage,
                        total: summary.paybackTotal,
                        perPage: _paybackPerPage,
                        searchHint: L10n.t('用户 ID'),
                        onSearchChanged: (String value) {
                          _paybackDebounce?.cancel();
                          _paybackDebounce = Timer(
                            const Duration(milliseconds: 300),
                            () {
                              _paybackSearch = value.trim();
                              _paybackPage = 1;
                              unawaited(_load());
                            },
                          );
                        },
                        onPerPageChanged: (int value) {
                          _paybackPerPage = value;
                          _paybackPage = 1;
                          unawaited(_load());
                        },
                        onPageChanged: (int page) {
                          _paybackPage = page;
                          unawaited(_load());
                        },
                      ),
                      SimpleDataTable(
                        framed: false,
                        minWidth: 480,
                        columns: <String>[
                          L10n.t('返利用户ID'),
                          L10n.t('返利金额'),
                          L10n.t('返利时间'),
                        ],
                        emptyText: L10n.t('暂无返利记录'),
                        rows: <List<Widget>>[
                          for (final PaybackItem item in summary.paybacks)
                            <Widget>[
                              TableText('${item.userId}'),
                              TableMoney(item.refGet),
                              TableText(item.datetime, muted: true),
                            ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                SectionCard(
                  icon: Icons.history,
                  title: L10n.t('提现记录'),
                  child: Column(
                    children: <Widget>[
                      ListToolbar(
                        currentPage: summary.withdrawCurrentPage,
                        lastPage: summary.withdrawLastPage,
                        total: summary.withdrawTotal,
                        perPage: _withdrawPerPage,
                        searchHint: L10n.t('渠道 / 金额'),
                        onSearchChanged: (String value) {
                          _withdrawDebounce?.cancel();
                          _withdrawDebounce = Timer(
                            const Duration(milliseconds: 300),
                            () {
                              _withdrawSearch = value.trim();
                              _withdrawPage = 1;
                              unawaited(_load());
                            },
                          );
                        },
                        onPerPageChanged: (int value) {
                          _withdrawPerPage = value;
                          _withdrawPage = 1;
                          unawaited(_load());
                        },
                        onPageChanged: (int page) {
                          _withdrawPage = page;
                          unawaited(_load());
                        },
                      ),
                      SimpleDataTable(
                        framed: false,
                        minWidth: 640,
                        columns: <String>[
                          L10n.t('金额'),
                          L10n.t('提现方式'),
                          L10n.t('状态'),
                          L10n.t('申请时间'),
                          L10n.t('操作'),
                        ],
                        emptyText: L10n.t('暂无提现记录'),
                        rows: <List<Widget>>[
                          for (final WithdrawRecordItem item
                              in summary.withdrawRecords)
                            <Widget>[
                              TableMoney(item.amount),
                              TableText(item.channel),
                              TableText(item.statusText),
                              TableText(item.createdAt, muted: true),
                              item.isPending
                                  ? TextButton(
                                      onPressed: () => unawaited(
                                        _cancelWithdraw(item.id),
                                      ),
                                      child: Text(L10n.t('取消')),
                                    )
                                  : const TableText('-', muted: true),
                            ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InviteCopyRow extends StatelessWidget {
  const _InviteCopyRow({
    required this.label,
    required this.value,
    required this.onCopy,
  });

  final String label;
  final String value;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(label, style: theme.textTheme.bodySmall),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            IconButton(
              tooltip: L10n.t('复制{0}', <Object>[label]),
              onPressed: onCopy,
              icon: const Icon(Icons.copy, size: 18),
            ),
          ],
        ),
      ],
    );
  }
}

class _WithdrawApplyResult {
  const _WithdrawApplyResult({
    required this.amount,
    required this.channelId,
    this.accountInfo = const <String, String>{},
    this.saveAccount = false,
  });

  final double amount;
  final String channelId;
  final Map<String, String> accountInfo;
  final bool saveAccount;
}

class _WithdrawApplyDialog extends StatefulWidget {
  const _WithdrawApplyDialog({required this.summary, required this.api});

  final InviteSummary summary;
  final PanelApiClient api;

  @override
  State<_WithdrawApplyDialog> createState() => _WithdrawApplyDialogState();
}

class _WithdrawApplyDialogState extends State<_WithdrawApplyDialog> {
  final TextEditingController _amount = TextEditingController();
  String _channelId = 'balance';
  String _savedAccountId = '';
  bool _saveAccount = false;
  bool _fieldsBusy = false;
  String? _fieldsError;
  String? _amountError;
  List<WithdrawChannelField> _fields = const <WithdrawChannelField>[];
  List<WithdrawSavedAccount> _savedAccounts = const <WithdrawSavedAccount>[];
  final Map<String, TextEditingController> _fieldControllers =
      <String, TextEditingController>{};

  InviteSummary get _summary => widget.summary;

  bool get _toBalance => _channelId == 'balance';

  @override
  void dispose() {
    _amount.dispose();
    _disposeFields();
    super.dispose();
  }

  void _disposeFields() {
    for (final TextEditingController controller in _fieldControllers.values) {
      controller.dispose();
    }
    _fieldControllers.clear();
  }

  String _helperText() {
    final bool needMin = _toBalance
        ? _summary.balanceWithdrawRequireMin
        : true;
    final String min = needMin
        ? L10n.t('，最低 ¥ {0}', <Object>[_summary.minWithdrawAmount.toStringAsFixed(2)])
        : '';
    return L10n.t('可提现 ¥ {0}{1}', <Object>[_summary.withdrawBalance.toStringAsFixed(2), min]);
  }

  Future<void> _selectChannel(String channelId) async {
    if (channelId == _channelId && (_toBalance || _fields.isNotEmpty)) {
      return;
    }
    _disposeFields();
    setState(() {
      _channelId = channelId;
      _savedAccountId = '';
      _saveAccount = false;
      _fields = const <WithdrawChannelField>[];
      _savedAccounts = const <WithdrawSavedAccount>[];
      _fieldsError = null;
      _fieldsBusy = !_toBalance;
    });
    if (_toBalance) {
      return;
    }
    try {
      final WithdrawChannelFieldsResult result = await widget.api
          .fetchWithdrawChannelFields(int.parse(channelId));
      if (!mounted || _channelId != channelId) {
        return;
      }
      for (final WithdrawChannelField field in result.fields) {
        _fieldControllers[field.name] = TextEditingController();
      }
      setState(() {
        _fields = result.fields;
        _savedAccounts = result.savedAccounts;
        _fieldsBusy = false;
      });
    } on Object catch (e) {
      if (!mounted || _channelId != channelId) {
        return;
      }
      setState(() {
        _fieldsBusy = false;
        _fieldsError = e is ApiException ? e.message : L10n.t('加载渠道失败');
      });
    }
  }

  void _fillSaved(String id) {
    setState(() => _savedAccountId = id);
    WithdrawSavedAccount? account;
    for (final WithdrawSavedAccount item in _savedAccounts) {
      if ('${item.id}' == id) {
        account = item;
        break;
      }
    }
    for (final MapEntry<String, TextEditingController> e
        in _fieldControllers.entries) {
      e.value.text = account?.accountInfo[e.key] ?? '';
    }
  }

  void _submit() {
    final double? parsed = double.tryParse(_amount.text.trim());
    if (parsed == null || parsed <= 0) {
      setState(() => _amountError = L10n.t('请输入有效的提现金额'));
      return;
    }
    if (!_toBalance && (_fieldsBusy || _fieldsError != null)) {
      return;
    }
    Navigator.of(context).pop(
      _WithdrawApplyResult(
        amount: parsed,
        channelId: _channelId,
        accountInfo: <String, String>{
          for (final MapEntry<String, TextEditingController> e
              in _fieldControllers.entries)
            e.key: e.value.text.trim(),
        },
        saveAccount: _saveAccount,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<WithdrawChannelItem> channels = _summary.withdrawChannels;
    final Map<String, String> channelOptions = <String, String>{
      'balance': L10n.t('提现到账户余额（无需审批）'),
      for (final WithdrawChannelItem channel in channels)
        '${channel.id}': L10n.t('{0}（需审批）', <Object>[channel.name]),
    };
    final Map<String, String> savedOptions = <String, String>{
      '': L10n.t('手动输入'),
      for (final WithdrawSavedAccount account in _savedAccounts)
        '${account.id}':
            account.isDefault ? L10n.t('{0}（默认）', <Object>[account.summary]) : account.summary,
    };

    return AlertDialog(
      title: Text(channels.isEmpty ? L10n.t('提现到余额') : L10n.t('申请提现')),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: L10n.t('金额'),
                  helperText: _helperText(),
                  errorText: _amountError,
                ),
                onChanged: (_) {
                  if (_amountError != null) {
                    setState(() => _amountError = null);
                  }
                },
              ),
              if (channels.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                Text(L10n.t('提现方式'), style: theme.textTheme.bodySmall),
                const SizedBox(height: 6),
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) =>
                      OptionDropdown<String>(
                        value: _channelId,
                        width: constraints.maxWidth,
                        options: channelOptions,
                        onChanged: (String value) =>
                            unawaited(_selectChannel(value)),
                      ),
                ),
              ],
              if (!_toBalance) ...<Widget>[
                if (_fieldsBusy) ...<Widget>[
                  const SizedBox(height: 16),
                  const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ] else if (_fieldsError != null) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(
                    _fieldsError!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ] else ...<Widget>[
                  if (_savedAccounts.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(L10n.t('已保存的账户'), style: theme.textTheme.bodySmall),
                    const SizedBox(height: 6),
                    LayoutBuilder(
                      builder:
                          (BuildContext context, BoxConstraints constraints) =>
                              OptionDropdown<String>(
                                value: _savedAccountId,
                                width: constraints.maxWidth,
                                options: savedOptions,
                                onChanged: _fillSaved,
                              ),
                    ),
                  ],
                  for (final WithdrawChannelField field in _fields) ...<Widget>[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _fieldControllers[field.name],
                      decoration: InputDecoration(
                        labelText: field.required ? '${field.name} *' : field.name,
                      ),
                    ),
                  ],
                  CheckboxListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _saveAccount,
                    onChanged: (bool? value) =>
                        setState(() => _saveAccount = value ?? false),
                    title: Text(L10n.t('保存此收款账户')),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(L10n.t('取消')),
        ),
        FilledButton(
          onPressed: _fieldsBusy || _fieldsError != null ? null : _submit,
          child: Text(L10n.t('申请')),
        ),
      ],
    );
  }
}
