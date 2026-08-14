class AuthOptions {
  const AuthOptions({
    required this.regMode,
    required this.emailVerify,
    required this.enableChangeEmail,
    required this.enableKill,
    required this.apiOrigin,
    required this.siteOrigin,
  });

  final String regMode;
  final bool emailVerify;
  final bool enableChangeEmail;
  final bool enableKill;
  final String apiOrigin;
  final String siteOrigin;

  bool get inviteRequired => regMode == 'invite';

  bool get registrationClosed => regMode == 'close';

  factory AuthOptions.fromJson(Map<String, dynamic> json) => AuthOptions(
    regMode: json['reg_mode'] as String? ?? 'open',
    emailVerify: json['email_verify'] == true,
    enableChangeEmail: json['enable_change_email'] == true,
    enableKill: json['enable_kill'] == true,
    apiOrigin: json['api_origin'] as String? ?? '',
    siteOrigin: json['site_origin'] as String? ?? '',
  );
}

class AccountStatus {
  const AccountStatus({
    required this.enable,
    required this.email,
    required this.submitAccountDeletionTime,
    required this.deletionTime,
    required this.banReason,
    required this.banTimeText,
    required this.banStartTime,
    required this.banEndTime,
    required this.banPermanent,
    required this.ticketEnabled,
    required this.supportEmail,
  });

  final int enable;
  final String email;
  final String? submitAccountDeletionTime;
  final String? deletionTime;
  final String? banReason;
  final String? banTimeText;
  final String? banStartTime;
  final String? banEndTime;
  final bool banPermanent;
  final bool ticketEnabled;
  final String supportEmail;

  bool get isPendingDeletion => enable == -1;

  bool get isBanned => enable == 0;

  bool get isNormal => enable == 1;

  factory AccountStatus.fromJson(Map<String, dynamic> json) => AccountStatus(
    enable: (json['enable'] as num?)?.toInt() ?? 1,
    email: json['email'] as String? ?? '',
    submitAccountDeletionTime:
        json['submit_account_deletion_time'] as String?,
    deletionTime: json['deletion_time'] as String?,
    banReason: json['ban_reason'] as String?,
    banTimeText: json['ban_time_text'] as String?,
    banStartTime: json['ban_start_time'] as String?,
    banEndTime: json['ban_end_time'] as String?,
    banPermanent: json['ban_permanent'] == true,
    ticketEnabled: json['ticket_enabled'] == true,
    supportEmail: json['support_email'] as String? ?? '',
  );
}

class InvitedUserItem {
  const InvitedUserItem({
    required this.id,
    required this.userName,
    required this.email,
    required this.regDate,
  });

  final int id;
  final String userName;
  final String email;
  final String regDate;

  factory InvitedUserItem.fromJson(Map<String, dynamic> json) =>
      InvitedUserItem(
        id: (json['id'] as num?)?.toInt() ?? 0,
        userName: json['user_name'] as String? ?? '',
        email: json['email'] as String? ?? '',
        regDate: json['reg_date'] as String? ?? '',
      );
}

class PaybackItem {
  const PaybackItem({
    required this.id,
    required this.userId,
    required this.total,
    required this.refBy,
    required this.refGet,
    required this.datetime,
  });

  final int id;
  final int userId;
  final double total;
  final int refBy;
  final double refGet;
  final String datetime;

  factory PaybackItem.fromJson(Map<String, dynamic> json) => PaybackItem(
    id: (json['id'] as num?)?.toInt() ?? 0,
    userId: (json['userid'] as num?)?.toInt() ?? 0,
    total: (json['total'] as num?)?.toDouble() ?? 0,
    refBy: (json['ref_by'] as num?)?.toInt() ?? 0,
    refGet: (json['ref_get'] as num?)?.toDouble() ?? 0,
    datetime: json['datetime'] as String? ?? '',
  );
}

class WithdrawRecordItem {
  const WithdrawRecordItem({
    required this.id,
    required this.amount,
    required this.status,
    required this.statusText,
    required this.channel,
    required this.createdAt,
    required this.processedAt,
  });

  final int id;
  final double amount;
  final int status;
  final String statusText;
  final String channel;
  final String createdAt;
  final String processedAt;

  bool get isPending => status == 0;

  factory WithdrawRecordItem.fromJson(Map<String, dynamic> json) =>
      WithdrawRecordItem(
        id: (json['id'] as num?)?.toInt() ?? 0,
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        status: (json['status'] as num?)?.toInt() ?? 0,
        statusText: json['status_text'] as String? ?? '',
        channel: json['channel'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
        processedAt: json['processed_at'] as String? ?? '',
      );
}

class WithdrawChannelItem {
  const WithdrawChannelItem({required this.id, required this.name});

