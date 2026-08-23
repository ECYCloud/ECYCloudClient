import 'package:ecycloud_client/data/models/announcement.dart';
import 'package:ecycloud_client/state/announcement_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Announcement _item({
  required int id,
  required String date,
  String? updatedAt,
}) {
  return Announcement(
    id: id,
    title: 't$id',
    date: date,
    updatedAt: updatedAt ?? date,
    content: 'c',
  );
}

void main() {
  test('updated_at 缺失时回落到 date', () {
    final Announcement item = Announcement.fromJson(<String, dynamic>{
      'id': 2,
      'title': 't',
      'date': '2026-08-01 00:00:00',
      'content': 'c',
    });
    expect(item.updatedAt, '2026-08-01 00:00:00');
  });

  test('点铃铛落到最近一条未读，而不是列表第一项', () {
    final List<Announcement> items = <Announcement>[
      _item(id: 1, date: '2020-01-01 00:00:00'),
      _item(id: 3, date: '2026-08-20 00:00:00'),
      _item(
        id: 2,
        date: '2026-08-10 00:00:00',
        updatedAt: '2026-08-22 12:00:00',
      ),
    ];
    final Map<String, String> seen = <String, String>{
      '1': '2020-01-01 00:00:00',
    };

    expect(AnnouncementController.focusUnreadIndex(items, seen), 2);
  });

  test('弹窗已读后若没有其它未读则不再有红点', () {
    final List<Announcement> items = <Announcement>[
      _item(id: 1, date: '2020-01-01 00:00:00'),
      _item(id: 4, date: '2026-08-23 00:00:00'),
    ];
    final Map<String, String> seen = <String, String>{
      '1': '2020-01-01 00:00:00',
      '4': '2026-08-23 00:00:00',
    };

    expect(AnnouncementController.focusUnreadIndex(items, seen), isNull);
  });

  test('同一条被编辑后重新算未读', () {
    final List<Announcement> items = <Announcement>[
      _item(
        id: 2,
        date: '2026-08-01 00:00:00',
        updatedAt: '2026-08-23 08:00:00',
      ),
    ];
    final Map<String, String> seen = <String, String>{
      '2': '2026-08-01 00:00:00',
    };

    expect(AnnouncementController.focusUnreadIndex(items, seen), 0);
  });
}
