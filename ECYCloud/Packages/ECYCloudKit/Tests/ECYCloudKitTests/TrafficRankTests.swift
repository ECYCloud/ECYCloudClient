import Foundation
import Testing
@testable import ECYCloudKit

// 与 OpenWrt 同一口径：超长主机名不计入，内存键数有上限，落盘每类只留前 100，其它账户的过期日期随落盘清掉
@Suite("流量排行") @MainActor
struct TrafficRankTests {
    private let site = URL(string: "https://panel.example.test")!
    private let day: TimeInterval = 86_400

    private func fixture() throws -> (URL, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ecycloud-rank-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, { try? FileManager.default.removeItem(at: directory) })
    }

    private static func key(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func saved(_ directory: URL) throws -> [String: [String: [String: [String: Int64]]]] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map {
            ($0.lastPathComponent, try JSONDecoder().decode([String: [String: [String: Int64]]].self, from: Data(contentsOf: $0)))
        })
    }

    @Test func longHostsAndExtraKeysAreNotCounted() throws {
        let (directory, cleanup) = try fixture(); defer { cleanup() }
        let rank = TrafficRankStore(directory: directory, now: { Date(timeIntervalSince1970: 1_790_000_000) })
        rank.configure(site: site, userID: 1)
        rank.add(TrafficRankDelta(groups: ["组": 5], hosts: [String(repeating: "a", count: 249) + ".com": 5, String(repeating: "b", count: 250) + ".com": 900]))
        #expect(rank.top(.today, hosts: true).map(\.name) == [String(repeating: "a", count: 249) + ".com"])
        rank.add(TrafficRankDelta(groups: Dictionary(uniqueKeysWithValues: (0..<600).map { ("组\($0)", Int64(1)) }),
                                  hosts: Dictionary(uniqueKeysWithValues: (0..<10_001).map { ("h\($0).test", Int64(1)) })))
        rank.add(TrafficRankDelta(groups: ["迟到组": 1000], hosts: ["late.test": 1000]))
        #expect(rank.top(.today, hosts: false).first?.name != "迟到组")
        #expect(rank.top(.today, hosts: true).first?.name != "late.test")
        rank.add(TrafficRankDelta(groups: ["组": 1000], hosts: [String(repeating: "a", count: 249) + ".com": 1000]))
        #expect(rank.top(.today, hosts: false).first?.name == "组")
        #expect(rank.top(.today, hosts: true).first?.bytes == 1005)
    }

    @Test func persistedRankKeepsTopHundredWhileMemoryKeepsCounts() throws {
        let (directory, cleanup) = try fixture(); defer { cleanup() }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let rank = TrafficRankStore(directory: directory, now: { now })
        rank.configure(site: site, userID: 1)
        rank.add(TrafficRankDelta(groups: Dictionary(uniqueKeysWithValues: (0..<150).map { ("组\($0)", Int64(1000 + $0)) }),
                                  hosts: Dictionary(uniqueKeysWithValues: (0..<150).map { ("h\($0).test", Int64(1000 + $0)) })))
        rank.flush()
        let today = try #require(saved(directory).values.first?[Self.key(now)])
        #expect(today["groups"]?.count == 100 && today["hosts"]?.count == 100)
        #expect(today["hosts"]?["h149.test"] != nil && today["hosts"]?["h0.test"] == nil)
        rank.add(TrafficRankDelta(groups: nil, hosts: ["h0.test": 5000]))
        let top = try #require(rank.top(.today, hosts: true).first)
        #expect(top.name == "h0.test" && top.bytes == 6000)
        #expect(rank.top(.today, hosts: false).count == TrafficRankStore.topLimit)
    }

    @Test func flushDropsOtherAccountsExpiredDaysButKeepsRecentOnes() throws {
        let (directory, cleanup) = try fixture(); defer { cleanup() }
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        let other = TrafficRankStore(directory: directory, now: { now })
        other.configure(site: site, userID: 2)
        other.add(TrafficRankDelta(groups: ["组": 10], hosts: ["b-old.test": 10]))
        other.flush()
        let stale = TrafficRankStore(directory: directory, now: { now })
        stale.configure(site: site, userID: 3)
        stale.add(TrafficRankDelta(groups: ["组": 10], hosts: ["c-old.test": 10]))
        stale.configure(site: nil, userID: nil)
        now += day
        other.add(TrafficRankDelta(groups: ["组": 10], hosts: ["b-recent.test": 10]))
        other.configure(site: nil, userID: nil)
        #expect(try saved(directory).values.contains { $0.values.contains { $0["hosts"]?["b-old.test"] != nil } })
        now += day
        let rank = TrafficRankStore(directory: directory, now: { now })
        rank.configure(site: site, userID: 1)
        rank.add(TrafficRankDelta(groups: ["美国": 100], hosts: ["a.test": 100]))
        rank.flush()
        let files = try saved(directory)
        #expect(files.count == 2)
        #expect(!files.values.contains { $0.values.contains { $0["hosts"]?["b-old.test"] != nil || $0["hosts"]?["c-old.test"] != nil } })
        rank.configure(site: site, userID: 2)
        #expect(rank.top(.yesterday, hosts: true).map(\.name) == ["b-recent.test"])
        rank.configure(site: site, userID: 1)
        #expect(rank.top(.today, hosts: true).map(\.name) == ["a.test"])
    }
}