  final int id;
  final String name;

  factory WithdrawChannelItem.fromJson(Map<String, dynamic> json) =>
      WithdrawChannelItem(
        id: (json['id'] as num?)?.toInt() ?? 0,
        name: json['name'] as String? ?? '',
      );
}

class WithdrawChannelField {
  const WithdrawChannelField({required this.name, required this.required});

  final String name;
  final bool required;

  factory WithdrawChannelField.fromJson(Map<String, dynamic> json) =>
      WithdrawChannelField(
        name: json['name'] as String? ?? '',
        required: json['required'] == true,
      );
}

class WithdrawSavedAccount {
  const WithdrawSavedAccount({
    required this.id,
    required this.accountInfo,
    required this.isDefault,
    required this.summary,
  });

  final int id;
  final Map<String, String> accountInfo;
  final bool isDefault;
  final String summary;

  factory WithdrawSavedAccount.fromJson(Map<String, dynamic> json) {
    final Object? info = json['account_info'];
    return WithdrawSavedAccount(
      id: (json['id'] as num?)?.toInt() ?? 0,
      accountInfo: <String, String>{
        if (info is Map)
          for (final MapEntry<dynamic, dynamic> e in info.entries)
            '${e.key}': '${e.value ?? ''}',
      },
      isDefault: json['is_default'] == true,
      summary: json['summary'] as String? ?? '',
    );
  }
}

class WithdrawChannelFieldsResult {
  const WithdrawChannelFieldsResult({
    required this.fields,
    required this.savedAccounts,
  });

  final List<WithdrawChannelField> fields;
  final List<WithdrawSavedAccount> savedAccounts;

  factory WithdrawChannelFieldsResult.fromJson(Map<String, dynamic> json) {
    final Object? channel = json['channel'];
    final Object? fields = channel is Map<String, dynamic>
        ? channel['fields']
        : null;
    final Object? accounts = json['saved_accounts'];
    return WithdrawChannelFieldsResult(
      fields: <WithdrawChannelField>[
        if (fields is List)
          for (final Object? item in fields)
            if (item is Map<String, dynamic>)
              WithdrawChannelField.fromJson(item),
      ],
      savedAccounts: <WithdrawSavedAccount>[
        if (accounts is List)
          for (final Object? item in accounts)
            if (item is Map<String, dynamic>)
              WithdrawSavedAccount.fromJson(item),
      ],
    );
  }
}

class InviteSummary {
  const InviteSummary({
    required this.code,
    required this.inviteUrl,
    required this.invitedUsersCount,
    required this.rebateUsersCount,
    required this.paybacksSum,
    required this.rebateFrequencyLimit,
    required this.codePayback,
    required this.withdrawBalance,
    required this.pendingWithdraw,
    required this.enableWithdraw,
    required this.minWithdrawAmount,
    required this.money,
    required this.invitedUsers,
    required this.paybacks,
    required this.withdrawRecords,
    this.balanceWithdrawRequireMin = false,
    this.withdrawChannels = const <WithdrawChannelItem>[],
    this.invitedCurrentPage = 1,
    this.invitedLastPage = 1,
    this.invitedTotal = 0,
    this.invitedPerPage = 10,
    this.paybackCurrentPage = 1,
    this.paybackLastPage = 1,
    this.paybackTotal = 0,
    this.paybackPerPage = 10,
    this.withdrawCurrentPage = 1,
    this.withdrawLastPage = 1,
    this.withdrawTotal = 0,
    this.withdrawPerPage = 10,
  });

  final String code;
  final String inviteUrl;
  final int invitedUsersCount;
  final int rebateUsersCount;
  final double paybacksSum;
  final int rebateFrequencyLimit;
  final double codePayback;
  final double withdrawBalance;
  final double pendingWithdraw;
  final bool enableWithdraw;
  final double minWithdrawAmount;
  final bool balanceWithdrawRequireMin;
  final List<WithdrawChannelItem> withdrawChannels;
  final double money;
  final List<InvitedUserItem> invitedUsers;
  final List<PaybackItem> paybacks;
  final List<WithdrawRecordItem> withdrawRecords;
  final int invitedCurrentPage;
  final int invitedLastPage;
  final int invitedTotal;
  final int invitedPerPage;
  final int paybackCurrentPage;
  final int paybackLastPage;
  final int paybackTotal;
  final int paybackPerPage;
  final int withdrawCurrentPage;
  final int withdrawLastPage;
  final int withdrawTotal;
  final int withdrawPerPage;

