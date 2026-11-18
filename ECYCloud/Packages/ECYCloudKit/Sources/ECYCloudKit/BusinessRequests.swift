import Foundation

extension ClientSession {
    public func announcements(silently: Bool = false) async throws -> AnnouncementBundle {
        let bundle: AnnouncementBundle = try await authenticated(silently: silently) { try await api.request("/announcements", origin: endpoints.site, token: $0.token) }
        announcementState.accept(bundle)
        return bundle
    }
    public func trafficHistory() async throws -> TrafficHistory {
        try await authenticated { try await api.request("/user/traffic-log", origin: endpoints.site, token: $0.token) }
    }
    public func tickets(page: Int, search: String) async throws -> TicketPage {
        let query = try pagination(page, search)
        let result: TicketPage = try await authenticated(allowRestricted: true) {
            try await api.request("/tickets", origin: endpoints.site, token: $0.token, query: query)
        }
        try validatePage(result.currentPage, result.lastPage, result.total, result.perPage, result.tickets.count)
        return result
    }
    public func ticket(_ id: Int) async throws -> TicketDetail {
        guard id > 0 else { throw ClientError.invalidResponse }
        return try await authenticated(allowRestricted: true) { try await api.request("/tickets/\(id)", origin: endpoints.site, token: $0.token) }
    }
    public func createTicket(title: String, text: String, attachments: [TicketAttachment] = []) async throws -> Int {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 1024 else { throw ClientError.input(L10n.t("请填写工单标题（最多 1024 字节）。")) }
        let html = try TicketContent.html(text, attachments: attachments)
        struct Created: Decodable, Sendable { let ticketId: Int }
        let result: Created = try await authenticated(allowRestricted: true) {
            try await api.request("/tickets", origin: endpoints.site, token: $0.token, body: ["title": title, "content": html])
        }
        guard result.ticketId > 0 else { throw ClientError.invalidResponse }
        return result.ticketId
    }
    public func replyTicket(_ id: Int, text: String, attachments: [TicketAttachment] = []) async throws -> String {
        guard id > 0 else { throw ClientError.invalidResponse }
        let html = try TicketContent.html(text, attachments: attachments)
        return try await authenticated(allowRestricted: true) {
            try await api.perform("/tickets/\(id)/reply", origin: endpoints.site, token: $0.token, body: ["content": html]).message
        }
    }
    public func closeTicket(_ id: Int) async throws -> String {
        guard id > 0 else { throw ClientError.invalidResponse }
        return try await authenticated(allowRestricted: true) {
            try await api.perform("/tickets/\(id)/close", origin: endpoints.site, token: $0.token, body: [:]).message
        }
    }
}

func pagination(_ page: Int, _ search: String) throws -> [URLQueryItem] {
    guard page > 0, search.utf8.count <= 1024 else { throw ClientError.input(L10n.t("搜索内容过长。")) }
    return [.init(name: "page", value: String(page)), .init(name: "length", value: "10"), .init(name: "search", value: search)]
}
func validatePage(_ current: Int, _ last: Int, _ total: Int, _ size: Int, _ count: Int) throws {
    guard current > 0, last > 0, total >= 0, [10, 25, 50, 100].contains(size), count <= size else { throw ClientError.invalidResponse }
}
