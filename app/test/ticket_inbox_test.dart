import 'package:ecycloud_client/state/auth_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('没有管理员回复则不显示红点', () {
    expect(
      AuthController.ticketReplyUnread(
        latestAdminReplyAt: '',
        userId: 1,
        seen: <String, dynamic>{},
      ),
      isFalse,
    );
  });

  test('首次安装没有已读记录时不把历史回复显示为新回复', () {
    expect(
      AuthController.ticketReplyUnread(
        latestAdminReplyAt: '2026-09-07 10:15:59',
        userId: 1,
        seen: <String, dynamic>{},
      ),
      isFalse,
    );
  });

  test('点过之后同一条回复不再显示红点', () {
    expect(
      AuthController.ticketReplyUnread(
        latestAdminReplyAt: '2026-09-07 10:15:59',
        userId: 1,
        seen: <String, dynamic>{
          'user_id': 1,
          'seen_admin_reply_at': '2026-09-07 10:15:59',
        },
      ),
      isFalse,
    );
  });

  test('管理员再次回复后重新显示红点', () {
    expect(
      AuthController.ticketReplyUnread(
        latestAdminReplyAt: '2026-09-08 09:00:00',
        userId: 1,
        seen: <String, dynamic>{
          'user_id': 1,
          'seen_admin_reply_at': '2026-09-07 10:15:59',
        },
      ),
      isTrue,
    );
  });

  test('首次切换账号不把该账号的历史回复显示为新回复', () {
    expect(
      AuthController.ticketReplyUnread(
        latestAdminReplyAt: '2026-09-07 10:15:59',
        userId: 2,
        seen: <String, dynamic>{
          'user_id': 1,
          'seen_admin_reply_at': '2026-09-07 10:15:59',
        },
      ),
      isFalse,
    );
  });

  test('首次记录为空时收到第一条管理员回复仍显示红点', () {
    expect(
      AuthController.ticketReplyUnread(
        latestAdminReplyAt: '2026-09-08 09:00:00',
        userId: 1,
        seen: <String, dynamic>{'user_id': 1, 'seen_admin_reply_at': ''},
      ),
      isTrue,
    );
  });

  test('服务端返回更早的回复时间不重新显示红点', () {
    expect(
      AuthController.ticketReplyUnread(
        latestAdminReplyAt: '2026-09-07 10:15:59',
        userId: 1,
        seen: <String, dynamic>{
          'user_id': 1,
          'seen_admin_reply_at': '2026-09-08 09:00:00',
        },
      ),
      isFalse,
    );
  });
}
