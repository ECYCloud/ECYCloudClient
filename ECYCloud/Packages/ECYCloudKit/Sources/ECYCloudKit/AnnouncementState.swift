import Foundation
import CryptoKit
import Observation

@MainActor @Observable
public final class AnnouncementState {
    public private(set) var bundle: AnnouncementBundle?
    public private(set) var seen: [String: String] = [:]
    private var dismissed: [String: String] = [:]
    private var presented: Set<String> = []
    private var scope: String?
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func configure(site: URL?, userID: Int?) {
        let next = site.flatMap { site in userID.map { "apple.announcements." + SHA256.hash(data: Data("\(site.absoluteString)|\($0)".utf8)).map { String(format: "%02x", $0) }.joined() } }
        guard scope != next else { return }
        scope = next; bundle = nil; presented = []
        seen = next.flatMap { defaults.dictionary(forKey: $0 + ".seen") as? [String: String] } ?? [:]
        dismissed = next.flatMap { defaults.dictionary(forKey: $0 + ".dismissed") as? [String: String] } ?? [:]
    }
    public func accept(_ bundle: AnnouncementBundle) { guard scope != nil else { return }; self.bundle = bundle }
    public var hasUnread: Bool { bundle?.announcements.contains { $0.id != 1 && seen[String($0.id)] != $0.updatedAt } == true }
    public func markSeen(_ item: Announcement) {
        guard let scope else { return }
        seen[String(item.id)] = item.updatedAt
        defaults.set(seen, forKey: scope + ".seen")
    }
    public func markAllSeen() {
        guard let scope, let bundle else { return }
        seen = Dictionary(bundle.announcements.map { (String($0.id), $0.updatedAt) }, uniquingKeysWith: { _, next in next })
        defaults.set(seen, forKey: scope + ".seen")
    }
    public func openIndex(_ items: [Announcement]) -> Int {
        var best: Int?, bestAt: Date?
        for (index, item) in items.enumerated() where item.id != 1 && seen[String(item.id)] != item.updatedAt {
            let at = Self.revisedAt(item)
            if best == nil || at != nil && (bestAt == nil || at! > bestAt!) { best = index; bestAt = at }
        }
        if let best { return best }
        var latest = 0
        bestAt = nil
        for (index, item) in items.enumerated() where !(item.id == 1 && items.count > 1) {
            if let at = Self.revisedAt(item), bestAt == nil || at > bestAt! { latest = index; bestAt = at }
        }
        return latest
    }
    static func revisedAt(_ item: Announcement) -> Date? {
        let text = item.updatedAt.isEmpty ? item.date : item.updatedAt
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            iso.formatOptions = options
            if let date = iso.date(from: text) { return date }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
    public func takePopup() -> Announcement? {
        guard scope != nil, let popup = bundle?.popup, dismissed[String(popup.id)] != popup.updatedAt else { return nil }
        let key = "\(popup.id)|\(popup.updatedAt)"
        guard presented.insert(key).inserted else { return nil }
        markSeen(popup)
        return popup
    }
    public func dismissPopup(_ item: Announcement) {
        guard let scope else { return }
        dismissed = [String(item.id): item.updatedAt]
        defaults.set(dismissed, forKey: scope + ".dismissed")
    }
}