  factory InviteSummary.fromJson(Map<String, dynamic> json) {
    final Object? invited = json['invited_users'];
    final Object? paybacks = json['paybacks'];
    final Object? withdraws = json['withdraw_records'];
    final Object? channels = json['withdraw_channels'];

    return InviteSummary(
      code: json['code'] as String? ?? '',
      inviteUrl: json['invite_url'] as String? ?? '',
      invitedUsersCount: (json['invited_users_count'] as num?)?.toInt() ?? 0,
      rebateUsersCount: (json['rebate_users_count'] as num?)?.toInt() ?? 0,
      paybacksSum: (json['paybacks_sum'] as num?)?.toDouble() ?? 0,
      rebateFrequencyLimit:
          (json['rebate_frequency_limit'] as num?)?.toInt() ?? 0,
      codePayback: (json['code_payback'] as num?)?.toDouble() ?? 0,
      withdrawBalance: (json['withdraw_balance'] as num?)?.toDouble() ?? 0,
      pendingWithdraw: (json['pending_withdraw'] as num?)?.toDouble() ?? 0,
      enableWithdraw: json['enable_withdraw'] == true,
      minWithdrawAmount: (json['min_withdraw_amount'] as num?)?.toDouble() ?? 0,
      balanceWithdrawRequireMin: json['balance_withdraw_require_min'] == true,
      withdrawChannels: <WithdrawChannelItem>[
        if (channels is List)
          for (final Object? item in channels)
            if (item is Map<String, dynamic>) WithdrawChannelItem.fromJson(item),
      ],
      money: (json['money'] as num?)?.toDouble() ?? 0,
      invitedUsers: <InvitedUserItem>[
        if (invited is List)
          for (final Object? item in invited)
            if (item is Map<String, dynamic>) InvitedUserItem.fromJson(item),
      ],
      paybacks: <PaybackItem>[
        if (paybacks is List)
          for (final Object? item in paybacks)
            if (item is Map<String, dynamic>) PaybackItem.fromJson(item),
      ],
      withdrawRecords: <WithdrawRecordItem>[
        if (withdraws is List)
          for (final Object? item in withdraws)
            if (item is Map<String, dynamic>) WithdrawRecordItem.fromJson(item),
      ],
      invitedCurrentPage: (json['invited_current_page'] as num?)?.toInt() ?? 1,
      invitedLastPage: (json['invited_last_page'] as num?)?.toInt() ?? 1,
      invitedTotal: (json['invited_total'] as num?)?.toInt() ?? 0,
      invitedPerPage: (json['invited_per_page'] as num?)?.toInt() ?? 10,
      paybackCurrentPage: (json['payback_current_page'] as num?)?.toInt() ?? 1,
      paybackLastPage: (json['payback_last_page'] as num?)?.toInt() ?? 1,
      paybackTotal: (json['payback_total'] as num?)?.toInt() ?? 0,
      paybackPerPage: (json['payback_per_page'] as num?)?.toInt() ?? 10,
      withdrawCurrentPage: (json['withdraw_current_page'] as num?)?.toInt() ?? 1,
      withdrawLastPage: (json['withdraw_last_page'] as num?)?.toInt() ?? 1,
      withdrawTotal: (json['withdraw_total'] as num?)?.toInt() ?? 0,
      withdrawPerPage: (json['withdraw_per_page'] as num?)?.toInt() ?? 10,
    );
  }
}

class EditAccountOptions {
  const EditAccountOptions({
    required this.gaEnable,
    required this.gaToken,
    required this.gaUrl,
    required this.enableTelegram,
    required this.telegramBot,
    required this.telegramId,
    required this.imValue,
    required this.bindToken,
    required this.telegramUnbindKick,
    required this.mailNotifySettings,
    required this.mailNotifyPreferences,
  });

  final int gaEnable;
  final String gaToken;
  final String gaUrl;
  final bool enableTelegram;
  final String telegramBot;
  final int telegramId;
  final String imValue;
  final String bindToken;
  final bool telegramUnbindKick;
  final Map<String, dynamic> mailNotifySettings;
  final Map<String, bool> mailNotifyPreferences;

  bool get telegramBound => telegramId > 0;

