import Foundation
import CryptoKit
import Observation

public struct TunnelCommand: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case snapshot, logs, select, close, closeAll, mode, probe, probes, logging, version, rules, geodata }
    public let action: Action
    public let page: Int
    public let group: String
    public let node: String
    public let connectionID: String
    public let scope: String, query: String, level: String, mode: String
    public init(_ action: Action, page: Int = 1, group: String = "", node: String = "", connectionID: String = "", scope: String = "active", query: String = "", level: String = "", mode: String = "") {
        self.action = action; self.page = page; self.group = group; self.node = node; self.connectionID = connectionID
        self.scope = scope; self.query = query; self.level = level; self.mode = mode
    }
}
public struct TunnelCommandEnvelope: Codable, Sendable {
    public let leaseID: UUID
    public let command: TunnelCommand
    public init(leaseID: UUID, command: TunnelCommand) { self.leaseID = leaseID; self.command = command }
}
public struct TunnelSnapshot: Decodable, Sendable {
    public struct Connection: Decodable, Identifiable, Sendable {
        public let id: String, network: String, host: String, source: String, destination: String, start: String, rule: String
        public let ip: String, port: String, remoteDestination: String, rulePayload: String
        public let upload: Int64, download: Int64
        public let chains: [String]
        public let process: String, processPath: String, inbound: String
        public let closedAt: String?
    }
    public let upload: Int64, download: Int64, uploadTotal: Int64, downloadTotal: Int64
    public let connections: [Connection]
    public let total: Int, page: Int
    public let selections: [String: String]
    public let groups: [NodeSelectionGroup]
    public let delays: [String: Int]?
    public let memory: Int64
    public let active: Int, closed: Int
    public let mode: String
    public let rank: TrafficRankDelta?
}
public struct TunnelLogs: Decodable, Sendable {
    public struct Entry: Decodable, Identifiable, Sendable { public let id: Int64; public let time: String, level: String, message: String; public let inbound: String? }
    public let entries: [Entry]
    public let total: Int
}
public struct NodeProbe: Decodable, Sendable {
    public enum Kind: String, Sendable { case delay, speed, reselect }
    public let running: Bool, failed: Bool
    public let delay: Int
    public let speed: Int64
}
struct SpeedTestAllowance: Decodable, Sendable {
    struct Denied: Decodable, Sendable { let proxyName: String, msg: String; let resetAt: TimeInterval? }
    let allowed: [String]
    let denied: [Denied]
}
@MainActor @Observable public final class NodeProbeState {
    public fileprivate(set) var values: [String: NodeProbe] = [:]
    public fileprivate(set) var testing: Set<String> = []
    public fileprivate(set) var testingGroups: Set<String> = []
    fileprivate var generation = 0
    fileprivate var measuringSpeed = false
    fileprivate var activeDelays = 0
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var quotaScope: String?
    @ObservationIgnored private var speedStamps: [String: [TimeInterval]] = [:]
    public init(defaults: UserDefaults? = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.now = now
    }
    func configure(site: URL?, userID: Int?) {
        let next = site.flatMap { site in userID.map { "apple.speed-quota." + SHA256.hash(data: Data("\(site.absoluteString)|\($0)".utf8)).map { String(format: "%02x", $0) }.joined() } }
        guard quotaScope != next else { return }
        clear(); quotaScope = next
        speedStamps = next.flatMap { defaults?.dictionary(forKey: $0) as? [String: [TimeInterval]] } ?? [:]
    }
    func canTestSpeed(_ node: String) -> Bool {
        speedStamps[node] = speedStamps[node]?.filter { $0 >= now().timeIntervalSince1970 - 3600 }
        return (speedStamps[node]?.count ?? 0) < 5
    }
    func recordSpeed(_ node: String) {
        _ = canTestSpeed(node)
        speedStamps[node, default: []].append(now().timeIntervalSince1970)
        saveQuota()
    }
    func exhaustSpeed(_ node: String, resetAt: TimeInterval?) {
        speedStamps[node] = Array(repeating: (resetAt ?? now().timeIntervalSince1970 + 3600) - 3600, count: 5)
        saveQuota()
    }
    private func saveQuota() {
        guard let quotaScope else { return }
        defaults?.set(speedStamps, forKey: quotaScope)
    }
    public func result(_ node: String, kind: NodeProbe.Kind) -> NodeProbe? { values[kind.rawValue + "/" + node] }
    public func isTesting(_ node: String, kind: NodeProbe.Kind) -> Bool { testing.contains(kind.rawValue + "/" + node) }
    public func isTestingGroup(_ group: String, kind: NodeProbe.Kind) -> Bool { testingGroups.contains(kind.rawValue + "/" + group) }
    public static func resolve(_ name: String, selections: [String: String]) -> String {
        var node = name
        var visited = Set<String>()
        for _ in 0..<8 {
            guard visited.insert(node).inserted, let next = selections[node], !next.isEmpty else { break }
            node = next
        }
        return node
    }
    public static func isOfficial(_ name: String) -> Bool {
        name.range(of: #"^node-[1-9][0-9]*$"#, options: .regularExpression) != nil
    }
    func clear(keepingResults: Bool = false) {
        generation += 1
        if !keepingResults { values = [:] }
        testing = []; testingGroups = []; measuringSpeed = false; activeDelays = 0
    }
}
extension ClientSession {
    public func measureGroup(_ group: NodeSelectionGroup, selections: [String: String], kind: NodeProbe.Kind) async throws -> String? {
        guard kind != .reselect else { throw TunnelError.control }
        try await ensureControlPlane()
        let key = kind.rawValue + "/" + group.id
        guard nodeProbes.testingGroups.insert(key).inserted else { return nil }
        let generation = nodeProbes.generation
        defer { if generation == nodeProbes.generation { nodeProbes.testingGroups.remove(key) } }
        var seen = Set<String>()
        let nodes = group.members.map { NodeProbeState.resolve($0, selections: selections) }.filter {
            !$0.isEmpty && seen.insert($0).inserted && (kind != .speed || NodeProbeState.isOfficial($0))
        }
        if nodes.isEmpty { return nil }
        if kind == .speed { return try await measureSpeeds(nodes) }
        await withTaskGroup(of: Void.self) { tasks in
            var next = 0
            for node in nodes.prefix(8) {
                tasks.addTask { _ = try? await self.measureNode(node, kind: .delay) }
                next += 1
            }
            for await _ in tasks {
                guard generation == nodeProbes.generation, !Task.isCancelled else { tasks.cancelAll(); break }
                if next < nodes.count {
                    let node = nodes[next]; next += 1
                    tasks.addTask { _ = try? await self.measureNode(node, kind: .delay) }
                }
            }
        }
        try Task.checkCancellation()
        guard generation == nodeProbes.generation else { throw CancellationError() }
        if !group.selectable { _ = try await measureNode(group.id, kind: .reselect) }
        return nil
    }

