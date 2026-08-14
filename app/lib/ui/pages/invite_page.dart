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
        _error = e is ApiException ? e.message : '加载失败：$e';
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
        content: Text('已复制$label'),
        behavior: SnackBarBehavior.floating,
      ),
    );
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
                ? '已重置您的邀请链接，复制您的邀请链接发送给其他人！'
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
          content: Text(msg.isEmpty ? '提现成功' : msg),
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
          content: Text(msg.isEmpty ? '已取消' : msg),
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
              title: '邀请返利',
              showBackButton: true,
              showUserAvatar: true,
              actions: <Widget>[
                RefreshButton(tooltip: '刷新', onRefresh: _load),
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
                  title: '邀请信息',
                  action: TextButton(
                    onPressed: _busy ? null : _reset,
                    child: const Text('重置邀请码'),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      InfoRow(label: '邀请码', value: summary.code),
                      const SizedBox(height: 4),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              summary.inviteUrl,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          IconButton(
                            tooltip: '复制链接',
                            onPressed: () => unawaited(
                              _copy('邀请链接', summary.inviteUrl),
                            ),
                            icon: const Icon(Icons.copy, size: 18),
                          ),
                          IconButton(
                            tooltip: '复制邀请码',
                            onPressed: () =>
                                unawaited(_copy('邀请码', summary.code)),
                            icon: const Icon(Icons.tag, size: 18),
                          ),
                        ],
                      ),
                      const Divider(height: 20),
                      InfoRow(
                        label: '邀请人数',
                        value: '${summary.invitedUsersCount}',
                      ),
                      InfoRow(
                        label: '返利人数',
                        value: '${summary.rebateUsersCount}',
                      ),
                      InfoRow(
                        label: '累计返利',
                        value: '¥ ${summary.paybacksSum.toStringAsFixed(2)}',
                      ),
                      InfoRow(
                        label: '返利比例',
                        value:
                            '${(summary.codePayback * 100).toStringAsFixed(0)}%',
                      ),
                      InfoRow(
                        label: '每位受邀用户返利次数上限',
                        value: '${summary.rebateFrequencyLimit}',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                SectionCard(
                  icon: Icons.account_balance_wallet_outlined,
                  title: '提现',
                  action: TextButton(
                    onPressed: _applyWithdraw,
                    child: Text(
                      summary.withdrawChannels.isEmpty ? '提现到余额' : '申请提现',
                    ),
                  ),
                  child: Column(
                    children: <Widget>[
                      InfoRow(
                        label: '可提现',
                        value:
                            '¥ ${summary.withdrawBalance.toStringAsFixed(2)}',
                      ),
                      if (summary.enableWithdraw)
                        InfoRow(
                          label: '提现中',
                          value:
                              '¥ ${summary.pendingWithdraw.toStringAsFixed(2)}',
                        ),
                      InfoRow(
                        label: '账户余额',
                        value: '¥ ${summary.money.toStringAsFixed(2)}',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                SectionCard(
                  icon: Icons.people_outline,
                  title: '邀请用户',
                  child: Column(
                    children: <Widget>[
                      ListToolbar(
                        currentPage: summary.invitedCurrentPage,
                        lastPage: summary.invitedLastPage,
                        total: summary.invitedTotal,
                        perPage: _invitedPerPage,
                        searchHint: '用户名 / 邮箱',
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
                        columns: const <String>[
                          '用户ID',
                          '用户名',
                          '邮箱',
                          '注册时间',
                        ],
                        emptyText: '暂无邀请用户',
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
                  title: '返利记录',
                  child: Column(
                    children: <Widget>[
                      ListToolbar(
                        currentPage: summary.paybackCurrentPage,
                        lastPage: summary.paybackLastPage,
                        total: summary.paybackTotal,
                        perPage: _paybackPerPage,
                        searchHint: '用户 ID',
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
                        columns: const <String>[
                          '返利用户ID',
                          '返利金额',
                          '返利时间',
                        ],
                        emptyText: '暂无返利记录',
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
                  title: '提现记录',
                  child: Column(
                    children: <Widget>[
                      ListToolbar(
                        currentPage: summary.withdrawCurrentPage,
                        lastPage: summary.withdrawLastPage,
                        total: summary.withdrawTotal,
                        perPage: _withdrawPerPage,
                        searchHint: '渠道 / 金额',
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
                        columns: const <String>[
                          '金额',
                          '提现方式',
                          '状态',
                          '申请时间',
                          '操作',
                        ],
                        emptyText: '暂无提现记录',
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
                                      child: const Text('取消'),
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
        ? '，最低 ¥ ${_summary.minWithdrawAmount.toStringAsFixed(2)}'
        : '';
    return '可提现 ¥ ${_summary.withdrawBalance.toStringAsFixed(2)}$min';
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
        _fieldsError = e is ApiException ? e.message : '加载渠道失败';
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
      setState(() => _amountError = '请输入有效的提现金额');
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
      'balance': '提现到账户余额（无需审批）',
      for (final WithdrawChannelItem channel in channels)
        '${channel.id}': '${channel.name}（需审批）',
    };
    final Map<String, String> savedOptions = <String, String>{
      '': '手动输入',
      for (final WithdrawSavedAccount account in _savedAccounts)
        '${account.id}':
            account.isDefault ? '${account.summary}（默认）' : account.summary,
    };

    return AlertDialog(
      title: Text(channels.isEmpty ? '提现到余额' : '申请提现'),
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
                  labelText: '金额',
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
                Text('提现方式', style: theme.textTheme.bodySmall),
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
                    Text('已保存的账户', style: theme.textTheme.bodySmall),
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
                    title: const Text('保存此收款账户'),
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
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _fieldsBusy || _fieldsError != null ? null : _submit,
          child: const Text('申请'),
        ),
      ],
    );
  }
}