  factory EditAccountOptions.fromJson(Map<String, dynamic> json) {
    final Object? settingsRaw = json['mail_notify_settings'];
    final Object? prefsRaw = json['mail_notify_preferences'];
    final Map<String, bool> prefs = <String, bool>{};
    if (prefsRaw is Map<String, dynamic>) {
      for (final MapEntry<String, dynamic> e in prefsRaw.entries) {
        prefs[e.key] = e.value == true;
      }
    }

    return EditAccountOptions(
      gaEnable: (json['ga_enable'] as num?)?.toInt() ?? 0,
      gaToken: json['ga_token'] as String? ?? '',
      gaUrl: json['ga_url'] as String? ?? '',
      enableTelegram: json['enable_telegram'] == true,
      telegramBot: json['telegram_bot'] as String? ?? '',
      telegramId: (json['telegram_id'] as num?)?.toInt() ?? 0,
      imValue: json['im_value'] as String? ?? '',
      bindToken: json['bind_token'] as String? ?? '',
      telegramUnbindKick: json['telegram_unbind_kick'] == true,
      mailNotifySettings: settingsRaw is Map<String, dynamic>
          ? Map<String, dynamic>.from(settingsRaw)
          : <String, dynamic>{},
      mailNotifyPreferences: prefs,
    );
  }

  EditAccountOptions copyWith({
    int? gaEnable,
    String? gaToken,
    String? gaUrl,
    int? telegramId,
    String? imValue,
    String? bindToken,
    Map<String, bool>? mailNotifyPreferences,
  }) => EditAccountOptions(
    gaEnable: gaEnable ?? this.gaEnable,
    gaToken: gaToken ?? this.gaToken,
    gaUrl: gaUrl ?? this.gaUrl,
    enableTelegram: enableTelegram,
    telegramBot: telegramBot,
    telegramId: telegramId ?? this.telegramId,
    imValue: imValue ?? this.imValue,
    bindToken: bindToken ?? this.bindToken,
    telegramUnbindKick: telegramUnbindKick,
    mailNotifySettings: mailNotifySettings,
    mailNotifyPreferences:
        mailNotifyPreferences ?? this.mailNotifyPreferences,
  );
}

class InviteResetResult {
  const InviteResetResult({
    required this.message,
    required this.newCode,
    required this.inviteUrl,
  });

  final String message;
  final String newCode;
  final String inviteUrl;
}

class TrafficDayTotal {
  const TrafficDayTotal({
    required this.totalUsage,
    required this.totalUpload,
    required this.totalDownload,
    required this.rateInfo,
  });

  final String totalUsage;
  final String totalUpload;
  final String totalDownload;
  final String rateInfo;

  factory TrafficDayTotal.fromJson(Map<String, dynamic> json) =>
      TrafficDayTotal(
        totalUsage: json['total_usage'] as String? ?? '0B',
        totalUpload: json['total_upload'] as String? ?? '0B',
        totalDownload: json['total_download'] as String? ?? '0B',
        rateInfo: json['rate_info'] as String? ?? '无',
      );
}

class TrafficNodeItem {
  const TrafficNodeItem({
    required this.nodeName,
    required this.nodeTrafficRate,
    required this.nodeRateStr,
    required this.dailyUpload,
    required this.dailyDownload,
    required this.dailyUsage,
  });

  final String nodeName;
  final double nodeTrafficRate;
  final String nodeRateStr;
  final int dailyUpload;
  final int dailyDownload;
  final int dailyUsage;

  factory TrafficNodeItem.fromJson(Map<String, dynamic> json) =>
      TrafficNodeItem(
        nodeName: json['node_name'] as String? ?? '',
        nodeTrafficRate: (json['node_traffic_rate'] as num?)?.toDouble() ?? 0,
        nodeRateStr: json['node_rate_str'] as String? ?? '',
        dailyUpload: (json['daily_upload'] as num?)?.toInt() ?? 0,
        dailyDownload: (json['daily_download'] as num?)?.toInt() ?? 0,
        dailyUsage: (json['daily_usage'] as num?)?.toInt() ?? 0,
      );
}

class TrafficLogBundle {
  const TrafficLogBundle({
    required this.traffic,
    required this.totalUpload,
    required this.totalDownload,
    required this.totalUsage,
    required this.totalRateInfo,
    required this.nodeTraffic,
    required this.logKeepDays,
  });

  final Map<String, TrafficDayTotal> traffic;
  final String totalUpload;
  final String totalDownload;
  final String totalUsage;
  final String totalRateInfo;
  final Map<String, List<TrafficNodeItem>> nodeTraffic;
  final int logKeepDays;

