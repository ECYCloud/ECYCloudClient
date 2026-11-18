import Foundation

public struct Announcement: Decodable, Identifiable, Sendable {
    public let id: Int
    public let title: String, date: String, updatedAt: String, content: String
}
public struct AnnouncementBundle: Decodable, Sendable {
    public let announcements: [Announcement]
    public let popup: Announcement?
}
public struct TicketSummary: Decodable, Identifiable, Sendable {
    public let id: Int, status: Int
    public let title: String, statusText: String, datetime: String, lastReplyTime: String
}
public struct TicketPage: Decodable, Sendable {
    public let tickets: [TicketSummary]
    public let banned: Bool, enableTicket: Bool
    public let currentPage: Int, lastPage: Int, total: Int, perPage: Int
}
public struct TicketDetail: Decodable, Identifiable, Sendable {
    public struct Message: Decodable, Identifiable, Sendable {
        public let id: Int
        public let isAdmin: Bool
        public let userName: String, content: String, datetime: String
        enum CodingKeys: String, CodingKey { case id, isAdmin, userName, content, datetime }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            isAdmin = try c.decode(Bool.self, forKey: .isAdmin)
            content = try c.decode(String.self, forKey: .content)
            datetime = try c.decode(String.self, forKey: .datetime)
            let name = (try c.decodeIfPresent(String.self, forKey: .userName) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            userName = name.isEmpty ? L10n.t(isAdmin ? "管理员" : "我") : name
        }
    }
    public let id: Int, status: Int, messageCount: Int
    public let title: String, statusText: String, datetime: String
    public let banned: Bool, enableTicket: Bool
    public let messages: [Message]
}
public enum TicketContent {
    public static func html(_ text: String) throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.count <= 1000 else {
            throw ClientError.input(L10n.t("工单内容需为 1–1000 字。"))
        }
        return escape(text).replacingOccurrences(of: "\n", with: "<br>")
    }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
}

public struct TrafficHistory: Decodable, Sendable {
    public struct Day: Decodable, Sendable {
        public let totalUsage: String, totalUpload: String, totalDownload: String, rateInfo: String
    }
    public struct Node: Decodable, Sendable {
        public let nodeName: String, nodeRateStr: String
        public let nodeTrafficRate: Double
        public let dailyUpload: Int64, dailyDownload: Int64, dailyUsage: Int64
    }
    public let traffic: [String: Day]
    public let nodeTraffic: [String: [Node]]
    public let totalUpload: String, totalDownload: String, totalUsage: String, totalRateInfo: String
    public let logKeepDays: Int
    enum CodingKeys: String, CodingKey { case traffic, nodeTraffic, totalUpload, totalDownload, totalUsage, totalRateInfo, logKeepDays }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        traffic = try c.phpMap([String: Day].self, forKey: .traffic)
        nodeTraffic = try c.phpMap([String: [Node]].self, forKey: .nodeTraffic)
        totalUpload = try c.decode(String.self, forKey: .totalUpload)
        totalDownload = try c.decode(String.self, forKey: .totalDownload)
        totalUsage = try c.decode(String.self, forKey: .totalUsage)
        totalRateInfo = try c.decode(String.self, forKey: .totalRateInfo)
        logKeepDays = try c.decode(Int.self, forKey: .logKeepDays)
    }
}

// PHP 空关联数组编码为 []，只允许空数组按空字典解析。
extension KeyedDecodingContainer {
    func phpMap<V: Decodable>(_ type: [String: V].Type, forKey key: Key) throws -> [String: V] {
        if let value = try? decode(type, forKey: key) { return value }
        let array = try decode([V].self, forKey: key)
        guard array.isEmpty else { throw ClientError.invalidResponse }
        return [:]
    }
}
extension ClientError {
    static func input(_ message: String) -> Self { .server(status: 400, code: 0, message: message, retryAfter: nil) }
}

public enum ClientLink {
    public static func external(_ text: String) -> URL? {
        guard text.utf8.count <= 8192, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: text), url.user == nil, url.password == nil,
              let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tg"].contains(scheme) else { return nil }
        if ["http", "https"].contains(scheme), url.host?.isEmpty != false { return nil }
        return url
    }
}
