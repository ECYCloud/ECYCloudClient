import 'package:ecycloud_client/data/models/user_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('流量字段与面板用户中心公式一致', () {
    final UserProfile profile = UserProfile.fromJson(<String, dynamic>{
      'id': 1,
      'email': 'a@b.c',
      'user_name': 'u',
      'upload': 300,
      'download': 700,
      'last_day_t': 400,
      'transfer_enable': 2000,
      'config_revision': 'r',
    });

    expect(profile.used, 1000);
    expect(profile.todayUsed, 600);
    expect(profile.lastUsed, 400);
    expect(profile.remaining, 1000);
    expect(profile.transferEnable - profile.used, 1000);
  });

  test('超量使用时剩余可为负且今日已用不为负', () {
    final UserProfile profile = UserProfile.fromJson(<String, dynamic>{
      'id': 1,
      'email': 'a@b.c',
      'upload': 800,
      'download': 800,
      'last_day_t': 2000,
      'transfer_enable': 1000,
      'config_revision': 'r',
    });

    expect(profile.todayUsed, 0);
    expect(profile.lastUsed, 2000);
    expect(profile.remaining, 0);
    expect(profile.transferEnable - profile.used, -600);
  });
}