  factory TrafficLogBundle.fromJson(Map<String, dynamic> json) {
    final Object? trafficRaw = json['traffic'];
    final Object? nodeRaw = json['node_traffic'];
    final Map<String, TrafficDayTotal> traffic = <String, TrafficDayTotal>{};
    if (trafficRaw is Map<String, dynamic>) {
      for (final MapEntry<String, dynamic> entry in trafficRaw.entries) {
        if (entry.value is Map<String, dynamic>) {
          traffic[entry.key] = TrafficDayTotal.fromJson(
            entry.value as Map<String, dynamic>,
          );
        }
      }
    }
    final Map<String, List<TrafficNodeItem>> nodeTraffic =
        <String, List<TrafficNodeItem>>{};
    if (nodeRaw is Map<String, dynamic>) {
      for (final MapEntry<String, dynamic> entry in nodeRaw.entries) {
        final Object? list = entry.value;
        nodeTraffic[entry.key] = <TrafficNodeItem>[
          if (list is List)
            for (final Object? item in list)
              if (item is Map<String, dynamic>) TrafficNodeItem.fromJson(item),
        ];
      }
    }

    return TrafficLogBundle(
      traffic: traffic,
      totalUpload: json['total_upload'] as String? ?? '0B',
      totalDownload: json['total_download'] as String? ?? '0B',
      totalUsage: json['total_usage'] as String? ?? '0B',
      totalRateInfo: json['total_rate_info'] as String? ?? '无',
      nodeTraffic: nodeTraffic,
      logKeepDays: (json['log_keep_days'] as num?)?.toInt() ?? 30,
    );
  }
}

class PurchaseRecord {
  const PurchaseRecord({
    required this.id,
    required this.orderNo,
    required this.shopName,
    required this.name,
    required this.content,
    required this.price,
    required this.datetime,
    required this.expTime,
    required this.renew,
    required this.autoRenew,
    required this.canToggle,
    required this.type,
  });

  final int id;
  final String orderNo;
  final String shopName;
  final String name;
  final String content;
  final double price;
  final String datetime;
  final String expTime;
  final String? renew;
  final bool autoRenew;
  final bool canToggle;
  final String type;

  factory PurchaseRecord.fromJson(Map<String, dynamic> json) => PurchaseRecord(
    id: _asInt(json['id']),
    orderNo: json['order_no']?.toString() ?? '',
    shopName: json['shop_name']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    content: json['content']?.toString() ?? '',
    price: _asDouble(json['price']),
    datetime: json['datetime']?.toString() ?? '',
    expTime: json['exp_time']?.toString() ?? '',
    renew: json['renew']?.toString(),
    autoRenew: json['auto_renew'] == true,
    canToggle: json['can_toggle'] == true,
    type: json['type']?.toString() ?? '',
  );
}

int _asInt(Object? raw) {
  if (raw is num) {
    return raw.toInt();
  }
  if (raw is String) {
    return int.tryParse(raw) ?? 0;
  }
  return 0;
}

double _asDouble(Object? raw) {
  if (raw is num) {
    return raw.toDouble();
  }
  if (raw is String) {
    return double.tryParse(raw) ?? 0;
  }
  return 0;
}

class PurchaseListPage {
  const PurchaseListPage({
    required this.purchases,
    required this.currentPage,
    required this.lastPage,
    required this.total,
    required this.perPage,
  });

  final List<PurchaseRecord> purchases;
  final int currentPage;
  final int lastPage;
  final int total;
  final int perPage;

  factory PurchaseListPage.fromJson(Map<String, dynamic> json) {
    final Object? raw = json['purchases'];
    return PurchaseListPage(
      purchases: <PurchaseRecord>[
        if (raw is List)
          for (final Object? item in raw)
            if (item is Map<String, dynamic>) PurchaseRecord.fromJson(item),
      ],
      currentPage: (json['current_page'] as num?)?.toInt() ?? 1,
      lastPage: (json['last_page'] as num?)?.toInt() ?? 1,
      total: (json['total'] as num?)?.toInt() ?? 0,
      perPage: (json['per_page'] as num?)?.toInt() ?? 0,
    );
  }
}

class RechargePaymentOption {
  const RechargePaymentOption({
    required this.id,
    required this.name,
    required this.type,
  });

  final String id;
  final String name;
  final String type;

  bool get isEpay => type == 'epay' || id == 'epay';

  factory RechargePaymentOption.fromJson(Map<String, dynamic> json) =>
      RechargePaymentOption(
        id: json['id']?.toString() ?? '',
        name: json['name'] as String? ?? '',
        type: json['type'] as String? ?? '',
      );
}

class RechargeInfo {
  const RechargeInfo({
    required this.money,
    required this.totalTopUp,
    required this.payments,
  });

  final double money;
  final String totalTopUp;
  final List<RechargePaymentOption> payments;

