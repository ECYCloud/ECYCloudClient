import Foundation
import Security

public struct PanelEndpoints: Codable, Equatable, Sendable {
    public let site: URL
    public let config: URL

    public init(site: String, config: String) throws {
        self.site = try Self.origin(site)
        self.config = try Self.origin(config)
    }

    public static func bundled(in bundle: Bundle = .main) throws -> Self {
        struct Bootstrap: Decodable {
            let panelUrl: String
            let subUrl: String
        }
        guard let url = bundle.url(forResource: "panel", withExtension: "json") else {
            throw ClientError.configuration
        }
        let data = try JSONDecoder().decode(Bootstrap.self, from: Data(contentsOf: url))
        return try Self(site: data.panelUrl, config: data.subUrl)
    }

    public func updating(site: String, config: String) throws -> Self {
        try Self(site: site, config: config)
    }

    static func origin(_ raw: String) throws -> URL {
        guard var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) != false else {
            throw ClientError.configuration
        }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        guard let url = parts.url else { throw ClientError.configuration }
        return url
    }
}

public enum ClientError: Error, LocalizedError, Equatable, Sendable {
    case configuration
    case invalidResponse
    case responseTooLarge
    case network
    case networkFailure(Int)
    case unreachable(Int)
    case keychain(Int32)
    case server(status: Int, code: Int, message: String, retryAfter: Int?)
    case passwordChanged(message: String)

    public var needsTwoFactor: Bool {
        if case .server(_, 2, _, _) = self { return true }
        return false
    }

    public var unauthorized: Bool {
        if case .server(401, let code, _, _) = self { return code != 2 }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .configuration: L10n.t("站点配置无效，请检查构建使用的 panel.json。")
        case .invalidResponse: L10n.t("服务器返回的数据格式不正确，请稍后重试。")
        case .responseTooLarge: L10n.t("服务器响应超过大小限制，已停止接收。")
        case .network: L10n.t("无法连接面板，请检查网络后重试。")
        case .networkFailure(let code):
            switch URLError.Code(rawValue: code) {
            case .cannotFindHost, .dnsLookupFailed:
                L10n.t("无法解析站点域名（网络错误 {0}），请稍后重试。", [String(describing: code)])
            case .timedOut:
                L10n.t("连接面板超时（网络错误 {0}），请稍后重试。", [String(describing: code)])
            case .notConnectedToInternet, .networkConnectionLost:
                L10n.t("网络连接已中断（网络错误 {0}），恢复网络后请重试。", [String(describing: code)])
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                L10n.t("无法验证面板的安全连接（网络错误 {0}）。", [String(describing: code)])
            default:
                L10n.t("无法连接面板（网络错误 {0}），请稍后重试。", [String(describing: code)])
            }
        case .unreachable(let code):
            L10n.t("{0}（已自动重试 {1} 次仍连不上，请关闭软件后重新打开）", [ClientError.networkFailure(code).errorDescription ?? "", "3"])
        case .keychain(let status):
            switch status {
            case errSecMissingEntitlement:
                L10n.t("应用缺少钥匙串访问权限（错误 {0}）。", [String(describing: status)])
            case errSecInteractionNotAllowed:
                L10n.t("系统当前不允许访问钥匙串，请确认设备已解锁后重试（错误 {0}）。", [String(describing: status)])
            default:
                L10n.t("无法安全保存或读取登录信息（钥匙串错误 {0}）。", [String(describing: status)])
            }
        case .server(_, _, let message, let retry):
            retry.map { L10n.t("{0}（请在 {1} 秒后重试）", [String(describing: message), String(describing: $0)]) } ?? message
        case .passwordChanged(let message): message
        }
    }
}

public struct AuthOptions: Decodable, Sendable {
    public let regMode: String
    public let enableChangeEmail: Bool
    public let enableKill: Bool
    public let enablePasswordChangeResetSubscription: Bool
    public var registrationClosed: Bool { regMode == "close" }
    public var inviteRequired: Bool { regMode == "invite" }
    public let emailVerify: Bool
    public let apiOrigin: String
    public let siteOrigin: String
}

