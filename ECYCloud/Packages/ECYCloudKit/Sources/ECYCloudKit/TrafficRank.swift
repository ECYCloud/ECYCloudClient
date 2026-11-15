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
// 与 OpenWrt statistics.uc 同一口径：当天内存计数受键数上限约束，落盘只留每类前 100
@MainActor @Observable public final class TrafficRankStore {
    public static let topLimit = 10
    private static let keepLimit = 100, maximumGroups = 512, maximumHosts = 10_000, maximumHostBytes = 253
    private var days: [String: [String: [String: Int64]]] = [:]
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var savedAt: Date?
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let now: () -> Date

    public init(directory: URL? = UserDataDirectory.root?.appendingPathComponent("traffic-rank", isDirectory: true), now: @escaping () -> Date = Date.init) {
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
        for (kind, values, keys, length) in [("groups", delta.groups ?? [:], Self.maximumGroups, 1024),
                                             ("hosts", delta.hosts ?? [:], Self.maximumHosts, Self.maximumHostBytes)] {
            var target = bucket[kind] ?? [:]
            for (name, bytes) in values where !name.isEmpty && name.utf8.count <= length && bytes > 0 {
                guard target[name] != nil || target.count < keys else { continue }
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
            try JSONEncoder().encode(Self.recent(days, now: now())).write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            dirty = false; savedAt = now()
        } catch { return }
        pruneOtherAccounts(except: file)
    }

    // 其它账户只留今天与昨天：过期日期一并清掉，同账户再登录仍能恢复近两天排行
    private func pruneOtherAccounts(except file: URL) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        for other in (try? FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: keys)) ?? []
        where other.pathExtension == "json" && other.lastPathComponent != file.lastPathComponent {
            guard let values = try? other.resourceValues(forKeys: Set(keys)), values.isRegularFile == true, values.isSymbolicLink != true,
                  let data = try? Data(contentsOf: other), data.count <= 4 << 20,
                  let stored = try? JSONDecoder().decode([String: [String: [String: Int64]]].self, from: data) else { continue }
            let recent = Self.recent(stored, now: now())
            if recent.isEmpty { try? FileManager.default.removeItem(at: other) }
            else if recent != stored { try? JSONEncoder().encode(recent).write(to: other, options: [.atomic]) }
        }
    }

    private static func recent(_ days: [String: [String: [String: Int64]]], now: Date) -> [String: [String: [String: Int64]]] {
        var out: [String: [String: [String: Int64]]] = [:]
        for key in [dayKey(now, offset: 0), dayKey(now, offset: -1)] {
            out[key] = days[key]?.mapValues { values in
                Dictionary(uniqueKeysWithValues: values.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(keepLimit).map { ($0.key, $0.value) })
            }
        }
        return out
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
