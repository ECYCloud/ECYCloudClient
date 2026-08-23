class Announcement {
  const Announcement({
    required this.id,
    required this.title,
    required this.date,
    required this.updatedAt,
    required this.content,
  });

  final int id;
  final String title;
  final String date;
  final String updatedAt;
  final String content;

  DateTime? get revisedAt => DateTime.tryParse(
    updatedAt.isNotEmpty ? updatedAt : date,
  );

  factory Announcement.fromJson(Map<String, dynamic> json) => Announcement(
    id: (json['id'] as num).toInt(),
    title: json['title'] as String? ?? '',
    date: json['date'] as String? ?? '',
    updatedAt: json['updated_at'] as String? ?? json['date'] as String? ?? '',
    content: json['content'] as String? ?? '',
  );
}

class AnnouncementBundle {
  const AnnouncementBundle({required this.items, this.popup});

  final List<Announcement> items;
  final Announcement? popup;

  factory AnnouncementBundle.fromJson(Map<String, dynamic> json) {
    final Object? raw = json['announcements'];
    final Object? popup = json['popup'];
    return AnnouncementBundle(
      items: <Announcement>[
        if (raw is List)
          for (final Object? item in raw)
            if (item is Map<String, dynamic>) Announcement.fromJson(item),
      ],
      popup: popup is Map<String, dynamic>
          ? Announcement.fromJson(popup)
          : null,
    );
  }
}