  bool get hasEpay => payments.any((RechargePaymentOption p) => p.isEpay);

  factory RechargeInfo.fromJson(Map<String, dynamic> json) {
    final Object? raw = json['payments'];
    return RechargeInfo(
      money: (json['money'] as num?)?.toDouble() ?? 0,
      totalTopUp: json['total_top_up']?.toString() ?? '0.00',
      payments: <RechargePaymentOption>[
        if (raw is List)
          for (final Object? item in raw)
            if (item is Map<String, dynamic>)
              RechargePaymentOption.fromJson(item),
      ],
    );
  }
}

class UsageIpItem {
  const UsageIpItem({
    required this.ip,
    required this.location,
    required this.datetime,
  });

  final String ip;
  final String location;
  final String datetime;

  factory UsageIpItem.fromJson(Map<String, dynamic> json) => UsageIpItem(
    ip: json['ip'] as String? ?? '',
    location: json['location'] as String? ?? '',
    datetime: json['datetime'] as String? ?? '',
  );
}

class UsageIpListPage {
  const UsageIpListPage({
    required this.items,
    required this.logKeepDays,
    required this.currentPage,
    required this.lastPage,
    required this.total,
    required this.perPage,
  });

  final List<UsageIpItem> items;
  final int logKeepDays;
  final int currentPage;
  final int lastPage;
  final int total;
  final int perPage;

  factory UsageIpListPage.fromJson(Map<String, dynamic> json) {
    final Object? raw = json['items'];
    return UsageIpListPage(
      items: <UsageIpItem>[
        if (raw is List)
          for (final Object? item in raw)
            if (item is Map<String, dynamic>) UsageIpItem.fromJson(item),
      ],
      logKeepDays: (json['log_keep_days'] as num?)?.toInt() ?? 1,
      currentPage: (json['current_page'] as num?)?.toInt() ?? 1,
      lastPage: (json['last_page'] as num?)?.toInt() ?? 1,
      total: (json['total'] as num?)?.toInt() ?? 0,
      perPage: (json['per_page'] as num?)?.toInt() ?? 0,
    );
  }
}

class LoginLogItem {
  const LoginLogItem({
    required this.ip,
    required this.location,
    required this.device,
    required this.type,
    required this.method,
    required this.datetime,
  });

  final String ip;
  final String location;
  final String device;
  final String type;
  final String method;
  final String datetime;

  factory LoginLogItem.fromJson(Map<String, dynamic> json) => LoginLogItem(
    ip: json['ip'] as String? ?? '',
    location: json['location'] as String? ?? '',
    device: json['device'] as String? ?? '',
    type: json['type'] as String? ?? '',
    method: json['method'] as String? ?? '',
    datetime: json['datetime'] as String? ?? '',
  );
}

class LoginLogListPage {
  const LoginLogListPage({
    required this.items,
    required this.logKeepDays,
    required this.currentPage,
    required this.lastPage,
    required this.total,
    required this.perPage,
  });

  final List<LoginLogItem> items;
  final int logKeepDays;
  final int currentPage;
  final int lastPage;
  final int total;
  final int perPage;

  factory LoginLogListPage.fromJson(Map<String, dynamic> json) {
    final Object? raw = json['items'];
    return LoginLogListPage(
      items: <LoginLogItem>[
        if (raw is List)
          for (final Object? item in raw)
            if (item is Map<String, dynamic>) LoginLogItem.fromJson(item),
      ],
      logKeepDays: (json['log_keep_days'] as num?)?.toInt() ?? 30,
      currentPage: (json['current_page'] as num?)?.toInt() ?? 1,
      lastPage: (json['last_page'] as num?)?.toInt() ?? 1,
      total: (json['total'] as num?)?.toInt() ?? 0,
      perPage: (json['per_page'] as num?)?.toInt() ?? 0,
    );
  }
}

class BalanceTransactionItem {
  const BalanceTransactionItem({
    required this.orderNo,
    required this.type,
    required this.typeText,
    required this.amount,
    required this.createdAt,
  });

  final String orderNo;
  final int type;
  final String typeText;
  final double amount;
  final String createdAt;

  factory BalanceTransactionItem.fromJson(Map<String, dynamic> json) =>
      BalanceTransactionItem(
        orderNo: json['order_no'] as String? ?? '',
        type: (json['type'] as num?)?.toInt() ?? 0,
        typeText: json['type_text'] as String? ?? '',
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        createdAt: json['created_at'] as String? ?? '',
      );
}

class BalanceListPage {
  const BalanceListPage({
    required this.items,
    required this.currentPage,
    required this.lastPage,
    required this.total,
    required this.perPage,
  });