public struct AccountStatus: Decodable, Sendable {
    public let enable: Int
    public let email: String
    public let submitAccountDeletionTime: String?
    public let deletionTime: String?
    public let banReason: String?
    public let banTimeText: String?
    public let banStartTime: String?
    public let banEndTime: String?
    public let banPermanent: Bool?
    public let ticketEnabled: Bool?
    public let supportEmail: String

    public var isNormal: Bool { enable == 1 }
    public var title: String { enable == -1 ? L10n.t("账号待删除") : L10n.t("账号受限") }
}

public struct UserProfile: Decodable, Sendable {
    public struct Plan: Decodable, Sendable {
        public let name: String
        public let remainingDays: Int
        public let expTime: String
        public let autoRenew: Bool?
        public let renewAt: String?
    }

    public let id: Int
    public let email: String
    public let userName: String
    public let avatar: String?
    public let latestAdminReplyAt: String?
    public let regDate: String?
    public let `class`: Int
    public let classExpire: String
    public let expireIn: String
    public let upload: Int64
    public let download: Int64
    public let transferEnable: Int64
    public let lastDayT: Int64
    public let nodeSpeedlimit: Double
    public let nodeConnector: Int
    // 面板按超级管理员下发：测速不限次数，本地额度预判跳过；旧面板不下发时为 nil
    public let speedTestUnlimited: Bool?
    public let onlineClientCount: Int
    public let onlineClientSelf: Bool?
    public let deviceKickNotice: Bool?
    public let deviceKickReason: String?
    public let enableCheckin: Bool?
    public let ableToCheckin: Bool?
    public let lastCheckInTime: String?
    public let lastSsTime: String?
    public let checkinMin: Int?
    public let checkinMax: Int?
    public let money: Double
    public let trafficReset: String
    public let plan: Plan?
    public let configRevision: String
    public let apiOrigin: String
    public let siteOrigin: String
    let revisions: [String: String]?

    public enum Page: String, Sendable { case tickets, invite, unlock }
    // 面板未下发该页版本号时为 nil，页面退回定时刷新
    public func revision(_ page: Page) -> String? { revisions?[page.rawValue] }

    public var displayName: String { userName.isEmpty ? email : userName }
    public var used: Int64 { upload + download }
    public var remaining: Int64 { max(0, transferEnable - used) }
    public var todayUsed: Int64 { max(0, used - lastDayT) }
    public var usedRatio: Double {
        transferEnable > 0 ? min(1, max(0, Double(used) / Double(transferEnable))) : 0
    }

    func validate() throws {
        guard id > 0, !email.isEmpty, upload >= 0, download >= 0,
              !upload.addingReportingOverflow(download).overflow,
              transferEnable >= 0, lastDayT >= 0, nodeConnector >= 0,
              onlineClientCount >= 0, nodeSpeedlimit.isFinite, money.isFinite else {
            throw ClientError.invalidResponse
        }
    }
}

struct LoginResult: Decodable, Sendable {
    var message: String?
    let token: String
    let expiresAt: String
    let user: UserProfile?
    let accountStatus: AccountStatus?

    func expiration() throws -> Date {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: expiresAt) { return date }
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: expiresAt) else { throw ClientError.invalidResponse }
        return date
    }
}

public struct CloudNode: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let protocolName: String
    public let network: String
    public let tls: String
    public let udp: String
}

public struct NodeSelectionGroup: Codable, Identifiable, Sendable {
    public let id: String
    public let members: [String]
    public let type: String
    public var selectable: Bool { type == "select" }
}

// 翻页、搜索或按名取到的节点（POST /config/nodes）
public struct CatalogNode: Sendable {
    public let node: CloudNode
    let rank: Int
    let providers: [String]
    let proxy: Data
}

// 面板只下发了一部分节点时附带的目录，见 docs/server-api.md「节点目录」
struct NodePaging: Sendable {
    // 分组在一个节点文件上的翻页位置；known 是已在面板配置里的节点表成员数
    struct Page: Sendable {
        let key: String
        let total: Int
        let head: Int
        let known: Int
    }
    let stamp: String
    let ranks: [String: Int]
    let pages: [String: [Page]]
}

