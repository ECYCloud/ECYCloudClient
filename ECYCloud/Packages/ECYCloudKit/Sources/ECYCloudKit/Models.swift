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

    private static func origin(_ raw: String) throws -> URL {
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
        public let id: Int?
        public let name: String
        public let remainingDays: Int
        public let expTime: String
        public let autoRenew: Bool?
        public let renewAt: String?
        public let canToggleAutoRenew: Bool?
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

    public enum Page: String, Sendable { case shop, tickets, invite, unlock }
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

public struct NodeCatalog: Decodable, Sendable {
    public let revision: String
    public let nodes: [CloudNode]
    public let selectionGroups: [NodeSelectionGroup]
    public let groups: [NodeSelectionGroup]
    public let mainGroupID: String?
    private let groupLabels: [String: String]
    public let groupIcons: [String: String]
    private let configurationData: Data

    public func assemble(options: ProfileOptions, selections: [String: String] = [:]) throws -> AssembledProfile {
        try ProfileAssembler.assemble(configurationData, options: options, selections: selections)
    }

    private struct Proxy: Decodable {
        let name: String
        let type: String
    }

    private struct Configuration: Decodable {
        struct Provider: Decodable { let payload: [Proxy] }
        struct Providers: Decodable {
            let nodes: Provider?
            enum CodingKeys: String, CodingKey { case nodes = "ecy-panel-nodes" }
        }
        let proxies: [Proxy]
        let providers: Providers?
        enum CodingKeys: String, CodingKey {
            case proxies
            case providers = "proxy-providers"
        }
    }

    private enum CodingKeys: String, CodingKey { case config, revision, nodeLabels, groupLabels, groupIcons }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        revision = try values.decode(String.self, forKey: .revision)
        let configuration = try values.decode(Configuration.self, forKey: .config)
        configurationData = try JSONEncoder().encode(values.decode([String: ProfileValue].self, forKey: .config))
        let labels: [String: String]
        // PHP 空关联数组会编码成 []；非空数组仍须拒绝。
        if let map = try? values.decode([String: String].self, forKey: .nodeLabels) {
            labels = map
        } else {
            let empty = try values.nestedUnkeyedContainer(forKey: .nodeLabels)
            guard empty.isAtEnd else { throw ClientError.invalidResponse }
            labels = [:]
        }
        let raw = try JSONSerialization.jsonObject(with: configurationData) as! [String: Any]
        if values.contains(.groupLabels) {
            if let map = try? values.decode([String: String].self, forKey: .groupLabels) { groupLabels = map }
            else {
                let empty = try values.nestedUnkeyedContainer(forKey: .groupLabels)
                guard empty.isAtEnd else { throw ClientError.invalidResponse }
                groupLabels = [:]
            }
        } else { groupLabels = [:] }
        if values.contains(.groupIcons) {
            if let map = try? values.decode([String: String].self, forKey: .groupIcons) { groupIcons = map }
            else {
                let empty = try values.nestedUnkeyedContainer(forKey: .groupIcons)
                guard empty.isAtEnd else { throw ClientError.invalidResponse }
                groupIcons = [:]
            }
        } else { groupIcons = [:] }
        mainGroupID = (raw["rules"] as? [String])?.compactMap { rule -> String? in
            let parts = rule.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count >= 2 && parts[0].uppercased() == "MATCH" ? parts[1] : nil
        }.first
        let providers = raw["proxy-providers"] as? [String: [String: Any]] ?? [:]
        var groupNames = Set<String>()
        groups = try (raw["proxy-groups"] as? [[String: Any]] ?? []).compactMap { group in
            guard let type = group["type"] as? String, group["hidden"] as? Bool != true else { return nil }
            guard let name = group["name"] as? String, !name.isEmpty, groupNames.insert(name).inserted else { throw ClientError.invalidResponse }
            var members = group["proxies"] as? [String] ?? []
            for key in group["use"] as? [String] ?? [] {
                members += (providers[key]?["payload"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            }
            var seen = Set<String>()
            members = members.filter { !$0.isEmpty && $0 != "ecy-panel-empty" && seen.insert($0).inserted }
            return members.isEmpty ? nil : NodeSelectionGroup(id: name, members: members, type: type)
        }
        selectionGroups = groups.filter(\.selectable)
        let proxies = configuration.providers?.nodes?.payload ?? configuration.proxies
        let metadata = (providers["ecy-panel-nodes"]?["payload"] as? [[String: Any]]) ?? (raw["proxies"] as? [[String: Any]] ?? [])
        var names = Set<String>()
        nodes = try proxies.map { proxy in
            guard !proxy.name.isEmpty, !proxy.type.isEmpty, names.insert(proxy.name).inserted else {
                throw ClientError.invalidResponse
            }
            let details = metadata.first { $0["name"] as? String == proxy.name }
            let type = proxy.type.lowercased()
            // 与 app/lib/state/connection_controller.dart 的 _displayType / _tlsTypeOf / udpOf 一致
            let tls = (details?["reality-opts"] as? [String: Any])?.isEmpty == false ? "REALITY"
                : details?["tls"] as? Bool == true || ["hysteria", "hysteria2", "tuic", "anytls"].contains(type) ? "TLS" : ""
            let xudp = details?["xudp"] as? Bool == true || details?["packet-encoding"] as? String == "xudp"
            return CloudNode(id: proxy.name, name: labels[proxy.name] ?? proxy.name, protocolName: Self.displayTypes[type] ?? proxy.type,
                             network: (details?["network"] as? String ?? "").trimmingCharacters(in: .whitespaces).uppercased(),
                             tls: tls, udp: xudp ? "XUDP" : details?["udp"] as? Bool == true ? "UDP" : "")
        }
    }

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
        switch mode {
        case .direct: []
        case .rule: groups.map { group in runtime.first { $0.id == group.id } ?? group }
        case .global: runtime.filter { $0.id == "GLOBAL" }
        }
    }

    public func displayName(_ id: String) -> String { nodes.first { $0.id == id }?.name ?? groupLabels[id] ?? id }

    // 对应 node_labels.dart 的 annotateRuntimeConfig：只替换带引号或逗号边界的整段标识，长标识先换
    func annotateRuntimeConfiguration(_ raw: String) -> String {
        let labels = (nodes.map { ($0.id, $0.name) } + groupLabels.map { ($0.key, $0.value) })
            .filter { $0.0 != $0.1 }.sorted { $0.0.count > $1.0.count }
        var out = raw
        for (id, label) in labels {
            let shown = label.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            out = out.replacingOccurrences(of: "\"\(id)\"", with: "\"\(shown)\"")
                .replacingOccurrences(of: ",\(id)\"", with: ",\(shown)\"")
                .replacingOccurrences(of: ",\(id),", with: ",\(shown),")
        }
        return out.replacingOccurrences(of: #"(?<![\w-])node-\d+(?![\w-])"#, with: "", options: .regularExpression)
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
