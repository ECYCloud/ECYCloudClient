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
    required this.userClass,
    required this.classExpire,
    required this.expireIn,
    required this.upload,
    required this.download,
    required this.transferEnable,
    required this.speedLimitMbps,
    required this.connectorLimit,
    required this.onlineIpCount,
    required this.money,
    required this.ableToCheckin,
    required this.trafficReset,
    required this.plan,
    required this.configRevision,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    id: (json['id'] as num).toInt(),
    email: json['email'] as String? ?? '',
    userName: json['user_name'] as String? ?? '',
    userClass: (json['class'] as num?)?.toInt() ?? 0,
    classExpire: _parseDate(json['class_expire']),
    expireIn: _parseDate(json['expire_in']),
    upload: (json['upload'] as num?)?.toInt() ?? 0,
    download: (json['download'] as num?)?.toInt() ?? 0,
    transferEnable: (json['transfer_enable'] as num?)?.toInt() ?? 0,
    speedLimitMbps: (json['node_speedlimit'] as num?)?.toDouble() ?? 0,
    connectorLimit: (json['node_connector'] as num?)?.toInt() ?? 0,
    onlineIpCount: (json['online_ip_count'] as num?)?.toInt() ?? 0,
    money: (json['money'] as num?)?.toDouble() ?? 0,
    ableToCheckin: json['able_to_checkin'] == true,
    trafficReset: json['traffic_reset'] as String? ?? '',
    plan: json['plan'] is Map<String, dynamic>
        ? UserPlan.fromJson(json['plan'] as Map<String, dynamic>)
        : null,
    configRevision: json['config_revision'] as String? ?? '',
  );

  final int id;
  final String email;
  final String userName;
  final int userClass;
  final DateTime? classExpire;
  final DateTime? expireIn;
  final int upload;
  final int download;
  final int transferEnable;
  final double speedLimitMbps;
  final int connectorLimit;
  final int onlineIpCount;
  final double money;
  final bool ableToCheckin;
  final String trafficReset;
  final UserPlan? plan;
  final String configRevision;

  String get displayName => userName.isEmpty ? email : userName;

  int get used => upload + download;

  int get remaining {
    final int left = transferEnable - used;
    return left > 0 ? left : 0;
  }

  double get usedRatio =>
      transferEnable <= 0 ? 0 : (used / transferEnable).clamp(0.0, 1.0);

  bool get expired =>
      classExpire != null && classExpire!.isBefore(DateTime.now());

  /// 有上限且当前在线 IP 已占满，不能再发起新连接
  bool get onlineIpLimitReached =>
      connectorLimit > 0 && onlineIpCount >= connectorLimit;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'email': email,
    'user_name': userName,
    'class': userClass,
    'class_expire': classExpire?.toIso8601String(),
    'expire_in': expireIn?.toIso8601String(),
    'upload': upload,
    'download': download,
    'transfer_enable': transferEnable,
    'node_speedlimit': speedLimitMbps,
    'node_connector': connectorLimit,
    'online_ip_count': onlineIpCount,
    'money': money,
    'able_to_checkin': ableToCheckin,
    'traffic_reset': trafficReset,
    'plan': plan?.toJson(),
    'config_revision': configRevision,
  };

  static DateTime? _parseDate(Object? raw) {
    if (raw is! String || raw.isEmpty) {
      return null;
    }
    return DateTime.tryParse(raw.replaceFirst(' ', 'T'));
  }
}
