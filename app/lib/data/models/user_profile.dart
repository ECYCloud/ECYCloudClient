class UserPlan {
  const UserPlan({
    required this.id,
    required this.name,
    required this.remainingDays,
    required this.expireAt,
    required this.boughtAt,
    required this.autoRenew,
    required this.renewAt,
    required this.canToggleAutoRenew,
  });

  factory UserPlan.fromJson(Map<String, dynamic> json) => UserPlan(
    id: (json['id'] as num?)?.toInt() ?? 0,
    name: json['name'] as String? ?? '',
    remainingDays: (json['remaining_days'] as num?)?.toInt() ?? 0,
    expireAt: json['exp_time'] as String? ?? '',
    boughtAt: json['buy_time'] as String? ?? '',
    autoRenew: json['auto_renew'] == true,
    renewAt: json['renew_at'] as String? ?? '',
    canToggleAutoRenew: json['can_toggle_auto_renew'] == true,
  );

  final int id;
  final String name;
  final int remainingDays;
  final String expireAt;
  final String boughtAt;
  final bool autoRenew;
  final String renewAt;
  final bool canToggleAutoRenew;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'remaining_days': remainingDays,
    'exp_time': expireAt,
    'buy_time': boughtAt,
    'auto_renew': autoRenew,
    'renew_at': renewAt,
    'can_toggle_auto_renew': canToggleAutoRenew,
  };
}

class UserProfile {
  const UserProfile({
    required this.id,
    required this.email,
    required this.userName,
    required this.avatar,
    required this.regDate,
    required this.userClass,
    required this.classExpire,
    required this.expireIn,
    required this.upload,
    required this.download,
    required this.transferEnable,
    required this.speedLimitMbps,
    required this.connectorLimit,
    required this.onlineIpCount,
    this.onlineIpSelf = false,
    required this.money,
    required this.lastDayT,
    required this.lastCheckInTime,
    required this.lastSsTime,
    required this.ableToCheckin,
    required this.enableCheckin,
    required this.checkinMin,
    required this.checkinMax,
    required this.trafficReset,
    required this.plan,
    required this.configRevision,
    this.ipKickNotice = false,
    this.apiOrigin = '',
    this.siteOrigin = '',
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    id: (json['id'] as num).toInt(),
    email: json['email'] as String? ?? '',
    userName: json['user_name'] as String? ?? '',
    avatar: json['avatar'] as String? ?? '',
    regDate: json['reg_date'] as String? ?? '',
    userClass: (json['class'] as num?)?.toInt() ?? 0,
    classExpire: _parseDate(json['class_expire']),
    expireIn: _parseDate(json['expire_in']),
    upload: (json['upload'] as num?)?.toInt() ?? 0,
    download: (json['download'] as num?)?.toInt() ?? 0,
    transferEnable: (json['transfer_enable'] as num?)?.toInt() ?? 0,
    speedLimitMbps: (json['node_speedlimit'] as num?)?.toDouble() ?? 0,
    connectorLimit: (json['node_connector'] as num?)?.toInt() ?? 0,
    onlineIpCount: (json['online_ip_count'] as num?)?.toInt() ?? 0,
    onlineIpSelf: json['online_ip_self'] == true,
    money: (json['money'] as num?)?.toDouble() ?? 0,
    lastDayT: (json['last_day_t'] as num?)?.toInt() ?? 0,
    lastCheckInTime: _checkInTimeText(json['last_check_in_time']),
    lastSsTime: json['last_ss_time'] as String? ?? '从未使用喵',
    ableToCheckin: json['able_to_checkin'] == true,
    // 旧缓存无此字段时默认展示；服务端显式 false 则隐藏
    enableCheckin: json['enable_checkin'] != false,
    checkinMin: (json['checkin_min'] as num?)?.toInt() ?? 1,
    checkinMax: (json['checkin_max'] as num?)?.toInt() ?? 300,
    trafficReset: json['traffic_reset'] as String? ?? '',
    plan: json['plan'] is Map<String, dynamic>
        ? UserPlan.fromJson(json['plan'] as Map<String, dynamic>)
        : null,
    configRevision: json['config_revision'] as String? ?? '',
    ipKickNotice: json['ip_kick_notice'] == true,
    apiOrigin: json['api_origin'] as String? ?? '',
    siteOrigin: json['site_origin'] as String? ?? '',
  );

  final int id;
  final String email;
  final String userName;
  final String avatar;
  final String regDate;
  final int userClass;
  final DateTime? classExpire;
  final DateTime? expireIn;
  final int upload;
  final int download;
  final int transferEnable;
  final double speedLimitMbps;
  final int connectorLimit;
  final int onlineIpCount;
  final bool onlineIpSelf;
  final double money;
  final int lastDayT;
  final String lastCheckInTime;
  final String lastSsTime;
  final bool ableToCheckin;
  final bool enableCheckin;
  final int checkinMin;
  final int checkinMax;
  final String trafficReset;
  final UserPlan? plan;
  final String configRevision;
  final bool ipKickNotice;
  final String apiOrigin;
  final String siteOrigin;

  String get displayName => userName.isEmpty ? email : userName;

  int get used => upload + download;

  int get todayUsed {
    final int value = used - lastDayT;
    return value > 0 ? value : 0;
  }

  int get lastUsed => lastDayT;

  int get remaining {
    final int left = transferEnable - used;
    return left > 0 ? left : 0;
  }

  double get usedRatio =>
      transferEnable <= 0 ? 0 : (used / transferEnable).clamp(0.0, 1.0);

  double ratioOf(int bytes) =>
      transferEnable <= 0 ? 0 : (bytes / transferEnable).clamp(0.0, 1.0);

  bool get expired =>
      classExpire != null && classExpire!.isBefore(DateTime.now());

  /// 有上限、名额已满且本机出口 IP 不在在线集合中；确认后才踢最旧在线 IP
  bool get onlineIpLimitReached =>
      connectorLimit > 0 && onlineIpCount >= connectorLimit && !onlineIpSelf;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'email': email,
    'user_name': userName,
    'avatar': avatar,
    'reg_date': regDate,
    'class': userClass,
    'class_expire': classExpire?.toIso8601String(),
    'expire_in': expireIn?.toIso8601String(),
    'upload': upload,
    'download': download,
    'transfer_enable': transferEnable,
    'node_speedlimit': speedLimitMbps,
    'node_connector': connectorLimit,
    'online_ip_count': onlineIpCount,
    'online_ip_self': onlineIpSelf,
    'money': money,
    'last_day_t': lastDayT,
    'last_check_in_time': lastCheckInTime,
    'last_ss_time': lastSsTime,
    'able_to_checkin': ableToCheckin,
    'enable_checkin': enableCheckin,
    'checkin_min': checkinMin,
    'checkin_max': checkinMax,
    'traffic_reset': trafficReset,
    'plan': plan?.toJson(),
    'config_revision': configRevision,
    'ip_kick_notice': ipKickNotice,
    'api_origin': apiOrigin,
    'site_origin': siteOrigin,
  };

  static DateTime? _parseDate(Object? raw) {
    if (raw is! String || raw.isEmpty) {
      return null;
    }
    return DateTime.tryParse(raw.replaceFirst(' ', 'T'));
  }

  /// 兼容旧缓存里可能是 ISO 字符串 / null
  static String _checkInTimeText(Object? raw) {
    if (raw == null) {
      return '从未签到';
    }
    if (raw is String) {
      return raw.isEmpty ? '从未签到' : raw;
    }
    return raw.toString();
  }
}
