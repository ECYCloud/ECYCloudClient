class TicketSummary {
  const TicketSummary({
    required this.id,
    required this.title,
    required this.status,
    required this.statusText,
    required this.datetime,
    required this.lastReplyTime,
  });

  final int id;
  final String title;
  final int status;
  final String statusText;
  final String datetime;
  final String lastReplyTime;

  factory TicketSummary.fromJson(Map<String, dynamic> json) => TicketSummary(
    id: (json['id'] as num).toInt(),
    title: json['title'] as String? ?? '',
    status: (json['status'] as num?)?.toInt() ?? 0,
    statusText: json['status_text'] as String? ?? '',
    datetime: json['datetime'] as String? ?? '',
    lastReplyTime: json['last_reply_time'] as String? ?? '',
  );
}

class TicketMessage {
  const TicketMessage({
    required this.id,
    required this.isAdmin,
    required this.userName,
    required this.content,
    required this.datetime,
  });

  final int id;
  final bool isAdmin;
  final String userName;
  final String content;
  final String datetime;

  factory TicketMessage.fromJson(Map<String, dynamic> json) {
    final bool isAdmin = json['is_admin'] as bool? ?? false;
    final String rawName = (json['user_name'] as String? ?? '').trim();
    return TicketMessage(
      id: (json['id'] as num).toInt(),
      isAdmin: isAdmin,
      // 旧面板未下发 user_name 时回退，避免空白
      userName: rawName.isNotEmpty ? rawName : (isAdmin ? '管理员' : '我'),
      content: json['content'] as String? ?? '',
      datetime: json['datetime'] as String? ?? '',
    );
  }
}

class TicketListPage {
  const TicketListPage({
    required this.tickets,
    required this.banned,
    required this.currentPage,
    required this.lastPage,
    required this.total,
    required this.perPage,
  });

  final List<TicketSummary> tickets;
  final bool banned;
  final int currentPage;
  final int lastPage;
  final int total;
  final int perPage;

  factory TicketListPage.fromJson(Map<String, dynamic> json) {
    final Object? raw = json['tickets'];
    return TicketListPage(
      tickets: <TicketSummary>[
        if (raw is List)
          for (final Object? item in raw)
            if (item is Map<String, dynamic>) TicketSummary.fromJson(item),
      ],
      banned: json['banned'] as bool? ?? false,
      currentPage: (json['current_page'] as num?)?.toInt() ?? 1,
      lastPage: (json['last_page'] as num?)?.toInt() ?? 1,
      total: (json['total'] as num?)?.toInt() ?? 0,
      perPage: (json['per_page'] as num?)?.toInt() ?? 10,
    );
  }
}

class TicketDetail {
  const TicketDetail({
    required this.id,
    required this.title,
    required this.status,
    required this.statusText,
    required this.datetime,
    required this.messages,
    required this.banned,
    this.messageCount = 0,
    this.enableTicket = true,
  });

  final int id;
  final String title;
  final int status;
  final String statusText;
  final String datetime;
  final List<TicketMessage> messages;
  final bool banned;
  final int messageCount;
  final bool enableTicket;

  factory TicketDetail.fromJson(Map<String, dynamic> json) {
    final Object? raw = json['messages'];
    final List<TicketMessage> messages = <TicketMessage>[
      if (raw is List)
        for (final Object? item in raw)
          if (item is Map<String, dynamic>) TicketMessage.fromJson(item),
    ];
    return TicketDetail(
      id: (json['id'] as num).toInt(),
      title: json['title'] as String? ?? '',
      status: (json['status'] as num?)?.toInt() ?? 0,
      statusText: json['status_text'] as String? ?? '',
      datetime: json['datetime'] as String? ?? '',
      messages: messages,
      banned: json['banned'] as bool? ?? false,
      messageCount: (json['message_count'] as num?)?.toInt() ?? messages.length,
      enableTicket: json['enable_ticket'] != false,
    );
  }
}
