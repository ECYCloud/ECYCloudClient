import 'package:flutter_test/flutter_test.dart';
import 'package:ecycloud_client/data/models/online_device.dart';
import 'package:ecycloud_client/data/models/user_profile.dart';

void main() {
  test('官方数量限制独立于第三方 IP 数量', () {
    final profile = UserProfile.fromJson({
      'id': 7,
      'node_connector': 2,
      'online_client_count': 2,
      'online_client_self': false,
      'online_ip_count': 0,
      'online_ip_self': true,
      'device_kick_notice': true,
      'device_kick_reason': 'limit_denied',
    });
    expect(profile.onlineDeviceCount, 2);
    expect(profile.deviceKickNotice, isTrue);
    expect(profile.deviceKickReason, 'limit_denied');
    expect(profile.toJson()['device_kick_notice'], isTrue);
    expect(profile.toJson()['device_kick_reason'], 'limit_denied');
    expect(profile.toJson().containsKey('ip_kick_notice'), isFalse);
    expect(profile.toJson().containsKey('ip_kick_reason'), isFalse);
    expect(profile.deviceLimitReached, isTrue);
    expect(UserProfile.fromJson(profile.toJson()).deviceLimitReached, isTrue);
  });

  test('已在线设备切换 IP 仍占原名额，无限制套餐不触发超限', () {
    expect(UserProfile.fromJson({
      'id': 7,
      'node_connector': 2,
      'online_client_count': 2,
      'online_client_self': true,
    }).deviceLimitReached, isFalse);
    expect(UserProfile.fromJson({
      'id': 7,
      'node_connector': 0,
      'online_client_count': 20,
      'online_client_self': false,
    }).deviceLimitReached, isFalse);
  });

  test('同 IP 设备保留独立下线选择标识', () {
    final a = OnlineDevice.fromJson({'ip': '198.51.100.8', 'device_id': 'a'});
    final b = OnlineDevice.fromJson({'ip': '198.51.100.8', 'device_id': 'b'});
    expect(a.ip, b.ip);
    expect(a.deviceId, isNot(b.deviceId));
  });
}
