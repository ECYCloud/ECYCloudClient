import Foundation
import CryptoKit

public struct ProfileOptions: Sendable {
    public enum Input: Sendable { case proxy, packetFlow }
    public var input: Input = .proxy
    public var mixedPort: Int
    public var controllerPort: Int
    public var secret: String
    public var mode = "rule"
    public var logLevel = "warning"
    public var allowLAN = false
    public var ipv6 = false
    public var tunEnabled = true
    public var strictRoute = true
    public var tunStack = "mixed"
    public var tunDevice = "ECYCloud"
    public var mtu = 9000
    public var ipv4Address = "172.19.0.1/30"
    public var ipv6Address = "fdfe:dcba:9876::1/126"
    public var autoDetectInterface = true
    public var excludedRoutes: [String] = []
    public var remoteDNS = "https://1.1.1.1/dns-query"
    public var localDNS = "223.5.5.5"

    public static var packetFlow: ProfileOptions {
        var result = ProfileOptions(mixedPort: 0, controllerPort: 0, secret: "")
        result.input = .packetFlow
        result.logLevel = "silent"
        result.mtu = 1500
        return result
    }

    public init(mixedPort: Int, controllerPort: Int, secret: String) {
        self.mixedPort = mixedPort; self.controllerPort = controllerPort; self.secret = secret
    }
}

public struct AssembledProfile: Sendable {
    public let data: Data
    public let validationData: Data
    public let remoteProviderCount: Int
    public let usesFakeIP: Bool
}

public struct ProfileValidationError: Error, LocalizedError, Sendable {
    public let issues: [String]
    public var errorDescription: String? { L10n.t("面板配置不规范\n") + issues.joined(separator: "\n") }
}

public enum ProfileAssembler {
    private static let builtins: Set<String> = ["direct", "reject", "reject-drop", "reject-tinygif", "pass", "compatible", "dns"]