public struct NodeCatalog: Sendable {
    public let revision: String
    public let nodes: [CloudNode]
    public let selectionGroups: [NodeSelectionGroup]
    public let groups: [NodeSelectionGroup]
    public let mainGroupID: String?
    private let groupLabels: [String: String]
    public let groupIcons: [String: String]
    private let configurationData: Data
    private let nodeIndex: [String: Int]
    // 节点副本超过内核装载上限，或面板只下发了一部分节点：内核里只有一部分节点，选用和测试前要先问内核装没装（NodeWorkingSet）
    let partial: Bool
    let paging: NodePaging?
    // 面板响应原文，只在分页时留着：并入后来取到的节点要改它，改完的这份才是落盘缓存
    private let source: Data?
    // 各分组在面板上的成员总数（没带下来的也算），只在分页时有
    private let totals: [String: Int]
    let issuedAt: Date?
    let validUntil: Date?
    var updateIntervalHours: Int?

    // 与面板 /link/ 订阅响应头 profile-update-interval: 24 保持一致
    static let defaultUpdateIntervalHours = 24

    static func updateIntervalHours(_ raw: String?) -> Int? {
        guard let hours = raw.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), (1...8760).contains(hours) else { return nil }
        return hours
    }

    func updateDue(at now: Date) -> Bool {
        guard let issuedAt else { return true }
        return now.timeIntervalSince(issuedAt) >= TimeInterval((updateIntervalHours ?? Self.defaultUpdateIntervalHours) * 3600)
    }

    // pinned 是固定装入内核的节点，probe 是只为测试临时装入的节点，见 NodeWorkingSet
    public func assemble(options: ProfileOptions, selections: [String: String] = [:], pinned: [String] = [], probe: [String] = []) throws -> AssembledProfile {
        try ProfileAssembler.assemble(configurationData, options: options, selections: selections, pinned: pinned, probe: probe)
    }

    func validate() throws { _ = try ProfileAssembler.validate(configurationData) }

    init(response: Data) throws {
        guard let body = (try? JSONSerialization.jsonObject(with: response) as? [String: Any])?["data"] as? [String: Any] else { throw ClientError.invalidResponse }
        try self.init(body, source: response)
    }

    // 配置保持面板下发的形态：各组节点文件只带成员名单时不在这里还原，节点多时还原出的副本是节点数的几倍
    init(_ body: [String: Any], source: Data? = nil) throws {
        guard let revision = body["revision"] as? String, let raw = body["config"] as? [String: Any],
              let listed = raw["proxies"] as? [[String: Any]] else { throw ClientError.invalidResponse }
        self.revision = revision
        let authorization = body["offline_authorization"] as? [String: Any]
        issuedAt = (authorization?["issued_at"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        validUntil = (authorization?["valid_until"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        configurationData = try JSONSerialization.data(withJSONObject: raw, options: [.withoutEscapingSlashes])
        // PHP 空关联数组会编码成 []；非空数组仍须拒绝。
        func stringMap(_ key: String) throws -> [String: String]? {
            guard let value = body[key] else { return nil }
            if let map = value as? [String: String] { return map }
            guard (value as? [Any])?.isEmpty == true else { throw ClientError.invalidResponse }
            return [:]
        }
        guard let labels = try stringMap("node_labels") else { throw ClientError.invalidResponse }
        groupLabels = try stringMap("group_labels") ?? [:]
        groupIcons = try stringMap("group_icons") ?? [:]
        mainGroupID = (raw["rules"] as? [String])?.compactMap { rule -> String? in
            let parts = rule.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count >= 2 && parts[0].uppercased() == "MATCH" ? parts[1] : nil
        }.first
        let providers = raw["proxy-providers"] as? [String: [String: Any]] ?? [:]
        var listing: (stamp: String, files: [String: [String: Any]], ranks: [String: Int])?
        if let value = body["catalog"] as? [String: Any] {
            guard let stamp = value["stamp"] as? String, !stamp.isEmpty, let files = value["providers"] as? [String: [String: Any]],
                  let ranks = value["ranks"] as? [String: Int] ?? ((value["ranks"] as? [Any])?.isEmpty == true ? [:] : nil) else { throw ClientError.invalidResponse }
            listing = (stamp, files, ranks)
        }
        var pages: [String: [NodePaging.Page]] = [:], totals: [String: Int] = [:]
        var groupNames = Set<String>()
        groups = try (raw["proxy-groups"] as? [[String: Any]] ?? []).compactMap { group in
            guard let type = group["type"] as? String, group["hidden"] as? Bool != true else { return nil }
            guard let name = group["name"] as? String, !name.isEmpty, groupNames.insert(name).inserted else { throw ClientError.invalidResponse }
            var members = group["proxies"] as? [String] ?? []
            for file in group["use"] as? [String] ?? [] {
                let listed = providers[file].map(NodeWorkingSet.members) ?? []
                members += listed
                guard let listing, let entry = listing.files[file] else { continue }
                guard let key = entry["key"] as? String, !key.isEmpty, let total = entry["total"] as? Int, total >= 0,
                      let head = entry["head"] as? Int, head >= 0 else { throw ClientError.invalidResponse }
                pages[name, default: []].append(.init(key: key, total: total, head: head, known: listed.count { listing.ranks[$0] != nil }))
            }
            var seen = Set<String>()
            members = members.filter { !$0.isEmpty && $0 != "ecy-panel-empty" && seen.insert($0).inserted }
            if let listing, let files = pages[name] { totals[name] = members.count { listing.ranks[$0] == nil } + files.reduce(0) { $0 + $1.total } }
            return members.isEmpty ? nil : NodeSelectionGroup(id: name, members: members, type: type)
        }
        paging = listing.map { NodePaging(stamp: $0.stamp, ranks: $0.ranks, pages: pages) }
        self.source = paging == nil ? nil : source
        self.totals = totals
        selectionGroups = groups.filter(\.selectable)
        let metadata: [[String: Any]]
        if let provider = providers[NodeWorkingSet.nodesProvider] {
            guard let payload = provider["payload"] as? [[String: Any]] else { throw ClientError.invalidResponse }
            metadata = payload
        } else { metadata = listed }
        var index: [String: Int] = [:]
        nodes = try metadata.enumerated().map { offset, details in
            guard let node = Self.cloudNode(details, label: (details["name"] as? String).flatMap { labels[$0] }),
                  index.updateValue(offset, forKey: node.id) == nil else { throw ClientError.invalidResponse }
            return node
        }
        nodeIndex = index
        partial = paging != nil || NodeWorkingSet.exceedsBudget(raw)
        (nodeLabels, otherLabels) = Self.annotations(nodes: nodes, groups: groupLabels)
        // 长标识在前，短标识不会先吃掉长标识的一段
        let identifiers = (otherLabels.map { NSRegularExpression.escapedPattern(for: $0.0) } + [#"node-\d+"#]).joined(separator: "|")
        logPattern = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_-])(?:"# + identifiers + #")(?![\p{L}\p{N}_-])"#)
        configurationPattern = try! NSRegularExpression(pattern: #"(?<=")(?:"# + identifiers + #")(?=")|(?<=,)(?:"# + identifiers + #")(?=[",])"#)
    }

    static func cloudNode(_ details: [String: Any], label: String?) -> CloudNode? {
        guard let id = details["name"] as? String, let kind = details["type"] as? String, !id.isEmpty, !kind.isEmpty else { return nil }
        let type = kind.lowercased()
        // 与 app/lib/state/connection_controller.dart 的 _displayType / _tlsTypeOf / udpOf 一致
        let tls = (details["reality-opts"] as? [String: Any])?.isEmpty == false ? "REALITY"
            : details["tls"] as? Bool == true || ["hysteria", "hysteria2", "tuic", "anytls"].contains(type) ? "TLS" : ""
        // 内核对 VLESS 默认启用 XUDP（adapter/outbound/vless.go），只有 packet-addr / packet-encoding: packetaddr 才关掉
        let encoding = details["packet-encoding"] as? String
        let xudp = type == "vless"
            ? !["packetaddr", "packet"].contains(encoding ?? "") && (details["xudp"] as? Bool == true || details["packet-addr"] as? Bool != true)
            : details["xudp"] as? Bool == true || encoding == "xudp"
        return CloudNode(id: id, name: label ?? id, protocolName: displayTypes[type] ?? kind,
                         network: (details["network"] as? String ?? "").trimmingCharacters(in: .whitespaces).uppercased(),
                         tls: tls, udp: xudp ? "XUDP" : details["udp"] as? Bool == true ? "UDP" : "")
    }

    // 把后来取到的节点并入面板响应（docs/architecture.md「节点目录分页」的并入规则），返回并入后的目录与要落盘的响应
    func merging(_ added: [CatalogNode]) throws -> (catalog: NodeCatalog, response: Data) {
        guard let source, var root = try JSONSerialization.jsonObject(with: source) as? [String: Any], var body = root["data"] as? [String: Any],
              var config = body["config"] as? [String: Any], var providers = config["proxy-providers"] as? [String: [String: Any]],
              var listing = body["catalog"] as? [String: Any], let files = listing["providers"] as? [String: [String: Any]] else { throw ClientError.invalidResponse }
        var ranks = listing["ranks"] as? [String: Int] ?? [:]
        var labels = body["node_labels"] as? [String: String] ?? [:]
        var seen = Set<String>()
        let added = added.filter { ranks[$0.node.id] == nil && seen.insert($0.node.id).inserted }
        for (file, var provider) in providers where file.hasPrefix("ecy-panel-") {
            guard let key = file == NodeWorkingSet.nodesProvider ? file : files[file]?["key"] as? String else { continue }
            let mine = added.filter { $0.providers.contains(key) }
            if mine.isEmpty { continue }
            if let members = provider["members"] as? [String] {
                provider["members"] = NodeWorkingSet.inserting(mine.map { ($0.rank, $0.node.id) }, into: members) { ranks[$0] }
            } else {
                let proxies = try mine.map { ($0.rank, try JSONSerialization.jsonObject(with: $0.proxy) as? [String: Any] ?? [:]) }
                let payload = (provider["payload"] as? [[String: Any]] ?? []).filter { $0["name"] as? String != "ecy-panel-empty" }
                provider["payload"] = NodeWorkingSet.inserting(proxies, into: payload) { ($0["name"] as? String).flatMap { ranks[$0] } }
            }
            providers[file] = provider
        }
        for node in added {
            ranks[node.node.id] = node.rank
            labels[node.node.id] = node.node.name
        }
        listing["ranks"] = ranks; body["catalog"] = listing; body["node_labels"] = labels
        config["proxy-providers"] = providers; body["config"] = config; root["data"] = body
        let response = try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])
        var catalog = try NodeCatalog(response: response)
        catalog.updateIntervalHours = updateIntervalHours
        return (catalog, response)
    }

    public func rank(_ id: String) -> Int? { paging?.ranks[id] }

    // 分组的成员总数：面板只下发了一部分节点时，没带上的也算。按目录算，不按传入的成员数：
    // 目录刚换新、内核还没重读时，内核报告的成员里有新目录不认识的节点
    public func total(of group: NodeSelectionGroup) -> Int { totals[group.id] ?? group.members.count }

    private static let displayTypes = [
        "direct": "Direct", "reject": "Reject", "rematch": "Rematch", "dns": "DNS", "ss": "Shadowsocks",
        "ssr": "ShadowsocksR", "snell": "Snell", "socks5": "SOCKS5", "http": "HTTP", "vmess": "VMess", "vless": "VLESS",
        "trojan": "Trojan", "hysteria": "Hysteria", "hysteria2": "Hysteria2", "wireguard": "WireGuard", "tuic": "TUIC",
        "ssh": "SSH", "mieru": "Mieru", "anytls": "AnyTLS", "sudoku": "Sudoku", "masque": "MASQUE",
        "trusttunnel": "TrustTunnel", "shadowquic": "ShadowQuic", "openvpn": "OpenVPN", "tailscale": "Tailscale",
        "gost-relay": "GostRelay", "select": "Selector", "url-test": "URLTest", "fallback": "Fallback",
        "load-balance": "LoadBalance", "relay": "Relay"
    ]

    public func groups(for mode: ClientPreferences.Mode, runtime: [NodeSelectionGroup] = []) -> [NodeSelectionGroup] {
        // 内核只装了一部分节点时成员按面板目录列全，未装入的节点选用时再装入（NodeWorkingSet）。
        // 分页时一律按目录：目录刚换新、内核还没重读的那一刻，内核里还留着新目录不认识的节点
        func merged(_ group: NodeSelectionGroup) -> NodeSelectionGroup {
            guard let live = runtime.first(where: { $0.id == group.id }) else { return group }
            return paging != nil || live.members.count < group.members.count ? NodeSelectionGroup(id: group.id, members: group.members, type: live.type) : live
        }
        return switch mode {
        case .direct: []
        case .rule: groups.map(merged)
        case .global: runtime.filter { $0.id == "GLOBAL" }.map { live in groups.first { $0.id == live.id }.map(merged) ?? live }
        }
    }

    public func node(_ id: String) -> CloudNode? { nodeIndex[id].map { nodes[$0] } }

    public func displayName(_ id: String) -> String { node(id)?.name ?? groupLabels[id] ?? id }

    // 对应 node_labels.dart 的 _ensureLabels：标识对显示名，跳过空键，名字自带的国旗保留，名字是 node-数字 或为空时显示为空。
    // node-数字 的标识单独成表，其余标识长的在前
    private let nodeLabels: [String: String]
    private let otherLabels: [(String, String)]

    static func isNodeID(_ text: String) -> Bool {
        text.hasPrefix("node-") && text.utf8.count > 5 && text.utf8.dropFirst(5).allSatisfy { (48...57).contains($0) }
    }

    private static func annotations(nodes: [CloudNode], groups: [String: String]) -> ([String: String], [(String, String)]) {
        var numbered: [String: String] = [:], others: [(String, String)] = []
        for (id, name) in nodes.map({ ($0.id, $0.name) }) + groups.map({ ($0.key, $0.value) }) {
            let label = isNodeID(name) ? "" : name
            guard !id.isEmpty, id != label else { continue }
            if isNodeID(id) { numbered[id] = numbered[id] ?? label } else { others.append((id, label)) }
        }
        return (numbered, others.sorted { $0.0.count > $1.0.count })
    }

    private static func replacing(_ pattern: NSRegularExpression, in raw: String, with replacement: (String) -> String) -> String {
        let text = raw as NSString
        var next = "", cursor = 0
        for match in pattern.matches(in: raw, range: NSRange(location: 0, length: text.length)) {
            next += text.substring(with: NSRange(location: cursor, length: match.range.location - cursor)) + replacement(text.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        return next + text.substring(from: cursor)
    }

    // 两张替换模式随目录建一次：标识都列进模式，每次调用现编的话耗时随标识数增长
    private let logPattern: NSRegularExpression
    private let configurationPattern: NSRegularExpression

    // 对应 node_labels.dart 的 annotateText：按完整标识替换，前后不能紧挨字母、数字、下划线或连字符；没有名字的 node-数字 一并去掉。
    // node-数字 匹配到后查表：把每个节点标识都列进模式，模式长度与编译耗时随节点数增长
    public func annotateLogs(_ messages: [String]) -> [String] {
        let names = Dictionary(otherLabels, uniquingKeysWith: { first, _ in first })
        return messages.map { line in
            // 对应 logger.dart 的 kernelChain：内核的 `策略组[节点]` 改为与连接页一致的 `策略组 → 节点`，须在换成显示名之前改
            let raw = line.replacingOccurrences(of: #" using ([^\[\]]+)\[([^\[\]]+)\]$"#, with: " using $1 → $2", options: .regularExpression)
            return Self.replacing(logPattern, in: raw) { names[$0] ?? nodeLabels[$0] ?? $0 }
                .replacingOccurrences(of: #"(?<![\w-])node-\d+(?![\w-])"#, with: "", options: .regularExpression)
        }
    }

    // 对应 node_labels.dart 的 annotateRuntimeConfig：只替换带引号或逗号边界的整段标识，长标识先换。
    // 全部标识单遍查表：逐个标识各扫一遍全文，耗时是「配置长度 × 标识数」
    func annotateRuntimeConfiguration(_ raw: String) -> String {
        func escaped(_ label: String) -> String { label.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let names = Dictionary(otherLabels, uniquingKeysWith: { first, _ in first })
        return Self.replacing(configurationPattern, in: raw) { (names[$0] ?? nodeLabels[$0]).map(escaped) ?? $0 }
            .replacingOccurrences(of: #"(?<![\w-])node-\d+(?![\w-])"#, with: "", options: .regularExpression)
    }
}

public struct DeviceInfo: Sendable {
    public let id: String
    public let name: String
    public let model: String
    public let os: String
    public let platform: String
    public let version: String

    public init(id: String, name: String, model: String, os: String, platform: String, version: String) {
        self.id = id
        self.name = name
        self.model = model
        self.os = os
        self.platform = platform
        self.version = version
    }
}