    public func measureNode(_ name: String, kind: NodeProbe.Kind) async throws -> NodeProbe {
        if kind == .speed {
            guard NodeProbeState.isOfficial(name) else { throw ClientError.input(L10n.t("不是可测速的官方节点")) }
            if let notice = try await measureSpeeds([name]) { throw ClientError.input(notice) }
            guard let result = nodeProbes.result(name, kind: .speed), !result.failed else { throw ClientError.input(L10n.t("测速失败")) }
            return result
        }
        try await ensureControlPlane()
        let key = kind.rawValue + "/" + name
        guard nodeProbes.testing.insert(key).inserted else { throw CancellationError() }
        let generation = nodeProbes.generation
        defer { if nodeProbes.generation == generation { nodeProbes.testing.remove(key) } }
        var ownsDelayLane = false
        defer { if ownsDelayLane && nodeProbes.generation == generation { nodeProbes.activeDelays -= 1 } }
        while nodeProbes.activeDelays >= 8 {
            try await Task.sleep(for: .milliseconds(50))
            guard generation == nodeProbes.generation else { throw CancellationError() }
        }
        try Task.checkCancellation()
        guard generation == nodeProbes.generation else { throw CancellationError() }
        nodeProbes.activeDelays += 1; ownsDelayLane = true
        return try await runProbe(name, kind: kind, generation: generation)
    }

