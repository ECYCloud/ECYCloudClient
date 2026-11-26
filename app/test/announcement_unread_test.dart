import 'package:ecycloud_client/data/models/announcement.dart';
import 'package:ecycloud_client/state/announcement_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Announcement _item({required int id, required String date, String? updatedAt}) {
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

  test('最新一条已读、旧公告未读时红点仍亮，铃铛打开最新发布的一条', () {
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
      '3': '2026-08-20 00:00:00',
    };

    expect(AnnouncementController.focusUnreadIndex(items, seen), 2);
    expect(AnnouncementController.latestIndex(items), 1);
    expect(
      AnnouncementController.focusUnreadIndex(items, <String, String>{}),
      1,
    );
  });

  test('切换语言后旧公告译文较新，仍打开最新发布的一条', () {
    final List<Announcement> items = <Announcement>[
      _item(
        id: 5,
        date: '2026-08-20 00:00:00',
        updatedAt: '2026-08-21 00:00:00',
      ),
      _item(
        id: 2,
        date: '2026-01-01 00:00:00',
        updatedAt: '2026-11-01 00:00:00',
      ),
    ];
    final Map<String, String> seen = <String, String>{
      '5': '2026-08-20 00:00:00',
      '2': '2026-01-01 00:00:00',
    };

    expect(AnnouncementController.focusUnreadIndex(items, seen), 0);
    expect(AnnouncementController.latestIndex(items), 0);
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

  test('置顶 id=1 未读也不抢焦点，红点只跟其余公告', () {
    final List<Announcement> items = <Announcement>[
      _item(id: 1, date: '2020-01-01 00:00:00'),
      _item(id: 4, date: '2026-08-23 00:00:00'),
    ];
    final Map<String, String> seen = <String, String>{
      '4': '2026-08-23 00:00:00',
    };

    expect(AnnouncementController.focusUnreadIndex(items, seen), isNull);
    expect(AnnouncementController.latestIndex(items), 1);
  });

  test('没有未读时打开最新发布的一条，而不是置顶第一条', () {
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
      for (final Announcement item in items) '${item.id}': item.updatedAt,
    };

    expect(AnnouncementController.focusUnreadIndex(items, seen), isNull);
    expect(AnnouncementController.latestIndex(items), 1);
  });
}
