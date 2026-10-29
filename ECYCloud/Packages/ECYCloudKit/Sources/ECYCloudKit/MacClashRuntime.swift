#if os(macOS)
import Foundation
import CryptoKit

@MainActor final class MacClashRuntime {
    let mixedPort: Int
    private let port: Int, secret: String
    private let transport: any HTTPTransport
    private let redactor: MacLogRedactor
    private let ruleFiles: [String: String]
    private var logStore: ClientLogStore?
    private var active: [String: [String: Any]] = [:]
    private var closed: [[String: Any]] = []
    private var logs: [[String: Any]] = []
    private var sequence = 0
    private var sampled = ContinuousClock.now
    private var proxyTotals: (Int64, Int64) = (0, 0)
    private var trafficSampled = false
    private var rates: (Int64, Int64) = (0, 0)
    private var servers: Set<String> = []
    private var rank: [String: [String: Int64]] = ["groups": [:], "hosts": [:]]
    private var memory: Int64 = 0
    private var memoryTask: Task<Void, Never>?
    private var sampleTask: Task<Void, Never>?
    private var sampling = false
    private var speedTask: Task<Int64, any Error>?
    private var probes: [String: [String: Any]] = [:]
    private var stopped = false
    private static let connectionSource = try! NSRegularExpression(pattern: #"^\[(?:TCP|UDP)\] (\[[^\]]+\]:\d+|[^\s(]+:\d+)"#)

    init(configuration: [String: Any], transport: any HTTPTransport, logStore: ClientLogStore? = nil) throws {
        guard let endpoint = configuration["external-controller"] as? String,
              endpoint.hasPrefix("127.0.0.1:"), let port = Int(endpoint.dropFirst("127.0.0.1:".count)),
              let mixed = configuration["mixed-port"] as? Int, (1024...65535).contains(port),
              (1024...65535).contains(mixed), port != mixed, port != (mixed < 65535 ? mixed + 1 : mixed - 1),
              let secret = configuration["secret"] as? String, (32...4096).contains(secret.utf8.count),
              secret.utf8.allSatisfy({ (33...126).contains($0) }) else { throw TunnelError.configuration }
        self.port = port; mixedPort = mixed; self.secret = secret; self.transport = transport
        redactor = MacLogRedactor(configuration: configuration)
        ruleFiles = (configuration["rule-providers"] as? [String: [String: Any]] ?? [:]).compactMapValues { $0["path"] as? String }
        let payloads = (configuration["proxy-providers"] as? [String: [String: Any]] ?? [:]).values.flatMap { $0["payload"] as? [[String: Any]] ?? [] }
        servers = Set(((configuration["proxies"] as? [[String: Any]] ?? []) + payloads).compactMap { ($0["server"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() })
        self.logStore = logStore
    }

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var parts = URLComponents()
        parts.scheme = "http"; parts.host = "127.0.0.1"; parts.port = port
        parts.percentEncodedPath = path
        if !query.isEmpty { parts.queryItems = query }
        return parts.url!
    }
    private func encoded(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 1024 else { throw TunnelError.control }
        return value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    }
    private func api(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                     query: [URLQueryItem] = [], timeout: TimeInterval = 10) async throws -> [String: Any] {
        var request = URLRequest(url: url(path, query: query), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let response = try await transport.send(request)
        guard [200, 204].contains(response.status), response.data.count <= URLSessionTransport.maximumResponseBytes else { throw TunnelError.control }
        if response.data.isEmpty { return [:] }
        guard let value = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { throw TunnelError.control }
        return value
    }

    func ready() async throws {
        _ = try await api("/version", timeout: 2)
        _ = try await api("/proxies/ecy-speed", method: "PUT", body: ["name": "DIRECT"], timeout: 2)
        // 转发探测只携带独立测速口令，不能把控制密钥交给代理出站。
        let status = try await MacSocket.forwardProbe(port: probePort, controller: port, credential: speedCredential)
        guard status == 401 else { throw TunnelError.start }
    }

    var probePort: Int { mixedPort < 65535 ? mixedPort + 1 : mixedPort - 1 }
    var speedCredential: String {
        "ecy-speed:" + SHA256.hash(data: Data("ecy-speed\0\(secret)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func disableTUN() async throws { _ = try await api("/configs", method: "PATCH", body: ["tun": ["enable": false]], timeout: 3) }
    func close() {
        stopped = true
        memoryTask?.cancel(); memoryTask = nil
        sampleTask?.cancel(); sampleTask = nil
        speedTask?.cancel(); speedTask = nil
    }

    // 与 Kernel/engine.go 的每秒采样一致：流量排行与已关闭连接不依赖界面是否在拉快照
    func startTrafficSampling() {
        sampleTask = Task { [weak self] in
            while let self, !Task.isCancelled, !self.stopped {
                _ = try? await self.sample()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func startMemoryProbe() {
        memoryTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && !self.stopped {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.connectionProxyDictionary = [:]
                configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
                configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 60
                let session = URLSession(configuration: configuration)
                do {
                    var request = URLRequest(url: self.url("/memory"))
                    request.setValue("Bearer " + self.secret, forHTTPHeaderField: "Authorization")
                    let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirects())
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TunnelError.control }
                    var line = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard !self.stopped, line.count < 65536 else { throw TunnelError.control }
                        if byte == 10 {
                            if let value = try JSONSerialization.jsonObject(with: line) as? [String: Any], let size = value["inuse"] as? Int64 { self.memory = size }
                            line.removeAll(keepingCapacity: true)
                        } else { line.append(byte) }
                    }
                } catch {}
                session.invalidateAndCancel()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func appendLogs(_ lines: [String]) {
        for line in lines {
            sequence += 1
            let level = line.range(of: #"(?<=level=)[a-z]+"#, options: .regularExpression).map { String(line[$0]) } ?? "info"
            var message = line
            if let range = line.range(of: "msg=") {
                let raw = String(line[range.upperBound...])
                message = (try? JSONDecoder().decode(String.self, from: Data(raw.utf8))) ?? raw
            }
            let time = ISO8601DateFormatter().string(from: .now), safe = redactor.redact(message)
            logs.append(["id": sequence, "time": time, "level": level, "message": safe])
            logStore?.append(time: time, level: level, message: safe)
        }
        if logs.count > 2000 { logs.removeFirst(logs.count - 2000) }
    }

    func request(_ command: TunnelCommand) async throws -> Data {
        guard !stopped, (1...100000).contains(command.page), command.query.utf8.count <= 1024 else { throw TunnelError.control }
        let result: [String: Any]
        switch command.action {
        case .logging:
            guard ClientLogStore.levels.contains(command.level) else { throw TunnelError.control }
            logStore?.level = command.level; result = ["ok": true]
        case .version: result = try await api("/version")
        case .rules:
            let response = try await api("/providers/rules")
            let providers = response["providers"] as? [String: [String: Any]] ?? [:]
            result = ["providers": Dictionary(uniqueKeysWithValues: providers.compactMap { name, value -> (String, [String: Any])? in
                guard let path = ruleFiles[name] else { return nil }
                return (name, value.merging(["path": path]) { _, new in new })
            })]
        case .geodata:
            _ = try await api("/configs/geo", method: "POST", timeout: 100); result = ["ok": true]
        case .snapshot: result = try await snapshot(command)
        case .logs:
            guard ["", "debug", "info", "warning", "error"].contains(command.level) else { throw TunnelError.control }
            let query = command.query.trimmingCharacters(in: .whitespacesAndNewlines)
            let filtered = logs.reversed().filter {
                (command.level.isEmpty || $0["level"] as? String == command.level) &&
                (query.isEmpty || ($0["message"] as! String).localizedCaseInsensitiveContains(query))
            }
            // 与 Kernel/control.go 一致：连接日志只带源地址，按源地址回查入站类型，活跃连接优先
            var inbound: [String: String] = [:]
            for value in closed + Array(active.values) {
                if let source = value["source"] as? String, let type = value["inbound"] as? String, !type.isEmpty { inbound[source] = type }
            }
            let entries = filtered.dropFirst((command.page - 1) * 20).prefix(20).map { entry in
                let message = entry["message"] as! String
                guard let match = Self.connectionSource.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                      let range = Range(match.range(at: 1), in: message), let type = inbound[String(message[range])] else { return entry }
                return entry.merging(["inbound": type]) { _, new in new }
            }
            result = ["entries": entries, "total": filtered.count]
        case .mode:
            guard ["rule", "global", "direct"].contains(command.mode) else { throw TunnelError.control }
            _ = try await api("/configs", method: "PATCH", body: ["mode": command.mode]); result = ["ok": true]
        case .select:
            _ = try await api("/proxies/" + encoded(command.group), method: "PUT", body: ["name": command.node])
            try await closeConnections(via: command.group)
            result = ["ok": true]
        case .close:
            _ = try await api("/connections/" + encoded(command.connectionID), method: "DELETE"); result = ["ok": true]
        case .closeAll:
            _ = try await api("/connections", method: "DELETE"); result = ["ok": true]
        case .probe: result = try await probe(command)
        case .probes:
            guard let value = probes[command.scope + "/" + command.node] else { throw TunnelError.control }
            result = value
        }
        guard !stopped else { throw CancellationError() }
        let data = try JSONSerialization.data(withJSONObject: result)
        guard data.count <= 65536 else { throw TunnelError.control }
        return data
    }

    private func closeConnections(via group: String) async throws {
        let current = try await api("/connections")
        for connection in current["connections"] as? [[String: Any]] ?? [] where (connection["chains"] as? [String])?.contains(group) == true {
            if let id = connection["id"] as? String { _ = try await api("/connections/" + encoded(id), method: "DELETE") }
        }
    }

    // 串行执行：两次采样交错会让旧计数覆盖新计数，下一轮再把同一段流量记一遍
    private func sample() async throws -> ([String: Any], [String: Any]) {
        while sampling { try await Task.sleep(for: .milliseconds(20)) }
        sampling = true
        defer { sampling = false }
        do {
            let connections = try await api("/connections")
            let proxyResponse = try await api("/proxies")
            let providerResponse = try await api("/providers/proxies")
            guard !stopped else { throw CancellationError() }
            var next: [String: [String: Any]] = [:]
            for value in connections["connections"] as? [[String: Any]] ?? [] {
                guard let id = value["id"] as? String, let metadata = value["metadata"] as? [String: Any] else { continue }
                func endpoint(_ address: String, _ port: String) -> String {
                    let host = metadata[address] as? String ?? ""
                    let number = metadata[port].map { String(describing: $0) } ?? ""
                    return host.contains(":") ? "[\(host)]:\(number)" : "\(host):\(number)"
                }
                let host = (metadata["host"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let ip = (metadata["destinationIP"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let port = metadata["destinationPort"].map { String(describing: $0) } ?? ""
                let target = host.isEmpty ? (ip.isEmpty ? "—" : ip) : host
                let process = (metadata["process"] as? String ?? "").isEmpty
                    ? (metadata["processPath"] as? String ?? "").split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
                    : metadata["process"] as? String ?? ""
                next[id] = ["id": id, "network": metadata["network"] as? String ?? "", "host": metadata["host"] as? String ?? "",
                            "source": endpoint("sourceIP", "sourcePort"), "destination": port.isEmpty ? target : target + ":" + port, "ip": ip, "port": port,
                            "remoteDestination": (metadata["remoteDestination"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                            "upload": value["upload"] as? Int64 ?? 0, "download": value["download"] as? Int64 ?? 0,
                            "start": value["start"] as? String ?? "", "chains": value["chains"] as? [String] ?? [],
                            "rule": (value["rule"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                            "rulePayload": (value["rulePayload"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                            "process": process, "processPath": (metadata["processPath"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                            "inbound": metadata["type"] as? String ?? ""]
            }
            for (id, var value) in active where next[id] == nil {
                value["closedAt"] = ISO8601DateFormatter().string(from: .now); closed.append(value)
            }
            accumulate(next, connections: connections["connections"] as? [[String: Any]] ?? [], proxies: proxyResponse["proxies"] as? [String: [String: Any]] ?? [:],
                       providers: providerResponse["providers"] as? [String: [String: Any]] ?? [:])
            active = next
            if closed.count > 1000 { closed.removeFirst(closed.count - 1000) }
            return (proxyResponse, providerResponse)
        }
    }

    private func snapshot(_ command: TunnelCommand) async throws -> [String: Any] {
        guard ["", "all", "active", "closed"].contains(command.scope) else { throw TunnelError.control }
        let (proxyResponse, providerResponse) = try await sample()
        let configuration = try await api("/configs")
        let query = command.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = active.values.sorted {
            let a = $0["start"] as! String, b = $1["start"] as! String
            return a == b ? ($0["id"] as! String) < ($1["id"] as! String) : a > b
        }
        let filtered = (current + closed.reversed()).filter { value in
            let text = ["destination", "ip", "process", "rule", "network", "inbound"].compactMap { value[$0] as? String } + (value["chains"] as? [String] ?? [])
            return query.isEmpty || text.joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
        let activeCount = filtered.filter { $0["closedAt"] == nil }.count
        let rows = filtered.filter {
            command.scope == "all" || (command.scope == "closed" ? $0["closedAt"] != nil : $0["closedAt"] == nil)
        }
        var groups: [[String: Any]] = [], selections: [String: String] = [:], delays: [String: Int] = [:]
        var proxies = proxyResponse["proxies"] as? [String: [String: Any]] ?? [:]
        for provider in (providerResponse["providers"] as? [String: [String: Any]] ?? [:]).values {
            for proxy in provider["proxies"] as? [[String: Any]] ?? [] {
                if let name = proxy["name"] as? String { proxies[name] = proxy }
            }
        }
        for (name, proxy) in proxies {
            if let delay = (proxy["history"] as? [[String: Any]])?.last?["delay"] as? Int, delay > 0 { delays[name] = delay }
        }
        for (name, value) in proxyResponse["proxies"] as? [String: [String: Any]] ?? [:] {
            guard name != "ecy-speed", value["hidden"] as? Bool != true, let members = value["all"] as? [String] else { continue }
            let type = (value["type"] as? String ?? "").lowercased()
            groups.append(["id": name, "members": members.filter { $0 != "ecy-speed" }, "type": type == "selector" ? "select" : type])
            selections[name] = value["now"] as? String
        }
        let drained = rank; rank = ["groups": [:], "hosts": [:]]
        return ["upload": rates.0, "download": rates.1, "uploadTotal": proxyTotals.0, "downloadTotal": proxyTotals.1, "rank": drained,
                "connections": Array(rows.dropFirst((command.page - 1) * 25).prefix(25)), "total": rows.count, "page": command.page,
                "selections": selections, "groups": groups.sorted { ($0["id"] as! String) < ($1["id"] as! String) }, "delays": delays,
                "memory": memory, "active": activeCount, "closed": filtered.count - activeCount, "mode": configuration["mode"] as? String ?? "rule"]
    }

    // 与 Kernel/control.go 的 accumulate 及 connection_controller.dart 的 _accumulateProxyTraffic 同口径：
    // 只计链路落地出站会出网的连接增量；排行增量取走即清空，交给客户端按账户落盘。
    private func accumulate(_ next: [String: [String: Any]], connections: [[String: Any]], proxies: [String: [String: Any]], providers: [String: [String: Any]]) {
        var types = proxies.mapValues { ($0["type"] as? String ?? "").lowercased() }
        for provider in providers.values {
            for proxy in provider["proxies"] as? [[String: Any]] ?? [] {
                if let name = proxy["name"] as? String, types[name] == nil { types[name] = (proxy["type"] as? String ?? "").lowercased() }
            }
        }
        let groups = Set(proxies.filter { $0.value["all"] != nil }.keys)
        let hosts = Dictionary(connections.compactMap { value -> (String, String)? in
            guard let id = value["id"] as? String, let metadata = value["metadata"] as? [String: Any] else { return nil }
            let host = (metadata["host"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            return (id, host.isEmpty ? (metadata["destinationIP"] as? String ?? "").trimmingCharacters(in: .whitespaces) : host)
        }, uniquingKeysWith: { first, _ in first })
        let first = !trafficSampled
        var up: Int64 = 0, down: Int64 = 0
        for (id, value) in next {
            let chains = value["chains"] as? [String] ?? []
            guard let leaf = chains.first, !groups.contains(leaf), let type = types[leaf], !type.isEmpty,
                  !["direct", "reject", "rejectdrop", "compatible", "pass", "dns"].contains(type) else { continue }
            let du = max(0, (value["upload"] as? Int64 ?? 0) - (active[id]?["upload"] as? Int64 ?? 0))
            let dd = max(0, (value["download"] as? Int64 ?? 0) - (active[id]?["download"] as? Int64 ?? 0))
            up += du; down += dd
            guard !first, du + dd > 0 else { continue }
            for hop in chains where groups.contains(hop) { add("groups", hop, du + dd) }
            if let host = hosts[id], !servers.contains(host.lowercased()) { add("hosts", host, du + dd) }
        }
        let elapsed = sampled.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        if !first, seconds > 0 { rates = (Int64(Double(up) / seconds), Int64(Double(down) / seconds)) }
        proxyTotals = (proxyTotals.0 + up, proxyTotals.1 + down); sampled = .now; trafficSampled = true
    }

    private func add(_ kind: String, _ key: String, _ bytes: Int64) {
        guard !key.isEmpty, rank[kind]![key] != nil || rank[kind]!.count < 256 else { return }
        rank[kind]![key, default: 0] += bytes
    }

    private func probe(_ command: TunnelCommand) async throws -> [String: Any] {
        guard ["delay", "speed", "reselect"].contains(command.scope) else { throw TunnelError.control }
        let name = try encoded(command.node)
        var delay = 0, speed: Int64 = 0
        let query = [URLQueryItem(name: "url", value: "https://cp.cloudflare.com/generate_204"), URLQueryItem(name: "timeout", value: "5000")]
        if command.scope == "speed" {
            guard speedTask == nil, NodeProbeState.isOfficial(command.node) else { throw TunnelError.control }
            let port = probePort, credential = speedCredential
            let task = Task {
                _ = try await api("/proxies/ecy-speed", method: "PUT", body: ["name": command.node])
                return try await MacSpeedProbe.measure(port: port, credential: credential)
            }
            speedTask = task
            defer { speedTask = nil }
            let measured: Result<Int64, any Error>
            do { measured = .success(try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })) }
            catch { measured = .failure(error) }
            try? await closeConnections(via: "ecy-speed")
            speed = try measured.get()
        } else if command.scope == "reselect" {
            _ = try await api("/group/" + name + "/delay", query: query, timeout: 8)
        } else {
            let providers = try await api("/providers/proxies")
            let nodes = (providers["providers"] as? [String: [String: Any]])?["ecy-panel-nodes"]?["proxies"] as? [[String: Any]] ?? []
            let path = nodes.contains(where: { $0["name"] as? String == command.node }) ? "/providers/proxies/ecy-panel-nodes/\(name)/healthcheck" : "/proxies/\(name)/delay"
            let result = try await api(path, query: query, timeout: 8)
            guard let value = result["delay"] as? Int, value > 0 else { throw TunnelError.control }
            delay = value
        }
        let result: [String: Any] = ["running": false, "failed": false, "delay": delay, "speed": speed]
        probes[command.scope + "/" + command.node] = result
        return result
    }
}

struct MacLogRedactor {
    let secrets: [String]
    init(configuration: [String: Any]) {
        var values = Set<String>()
        func walk(_ value: Any, key: String = "") {
            if let string = value as? String, ["password", "passwd", "token", "secret", "uuid", "private-key", "client-fingerprint"].contains(key.lowercased()), !string.isEmpty { values.insert(string) }
            else if let object = value as? [String: Any] { for (key, value) in object { walk(value, key: key) } }
            else if let array = value as? [Any] { for item in array { walk(item) } }
        }
        walk(configuration)
        secrets = values.sorted { $0.count > $1.count }
    }
    func redact(_ text: String) -> String {
        var result = text
        for secret in secrets { result = result.replacingOccurrences(of: secret, with: "***") }
        result = result.replacingOccurrences(of: #"(?i)(password|passwd|token|secret|authorization|api[_-]?key)[=: ]+(?:(?:Bearer|Basic)\s+)?[^\s,;]+"#, with: "$1=***", options: .regularExpression)
        let pattern = try! NSRegularExpression(pattern: #"(?i)[a-z][a-z0-9+.-]*://[^\s<>"']+"#)
        for match in pattern.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            var url = URLComponents(string: String(result[range]))
            url?.user = nil; url?.password = nil; url?.query = nil; url?.fragment = nil
            result.replaceSubrange(range, with: url?.string ?? L10n.t("[链接]"))
        }
        return String(result.prefix(4096))
    }
}
#endif