    public static func assemble(_ remote: Data, options: ProfileOptions, selections: [String: String] = [:]) throws -> AssembledProfile {
        guard remote.count <= URLSessionTransport.maximumResponseBytes else { throw ClientError.responseTooLarge }
        guard var config = try JSONSerialization.jsonObject(with: remote) as? [String: Any] else { throw ClientError.invalidResponse }
        let issues = inspect(config)
        guard issues.isEmpty else { throw ProfileValidationError(issues: issues) }
        let probePort = options.mixedPort < 65535 ? options.mixedPort + 1 : options.mixedPort - 1
        let packetFlow = options.input == .packetFlow
        let validProxy = (1024...65535).contains(options.mixedPort) && (1024...65535).contains(options.controllerPort)
            && options.controllerPort != options.mixedPort && options.controllerPort != probePort
            && options.secret.utf8.count >= 32 && options.secret.utf8.count <= 4096
            && options.secret.utf8.allSatisfy { (33...126).contains($0) }
        guard packetFlow || validProxy,
              ["rule", "global", "direct"].contains(options.mode),
              ["silent", "error", "warning", "info", "debug"].contains(options.logLevel),
              options.excludedRoutes.count <= 256, options.excludedRoutes.allSatisfy({ NetworkRoute($0) != nil }),
              ["system", "mixed", "gvisor", "mips"].contains(options.tunStack), (1280...65535).contains(options.mtu) else {
            throw ClientError.configuration
        }
        if config["unified-delay"] == nil { config["unified-delay"] = true }
        if config["tcp-concurrent"] == nil { config["tcp-concurrent"] = true }
        if config["dns"] == nil {
            config["dns"] = ["enable": true, "enhanced-mode": "fake-ip", "fake-ip-range": "198.18.0.1/16",
                             "default-nameserver": [options.localDNS], "nameserver": [options.remoteDNS], "proxy-server-nameserver": [options.localDNS]]
        }
        config["mixed-port"] = packetFlow ? 0 : options.mixedPort
        for key in ["port", "socks-port", "redir-port", "tproxy-port"] { config[key] = 0 }
        config["mode"] = options.mode
        config["log-level"] = packetFlow ? "silent" : options.logLevel
        config["allow-lan"] = !packetFlow && options.allowLAN
        config["bind-address"] = options.allowLAN ? "*" : "127.0.0.1"
        config["authentication"] = [String]()
        config["listeners"] = [[String: Any]]()
        config["tunnels"] = [[String: Any]]()
        for key in ["ss-config", "vmess-config", "external-controller-unix", "external-controller-pipe", "external-controller-tls", "external-doh-server", "external-ui", "external-ui-url"] { config[key] = "" }
        config["tuic-server"] = ["enable": false]
        config["iptables"] = ["enable": false]
        config["external-controller"] = packetFlow ? "" : "127.0.0.1:\(options.controllerPort)"
        config["secret"] = packetFlow ? "" : options.secret
        config["external-controller-cors"] = ["allow-origins": ["http://127.0.0.1"], "allow-private-network": false]
        config["ipv6"] = options.ipv6
        config["profile"] = ["store-selected": !packetFlow, "store-fake-ip": !packetFlow]
        var excluded = NetworkSegments.routeDefaults
        for route in options.excludedRoutes where !excluded.contains(route) { excluded.append(route) }
        config["tun"] = ["enable": !packetFlow && options.tunEnabled, "stack": options.tunStack, "device": options.tunDevice,
                         "auto-route": !packetFlow, "auto-detect-interface": options.autoDetectInterface, "strict-route": options.strictRoute,
                         "mtu": options.mtu, "dns-hijack": packetFlow ? [String]() : ["any:53"], "inet4-address": [options.ipv4Address],
                         "inet6-address": [options.ipv6Address], "route-exclude-address": excluded]
        if var ntp = config["ntp"] as? [String: Any], ntp["write-to-system"] != nil { ntp["write-to-system"] = false; config["ntp"] = ntp }
        var dns = config["dns"] as! [String: Any]
        dns["listen"] = ""; dns["ipv6"] = options.ipv6; config["dns"] = dns
        var groups = config["proxy-groups"] as! [[String: Any]]
        let providers = config["proxy-providers"] as? [String: [String: Any]] ?? [:]
        var appliedSelection = false
        for index in groups.indices where groups[index]["type"] as? String == "select" {
            guard let name = groups[index]["name"] as? String, let wanted = selections[name] else { continue }
            var members = groups[index]["proxies"] as? [String] ?? []
            for provider in groups[index]["use"] as? [String] ?? [] {
                members += (providers[provider]?["payload"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.filter { $0 != "ecy-panel-empty" }
            }
            if members.contains(wanted) { groups[index]["default-selected"] = wanted; appliedSelection = true }
        }
        if appliedSelection { config["profile"] = ["store-selected": false, "store-fake-ip": !packetFlow] }
        if !packetFlow {
        let proxies = config["proxies"] as? [[String: Any]] ?? []
        var probe: [String: Any] = ["name": "ecy-speed", "type": "select", "hidden": true, "proxies": ["DIRECT"] + proxies.compactMap { $0["name"] as? String }]
        if providers["ecy-panel-nodes"] != nil { probe["use"] = ["ecy-panel-nodes"] }
        groups.append(probe); config["proxy-groups"] = groups
        let digest = SHA256.hash(data: Data("ecy-speed\0\(options.secret)".utf8)).map { String(format: "%02x", $0) }.joined()
        config["listeners"] = [["name": "ecy-speed", "type": "mixed", "listen": "127.0.0.1", "port": probePort,
                                "udp": false, "users": [["username": "ecy-speed", "password": digest]], "proxy": "ecy-speed"]]
        } else {
            config["proxy-groups"] = groups
            config["find-process-mode"] = "off"
            config["interface-name"] = ""
            config["routing-mark"] = 0
            config["geo-auto-update"] = false
            config["proxy-providers"] = providers.mapValues { value in
                var next = value
                if value["type"] as? String == "file", value["payload"] is [Any] { next["type"] = "inline" }
                return next
            }
        }
        var validation = config
        if config["proxy-providers"] != nil {
            validation["proxy-providers"] = providers.mapValues { value in
                var next = value
                if value["type"] as? String == "file", value["payload"] is [Any] { next["type"] = "inline" }
                return next
            }
        }
        var profile = config["profile"] as! [String: Bool]
        profile["store-fake-ip"] = false; validation["profile"] = profile
        let count = ["rule-providers", "proxy-providers"].reduce(0) { result, key in
            result + (config[key] as? [String: [String: Any]] ?? [:]).values.filter { $0["type"] as? String == "http" }.count
        }
        return try AssembledProfile(data: JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes]),
                                    validationData: JSONSerialization.data(withJSONObject: validation, options: [.sortedKeys, .withoutEscapingSlashes]),
                                    remoteProviderCount: count, usesFakeIP: dns["enable"] as? Bool == true && (dns["enhanced-mode"] as? String)?.lowercased() == "fake-ip")
    }

