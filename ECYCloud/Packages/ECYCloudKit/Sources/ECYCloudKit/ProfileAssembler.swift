import Foundation
import CryptoKit

extension TunnelLease {
    // 对应 profile_assembler.dart 的 canUpdateNodes：除节点文件内容与各组默认选中项外完全一致，才能只更新节点
    func differsOnlyInNodes(from running: TunnelLease) -> Bool {
        func signature(_ data: Data) -> Data? {
            guard var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var providers = config["proxy-providers"] as? [String: [String: Any]], providers["ecy-panel-nodes"] != nil else { return nil }
            for name in providers.keys where name.hasPrefix("ecy-panel-") { providers[name]?["payload"] = nil }
            config["proxy-providers"] = providers
            config["proxy-groups"] = (config["proxy-groups"] as? [[String: Any]])?.map { $0.filter { $0.key != "default-selected" } }
            // 默认选中项会连带改 store-selected；只更新节点时内核不重读这一项
            config["profile"] = (config["profile"] as? [String: Any])?.filter { $0.key != "store-selected" }
            // 运行中切换模式只改内核状态，运行配置里仍是启动时的值；重读节点文件不涉及它
            config["mode"] = nil
            return try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        }
        guard owner == running.owner, cacheKey == running.cacheKey, let before = signature(running.configuration) else { return false }
        return before == signature(configuration)
    }
}

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
    public var proxyChina = false
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

    // 对应 profile_inspector.dart 的 ensureValid：拉取节点时与装配时共用同一套结构检查
    static func validate(_ remote: Data) throws -> [String: Any] {
        guard remote.count <= URLSessionTransport.maximumResponseBytes else { throw ClientError.responseTooLarge }
        guard let config = try JSONSerialization.jsonObject(with: remote) as? [String: Any] else { throw ClientError.invalidResponse }
        let issues = inspect(config)
        guard issues.isEmpty else { throw ProfileValidationError(issues: issues) }
        return config
    }

    public static func assemble(_ remote: Data, options: ProfileOptions, selections: [String: String] = [:],
                                pinned: [String] = [], probe: [String] = []) throws -> AssembledProfile {
        var config = try validate(remote)
        // 校验、落盘、启动与热载用的都是裁剪后的同一份：完整目录交给内核，手机与特权侧的上限都装不下
        config = NodeWorkingSet.restrict(config, loaded: NodeWorkingSet.select(config, pinned: pinned + selections.values), probe: probe)
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
        var tun: [String: Any] = ["enable": !packetFlow && options.tunEnabled, "stack": options.tunStack, "device": options.tunDevice,
                                  "auto-route": !packetFlow, "auto-detect-interface": options.autoDetectInterface, "strict-route": options.strictRoute,
                                  "mtu": options.mtu, "dns-hijack": packetFlow ? [String]() : ["any:53"], "inet4-address": [options.ipv4Address],
                                  "inet6-address": [options.ipv6Address], "route-exclude-address": excluded]
        #if os(macOS)
        // 内核在 darwin 上 dns-mode 留空即 disabled，系统解析直接发给局域网 DNS、不经内核；hijack 把 TUN 地址登记为系统首选解析器，内核退出即自动撤销
        if !packetFlow { tun["dns-mode"] = "hijack" }
        #endif
        config["tun"] = tun
        if var ntp = config["ntp"] as? [String: Any], ntp["write-to-system"] != nil { ntp["write-to-system"] = false; config["ntp"] = ntp }
        var dns = config["dns"] as! [String: Any]
        dns["listen"] = ""; dns["ipv6"] = options.ipv6; config["dns"] = dns
        if options.proxyChina, let rules = config["rules"] as? [Any] { config["rules"] = proxyChinaRules(rules) }
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
        if providers[NodeWorkingSet.nodesProvider] != nil { probe["use"] = [NodeWorkingSet.nodesProvider, NodeWorkingSet.probeProvider] }
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
            // 面板节点文件保持 file：内核只有按文件重读才能不重启就换节点（Kernel/engine.go 的 UpdateNodes），文件还没写出时它用 payload
            config["proxy-providers"] = Dictionary(uniqueKeysWithValues: providers.map { name, value in
                var next = value
                if !name.hasPrefix("ecy-panel-"), value["type"] as? String == "file", value["payload"] is [Any] { next["type"] = "inline" }
                return (name, next)
            })
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

    private static func proxyChinaRules(_ rules: [Any]) -> [Any] {
        guard let target = rules.lazy.map({ "\($0)".components(separatedBy: ",") })
            .first(where: { $0.count >= 2 && $0[0].trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "MATCH" })?[1]
            .trimmingCharacters(in: .whitespacesAndNewlines), target.uppercased() != "DIRECT" else { return rules }
        return rules.map { rule in
            guard let rule = rule as? String else { return rule }
            var fields = rule.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard fields.count >= 3, ["GEOIP", "GEOSITE"].contains(fields[0].uppercased()), fields[1].lowercased() == "cn",
                  fields[2].uppercased() == "DIRECT" else { return rule }
            fields[2] = target
            return fields.joined(separator: ",")
        }
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
        // 组网类出站会让内核加入外部 P2P 网络、开监听口或充当出口节点，等于替用户开了看不见的入站
        for node in ([config["proxies"]] + providers.values.map { $0["payload"] }).compactMap({ $0 as? [[String: Any]] }).joined() {
            let type = (node["type"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            if ["easytier", "tailscale", "zerotier"].contains(type) {
                issue(L10n.t("节点「{0}」是组网类型（{1}），会让内核加入外部网络，客户端不支持", [node["name"] as? String ?? "", type]))
            }
        }
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
                // 内核取 provider 字段名不分大小写（mihomo common/structure）：PATH、URL 这类变体一样会被拿去落盘、下载，各个变体逐一检查
                let paths = value.filter { $0.key.lowercased() == "path" }.map(\.value)
                let urls = value.filter { $0.key.lowercased() == "url" }.map(\.value)
                if section == "rule-providers" && !paths.contains(where: { ($0 as? String)?.isEmpty == false }) { issue(L10n.t("规则集缺少保存路径")) }
                if !paths.allSatisfy({ ($0 as? String).map(safeProviderPath) ?? false }) { issue(L10n.t("规则或节点保存路径必须位于运行目录内，且不能覆盖客户端文件")) }
                if section == "proxy-providers", name.hasPrefix("ecy-panel-") {
                    let validName = name == "ecy-panel-nodes" || name.range(of: #"^ecy-panel-[a-f0-9]{64}$"#, options: .regularExpression) != nil
                    // 只带成员名单的节点文件，名单里的节点都要在 ecy-panel-nodes 里
                    let members = value["members"] as? [String]
                    let complete = value["members"] == nil ? (value["payload"] as? [Any])?.isEmpty == false
                        : value["payload"] == nil && members?.isEmpty == false && members!.allSatisfy(names.contains)
                    if !validName || type != "file" || value["path"] as? String != "\(name).json" || !complete { issue(L10n.t("面板节点提供器不完整")) }
                }
                if type == "http", !urls.contains(where: { ($0 as? String)?.isEmpty == false }) { issue(L10n.t("在线规则或节点提供器缺少地址")) }
                else if !urls.allSatisfy(httpsURL) { issue(L10n.t("规则或节点提供器的下载地址必须使用 https")) }
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
        for (key, url) in config["geox-url"] as? [String: Any] ?? [:] where !httpsURL(url) { issue(L10n.t("geox-url「{0}」必须使用 https", [key])) }
        return issues
    }

    // 明文下载会被链路上替换规则集、节点订阅与地理数据库：只检查不改写，没有地址的本地 provider 不受影响。
    // 内核取 provider 字段时名字不分大小写（mihomo common/structure），URL、Url 一样会被拿去下载
    private static func httpsURL(_ value: Any) -> Bool {
        if value is NSNull { return true }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return text.isEmpty || text.hasPrefix("https://")
    }
}