    private func measureSpeeds(_ names: [String]) async throws -> String? {
        try await ensureControlPlane()
        let token = try await authenticated { $0.token }
        let generation = nodeProbes.generation
        let pending = names.filter { nodeProbes.testing.insert("speed/" + $0).inserted }
        guard !pending.isEmpty else { throw CancellationError() }
        for name in pending where nodeProbes.result(name, kind: .speed)?.failed == true { nodeProbes.values["speed/" + name] = nil }
        var ownsSpeedLane = false
        defer {
            if generation == nodeProbes.generation {
                for name in pending { nodeProbes.testing.remove("speed/" + name) }
                if ownsSpeedLane { nodeProbes.measuringSpeed = false }
            }
        }
        while nodeProbes.measuringSpeed {
            try await Task.sleep(for: .milliseconds(100))
            guard generation == nodeProbes.generation else { throw CancellationError() }
        }
        try Task.checkCancellation()
        guard generation == nodeProbes.generation else { throw CancellationError() }
        nodeProbes.measuringSpeed = true; ownsSpeedLane = true
        let unlimited = profile?.id == 1
        let localBlocked = pending.filter { !unlimited && !nodeProbes.canTestSpeed($0) }
        let reserving = pending.filter { !localBlocked.contains($0) }
        for name in localBlocked { nodeProbes.testing.remove("speed/" + name) }
        var allowed = Set<String>(), denied: [SpeedTestAllowance.Denied] = []
        for offset in stride(from: 0, to: reserving.count, by: 256) {
            let batch = Array(reserving.dropFirst(offset).prefix(256))
            let body = try JSONEncoder().encode(["proxy_names": batch])
            let allowance: SpeedTestAllowance = try await authenticated {
                guard $0.token == token, generation == nodeProbes.generation else { throw CancellationError() }
                return try await api.request("/user/speed-test", origin: endpoints.site, token: token, jsonBody: body)
            }
            guard generation == nodeProbes.generation else { throw CancellationError() }
            allowed.formUnion(allowance.allowed.filter { batch.contains($0) })
            denied += allowance.denied.filter { batch.contains($0.proxyName) }
        }
        if !unlimited {
            for failure in denied {
                if let resetAt = failure.resetAt { nodeProbes.exhaustSpeed(failure.proxyName, resetAt: resetAt) }
            }
        }
        for name in pending where !allowed.contains(name) { nodeProbes.testing.remove("speed/" + name) }
        if allowed.isEmpty {
            return denied.first?.msg ?? (localBlocked.isEmpty ? L10n.t("面板未允许本次测速") : L10n.t("该节点 1 小时内测速已达 5 次，请稍后再试"))
        }
        for name in pending where allowed.contains(name) {
            try Task.checkCancellation()
            guard generation == nodeProbes.generation else { throw CancellationError() }
            do {
                let result = try await runProbe(name, kind: .speed, generation: generation)
                if !unlimited { nodeProbes.recordSpeed(name) }
                struct Report: Encodable { struct Result: Encodable { let proxy_name: String; let bytes_per_second: Int64 }; let results: [Result] }
                let body = try JSONEncoder().encode(Report(results: [.init(proxy_name: name, bytes_per_second: result.speed)]))
                do {
                    let report: SpeedTestAllowance = try await authenticated {
                        guard $0.token == token, generation == nodeProbes.generation else { throw CancellationError() }
                        return try await api.request("/user/speed-test", origin: endpoints.site, token: token, jsonBody: body)
                    }
                    guard generation == nodeProbes.generation else { throw CancellationError() }
                    if let failure = report.denied.first(where: { $0.proxyName == name }) {
                        if !unlimited { nodeProbes.exhaustSpeed(name, resetAt: failure.resetAt) }
                        nodeProbes.values["speed/" + name] = NodeProbe(running: false, failed: true, delay: 0, speed: 0)
                    }
                } catch let error as ClientError where !error.unauthorized {
                    // 测量已成功；面板暂时不可达不能把实测结果改成测速失败。
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                guard generation == nodeProbes.generation else { throw CancellationError() }
            }
            nodeProbes.testing.remove("speed/" + name)
        }
        let skipped = localBlocked.count + denied.count
        return skipped == 0 ? nil : pending.count == 1 ? denied.first?.msg : L10n.t("已跳过 {0} 个达到测速次数上限的节点", [String(describing: skipped)])
    }

    private func runProbe(_ name: String, kind: NodeProbe.Kind, generation: Int) async throws -> NodeProbe {
        guard let connection else { throw TunnelError.unavailable }
        let key = kind.rawValue + "/" + name
        func poll(_ action: TunnelCommand.Action) async throws -> NodeProbe {
            guard generation == nodeProbes.generation else { throw CancellationError() }
            return try JSONDecoder().decode(NodeProbe.self, from: await connection.request(.init(action, node: name, scope: kind.rawValue)))
        }
        do {
            var result = try await poll(.probe)
            let deadline = ContinuousClock.now + .seconds(kind == .speed ? 15 : 8)
            while result.running {
                guard ContinuousClock.now < deadline else { throw ClientError.input(kind == .speed ? L10n.t("测速超时") : L10n.t("延迟测试超时")) }
                try await Task.sleep(for: .milliseconds(300))
                result = try await poll(.probes)
            }
            guard generation == nodeProbes.generation else { throw CancellationError() }
            guard !result.failed, kind == .reselect || (kind == .delay ? result.delay > 0 : result.speed > 0) else { throw ClientError.input(kind == .speed ? L10n.t("测速失败") : L10n.t("节点不可用")) }
            nodeProbes.values[key] = result
            return result
        } catch {
            if nodeProbes.generation == generation && !(error is CancellationError) {
                nodeProbes.values[key] = NodeProbe(running: false, failed: true, delay: 0, speed: 0)
            }
            throw error
        }
    }
    public func tunnelSnapshot(page: Int = 1, scope: String = "active", query: String = "") async throws -> TunnelSnapshot {
        guard let connection else { throw TunnelError.unavailable }
        let data = try await connection.request(.init(.snapshot, page: page, scope: scope, query: query))
        guard let value = try? JSONDecoder().decode(TunnelSnapshot.self, from: data), value.total >= 0,
              value.page == page, value.connections.count <= 25, value.upload >= 0, value.download >= 0 else { throw TunnelError.control }
        // 与 Flutter 一致：只在接管连接期间记账，待机时取走的增量直接丢弃
        if let rank = value.rank, connection.state == .connected { trafficRank.add(rank) }
        for (node, delay) in value.delays ?? [:] where delay > 0 && !nodeProbes.isTesting(node, kind: .delay) {
            nodeProbes.values["delay/" + node] = NodeProbe(running: false, failed: false, delay: delay, speed: 0)
        }
        return value
    }
    public func tunnelLogs(page: Int = 1, level: String = "", query: String = "") async throws -> TunnelLogs {
        guard let connection else { throw TunnelError.unavailable }
        let data = try await connection.request(.init(.logs, page: page, query: query, level: level))
        guard let value = try? JSONDecoder().decode(TunnelLogs.self, from: data), (0...2000).contains(value.total), value.entries.count <= 20 else { throw TunnelError.control }
        return value
    }
    public func selectActiveNode(group: String, node: String) async throws {
        guard let connection else { throw TunnelError.control }
        let snapshot = try await tunnelSnapshot()
        guard snapshot.groups.contains(where: { $0.id == group && $0.selectable && $0.members.contains(node) }) else { throw TunnelError.control }
        _ = try await connection.request(.init(.select, group: group, node: node))
        selectNode(group: group, node: node)
    }
    public func setMode(_ mode: ClientPreferences.Mode) async throws {
        guard phase == .signedIn else { throw CancellationError() }
        if let connection, connection.controlPlaneReady {
            _ = try await connection.request(.init(.mode, mode: mode.rawValue))
        } else if let connection, connection.state != .disconnected { throw CancellationError() }
        preferences.mode = mode
    }
    public func closeConnection(_ id: String?) async throws {
        guard let connection else { throw TunnelError.unavailable }
        _ = try await connection.request(.init(id == nil ? .closeAll : .close, connectionID: id ?? ""))
    }
}