    static func safeProviderPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), path.range(of: #"[\\:\x00-\x1f\x7f]"#, options: .regularExpression) == nil else { return false }
        let parts = path.components(separatedBy: "/").filter { $0 != "." }
        guard let first = parts.first, !parts.contains(where: {
            $0.isEmpty || $0 == ".." || $0.hasSuffix(".") || $0.hasSuffix(" ") || $0.range(of: #"^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
        }) else { return false }
        return first.range(of: #"^(config\.json|config\.check\.json|cache\.db|proxy-snapshot\.json|geoip\.metadb|geosite\.dat|geoip\.dat|asn\.mmdb|bundlemrs\.7z)(\.|$)|^\.validate-"#, options: [.regularExpression, .caseInsensitive]) == nil
    }

    private static func inspect(_ config: [String: Any]) -> [String] {
        var issues: [String] = []
        var names = Set<String>()
        func issue(_ value: String) { if issues.count < 20 { issues.append(value) } }
        let providers = config["proxy-providers"] as? [String: [String: Any]] ?? [:]
        let nodes = providers["ecy-panel-nodes"]?["payload"] ?? config["proxies"]
        if let nodes = nodes as? [[String: Any]], !nodes.isEmpty {
            for (index, node) in nodes.enumerated() {
                guard let name = node["name"] as? String, !name.isEmpty, let type = node["type"] as? String, !type.isEmpty,
                      names.insert(name).inserted else { issue(L10n.t("第 {0} 个节点名称或类型无效，或名称重复", [String(describing: index + 1)])); continue }
            }
        } else { issue(L10n.t("面板未下发有效节点列表")) }
        var providerNames: [String: Set<String>] = [:]
        for section in ["proxy-providers", "rule-providers"] {
            guard let raw = config[section] else { providerNames[section] = []; continue }
            guard let map = raw as? [String: [String: Any]] else { issue(L10n.t("{0} 格式不正确", [String(describing: section)])); continue }
            providerNames[section] = Set(map.keys)
            for (name, value) in map {
                guard let type = value["type"] as? String, !type.isEmpty else { issue(L10n.t("{0} 存在缺少类型的条目", [String(describing: section)])); continue }
                if section == "rule-providers" && (value["path"] as? String)?.isEmpty != false { issue(L10n.t("规则集缺少保存路径")) }
                if let path = value["path"], !(path is String && safeProviderPath(path as! String)) { issue(L10n.t("规则或节点保存路径必须位于运行目录内，且不能覆盖客户端文件")) }
                if section == "proxy-providers", name.hasPrefix("ecy-panel-") {
                    let validName = name == "ecy-panel-nodes" || name.range(of: #"^ecy-panel-[a-f0-9]{64}$"#, options: .regularExpression) != nil
                    if !validName || type != "file" || value["path"] as? String != "\(name).json" || (value["payload"] as? [Any])?.isEmpty != false { issue(L10n.t("面板节点提供器不完整")) }
                }
                if type == "http", (value["url"] as? String)?.isEmpty != false { issue(L10n.t("在线规则或节点提供器缺少地址")) }
                if (value["format"] as? String)?.lowercased() == "mrs", (value["behavior"] as? String)?.lowercased() == "classical" { issue(L10n.t("逐条规则不能使用 mrs 格式")) }
            }
        }
        if let groups = config["proxy-groups"] as? [[String: Any]], !groups.isEmpty {
            for (index, group) in groups.enumerated() {
                guard let name = group["name"] as? String, !name.isEmpty, names.insert(name).inserted,
                      let type = group["type"] as? String, !type.isEmpty else { issue(L10n.t("第 {0} 个策略组名称或类型无效，或名称重复", [String(describing: index + 1)])); continue }
            }
            for group in groups {
                let members = group["proxies"] as? [String] ?? []
                let uses = group["use"] as? [String] ?? []
                if members.isEmpty && uses.isEmpty { issue(L10n.t("策略组没有有效成员")) }
                if members.contains(where: { !names.contains($0) && !builtins.contains($0.lowercased()) }) { issue(L10n.t("策略组引用了不存在的成员")) }
                if uses.contains(where: { !(providerNames["proxy-providers"] ?? []).contains($0) }) { issue(L10n.t("策略组引用了不存在的节点提供器")) }
            }
        } else { issue(L10n.t("面板配置缺少有效策略组")) }
        if names.contains("ecy-speed") { issue(L10n.t("面板配置占用了客户端测速名称")) }
        if let rules = config["rules"] as? [String], !rules.isEmpty {
            var hasMatch = false
            for line in rules {
                let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty || line.hasPrefix("#") { continue }
                let parts = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard let type = parts.first?.uppercased() else { issue(L10n.t("分流规则格式不正确")); continue }
                if ["MATCH", "FINAL"].contains(type) { hasMatch = true }
                if type == "RULE-SET", parts.count < 2 || !(providerNames["rule-providers"] ?? []).contains(parts[1]) { issue(L10n.t("分流规则引用了不存在的规则集")) }
                if ["AND", "OR", "NOT", "SUB-RULE"].contains(type) { continue }
                guard parts.count >= 2 else { issue(L10n.t("分流规则缺少目标")); continue }
                let target = parts.last!.lowercased() == "no-resolve" ? parts[parts.count - 2] : parts.last!
                if !names.contains(target) && !builtins.contains(target.lowercased()) { issue(L10n.t("分流规则指向了不存在的策略")) }
            }
            if !hasMatch { issue(L10n.t("分流规则缺少最后一条兜底规则")) }
        } else { issue(L10n.t("面板配置缺少有效分流规则")) }
        if let dns = config["dns"], !(dns is [String: Any]) { issue(L10n.t("DNS 设置格式不正确")) }
        return issues
    }
}

// 配置中的 mihomo 字段保持原样，包括带连字符和下划线的键。
indirect enum ProfileValue: Codable {
    case object([String: ProfileValue]), array([ProfileValue]), string(String), integer(Int64), number(Double), bool(Bool), null
    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let next = try? value.decode(Bool.self) { self = .bool(next) }
        else if let next = try? value.decode(Int64.self) { self = .integer(next) }
        else if let next = try? value.decode(Double.self) { self = .number(next) }
        else if let next = try? value.decode(String.self) { self = .string(next) }
        else if let next = try? value.decode([ProfileValue].self) { self = .array(next) }
        else { self = .object(try value.decode([String: ProfileValue].self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let next): try value.encode(next)
        case .array(let next): try value.encode(next)
        case .string(let next): try value.encode(next)
        case .integer(let next): try value.encode(next)
        case .number(let next): try value.encode(next)
        case .bool(let next): try value.encode(next)
        case .null: try value.encodeNil()
        }
    }
}