  final List<BalanceTransactionItem> items;
  final int currentPage;
  final int lastPage;
  final int total;
  final int perPage;

  factory BalanceListPage.fromJson(Map<String, dynamic> json) {
    final Object? raw = json['items'];
    return BalanceListPage(
      items: <BalanceTransactionItem>[
        if (raw is List)
          for (final Object? item in raw)
            if (item is Map<String, dynamic>)
              BalanceTransactionItem.fromJson(item),
      ],
      currentPage: (json['current_page'] as num?)?.toInt() ?? 1,
      lastPage: (json['last_page'] as num?)?.toInt() ?? 1,
      total: (json['total'] as num?)?.toInt() ?? 0,
      perPage: (json['per_page'] as num?)?.toInt() ?? 0,
    );
  }
}

class UnlockResult {
  const UnlockResult({
    required this.nodeName,
    required this.createdAt,
    required this.unlockItem,
  });

  final String nodeName;
  final String createdAt;
  final Map<String, String> unlockItem;

  factory UnlockResult.fromJson(Map<String, dynamic> json) {
    final Object? raw = json['unlock_item'];
    final Map<String, String> items = <String, String>{};
    if (raw is Map<String, dynamic>) {
      for (final MapEntry<String, dynamic> entry in raw.entries) {
        items[entry.key] = entry.value?.toString() ?? '';
      }
    }

    return UnlockResult(
      nodeName: json['node_name'] as String? ?? '',
      createdAt: json['created_at'] as String? ?? '',
      unlockItem: items,
    );
  }
}

class UnlockListPage {
  const UnlockListPage({
    required this.results,
    required this.unlockCheckInterval,
    required this.currentPage,
    required this.lastPage,
    required this.total,
    required this.perPage,
  });

  final List<UnlockResult> results;
  final int unlockCheckInterval;
  final int currentPage;
  final int lastPage;
  final int total;
  final int perPage;

  factory UnlockListPage.fromJson(Map<String, dynamic> json) {
    final Object? raw = json['results'];
    return UnlockListPage(
      results: <UnlockResult>[
        if (raw is List)
          for (final Object? item in raw)
            if (item is Map<String, dynamic>) UnlockResult.fromJson(item),
      ],
      unlockCheckInterval:
          (json['unlock_check_interval'] as num?)?.toInt() ?? 0,
      currentPage: (json['current_page'] as num?)?.toInt() ?? 1,
      lastPage: (json['last_page'] as num?)?.toInt() ?? 1,
      total: (json['total'] as num?)?.toInt() ?? 0,
      perPage: (json['per_page'] as num?)?.toInt() ?? 0,
    );
  }
}

class CustomProxyGroup {
  const CustomProxyGroup({
    required this.name,
    this.icon,
    required this.includeNodes,
    required this.proxies,
  });

  final String name;
  final String? icon;
  final bool includeNodes;
  final List<String> proxies;

  factory CustomProxyGroup.fromJson(Map<String, dynamic> json) =>
      CustomProxyGroup(
        name: json['name'] as String? ?? '',
        icon: json['icon'] as String?,
        includeNodes: json['include_nodes'] != false,
        proxies: <String>[
          if (json['proxies'] is List)
            for (final Object? item in json['proxies'] as List)
              if (item is String && item.isNotEmpty) item,
        ],
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'icon': icon,
    'include_nodes': includeNodes,
    'proxies': proxies,
  };
}

class CustomRuleProvider {
  const CustomRuleProvider({
    required this.name,
    required this.url,
    required this.policy,
    required this.behavior,
    required this.format,
    required this.interval,
  });

  final String name;
  final String url;
  final String policy;
  final String behavior;
  final String format;
  final int interval;

  factory CustomRuleProvider.fromJson(Map<String, dynamic> json) =>
      CustomRuleProvider(
        name: json['name'] as String? ?? '',
        url: json['url'] as String? ?? '',
        policy: json['policy'] as String? ?? '',
        behavior: json['behavior'] as String? ?? 'classical',
        format: json['format'] as String? ?? 'yaml',
        interval: (json['interval'] as num?)?.toInt() ?? 86400,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (name.isNotEmpty) 'name': name,
    'url': url,
    'policy': policy,
    if (behavior.isNotEmpty) 'behavior': behavior,
    if (format.isNotEmpty) 'format': format,
    if (interval > 0) 'interval': interval,
  };
}

class SubscriptionConfig {
  const SubscriptionConfig({
    required this.customizableGroups,
    required this.allGroupNames,
    required this.groupIcons,
    required this.availableProxyNames,
    required this.allowCustomHosts,
    required this.allowCustomRules,
    required this.allowCustomGroups,
    required this.allowCustomRuleProviders,
    required this.maxCustomHosts,
    required this.maxCustomRules,
    required this.maxCustomGroups,
    required this.maxCustomRuleProviders,
    required this.disabledGroups,
    required this.customHosts,
    required this.customRules,
    required this.customGroups,
    required this.customRuleProviders,
    required this.supportGroups,
    required this.supportHosts,
    required this.supportRules,
  });

