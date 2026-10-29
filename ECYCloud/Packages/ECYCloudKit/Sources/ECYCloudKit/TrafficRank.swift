import Foundation
import CryptoKit
import Observation

public enum TrafficRankDay: Sendable { case today, yesterday }

public struct TrafficRankRow: Identifiable, Sendable {
    public let name: String
    public let bytes: Int64
    public var id: String { name }
}

public struct TrafficRankDelta: Decodable, Sendable {
    public let groups: [String: Int64]?
    public let hosts: [String: Int64]?
}

// 对应 app/lib/data/store/traffic_rank_store.dart：按账户分文件，只保留今天与昨天，每类取前 10。
@MainActor @Observable public final class TrafficRankStore {
    public static let topLimit = 10
    private static let maximumKeys = 4096
    private var days: [String: [String: [String: Int64]]] = [:]
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var savedAt: Date?
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let now: () -> Date

    public init(directory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("ECYCloud/traffic-rank", isDirectory: true), now: @escaping () -> Date = Date.init) {
        self.directory = directory; self.now = now
    }

    func configure(site: URL?, userID: Int?) {
        let name = site.flatMap { site in userID.map { SHA256.hash(data: Data("\(site.absoluteString)|\($0)".utf8)).map { String(format: "%02x", $0) }.joined() } }
        let next = name.flatMap { directory?.appendingPathComponent($0 + ".json") }
        guard next != file else { return }
        flush()
        file = next; savedAt = nil; dirty = false; days = [:]
        guard let next, let data = try? Data(contentsOf: next), data.count <= 4 << 20,
              let stored = try? JSONDecoder().decode([String: [String: [String: Int64]]].self, from: data) else { return }
        days = stored
        prune()
    }

    func add(_ delta: TrafficRankDelta) {
        guard file != nil else { return }
        let key = Self.dayKey(now(), offset: 0)
        var bucket = days[key] ?? [:]
        var changed = false
        for (kind, values) in [("groups", delta.groups ?? [:]), ("hosts", delta.hosts ?? [:])] {
            var target = bucket[kind] ?? [:]
            for (name, bytes) in values where !name.isEmpty && name.utf8.count <= 1024 && bytes > 0 {
                guard target[name] != nil || target.count < Self.maximumKeys else { continue }
                target[name, default: 0] += bytes
                changed = true
            }
            bucket[kind] = target
        }
        guard changed else { return }
        days[key] = bucket
        prune()
        dirty = true
        flush(force: false)
    }

    public func top(_ day: TrafficRankDay, hosts: Bool) -> [TrafficRankRow] {
        let bucket = days[Self.dayKey(now(), offset: day == .today ? 0 : -1)]?[hosts ? "hosts" : "groups"] ?? [:]
        return bucket.filter { $0.value > 0 }.map { TrafficRankRow(name: $0.key, bytes: $0.value) }
            .sorted { $0.bytes == $1.bytes ? $0.name < $1.name : $0.bytes > $1.bytes }.prefix(Self.topLimit).map { $0 }
    }

    func flush(force: Bool = true) {
        guard let file, dirty else { return }
        if !force, let savedAt, now().timeIntervalSince(savedAt) < 30 { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(days).write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            dirty = false; savedAt = now()
        } catch {}
    }

    private func prune() {
        let keep: Set<String> = [Self.dayKey(now(), offset: 0), Self.dayKey(now(), offset: -1)]
        days = days.filter { keep.contains($0.key) }
    }

    private static func dayKey(_ date: Date, offset: Int) -> String {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: offset, to: date) ?? date
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