  final List<String> customizableGroups;
  final List<String> allGroupNames;
  final Map<String, String> groupIcons;
  final List<String> availableProxyNames;
  final bool allowCustomHosts;
  final bool allowCustomRules;
  final bool allowCustomGroups;
  final bool allowCustomRuleProviders;
  final int maxCustomHosts;
  final int maxCustomRules;
  final int maxCustomGroups;
  final int maxCustomRuleProviders;
  final List<String> disabledGroups;
  final String customHosts;
  final String customRules;
  final List<CustomProxyGroup> customGroups;
  final List<CustomRuleProvider> customRuleProviders;
  final List<String> supportGroups;
  final List<String> supportHosts;
  final List<String> supportRules;

  factory SubscriptionConfig.fromJson(Map<String, dynamic> json) {
    final Object? icons = json['group_icons'];
    final Map<String, String> groupIcons = <String, String>{};
    if (icons is Map) {
      icons.forEach((Object? key, Object? value) {
        if (key is String && value is String && value.isNotEmpty) {
          groupIcons[key] = value;
        }
      });
    }
    return SubscriptionConfig(
      customizableGroups: _stringList(json['customizable_groups']),
      allGroupNames: _stringList(json['all_group_names']),
      groupIcons: groupIcons,
      availableProxyNames: _orderedAvailableProxyNames(
        _stringList(json['available_proxy_names']),
      ),
      allowCustomHosts: json['allow_custom_hosts'] == true,
      allowCustomRules: json['allow_custom_rules'] == true,
      allowCustomGroups: json['allow_custom_groups'] == true,
      allowCustomRuleProviders: json['allow_custom_rule_providers'] == true,
      maxCustomHosts: (json['max_custom_hosts'] as num?)?.toInt() ?? 0,
      maxCustomRules: (json['max_custom_rules'] as num?)?.toInt() ?? 0,
      maxCustomGroups: (json['max_custom_groups'] as num?)?.toInt() ?? 0,
      maxCustomRuleProviders:
          (json['max_custom_rule_providers'] as num?)?.toInt() ?? 0,
      disabledGroups: _stringList(json['disabled_groups']),
      customHosts: json['custom_hosts'] as String? ?? '',
      customRules: json['custom_rules'] as String? ?? '',
      customGroups: <CustomProxyGroup>[
        if (json['custom_groups'] is List)
          for (final Object? item in json['custom_groups'] as List)
            if (item is Map<String, dynamic>) CustomProxyGroup.fromJson(item),
      ],
      customRuleProviders: <CustomRuleProvider>[
        if (json['custom_rule_providers'] is List)
          for (final Object? item in json['custom_rule_providers'] as List)
            if (item is Map<String, dynamic>) CustomRuleProvider.fromJson(item),
      ],
      supportGroups: _stringList(json['support_groups']),
      supportHosts: _stringList(json['support_hosts']),
      supportRules: _stringList(json['support_rules']),
    );
  }

  static List<String> _stringList(Object? raw) => <String>[
    if (raw is List)
      for (final Object? item in raw)
        if (item is String && item.isNotEmpty) item,
  ];

  /// 与面板一致：主节点 / 自动选择 / 故障转移 置顶，其后为内置出站与其余项。
  static List<String> _orderedAvailableProxyNames(List<String> raw) {
    const List<String> preferred = <String>['主节点', '自动选择', '故障转移'];
    const List<String> builtins = <String>[
      'DIRECT',
      'REJECT',
      'REJECT-TINYGIF',
    ];
    final Set<String> seen = <String>{};
    final List<String> out = <String>[];
    void addIfPresent(String name) {
      if (raw.contains(name) && seen.add(name)) {
        out.add(name);
      }
    }

    for (final String name in preferred) {
      addIfPresent(name);
    }
    for (final String name in builtins) {
      addIfPresent(name);
    }
    for (final String name in raw) {
      if (seen.add(name)) {
        out.add(name);
      }
    }
    return out;
  }
}
