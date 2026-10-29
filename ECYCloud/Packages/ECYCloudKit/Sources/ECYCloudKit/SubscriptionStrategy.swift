import Foundation

public struct CustomProxyGroup: Codable, Identifiable, Sendable, Equatable {
    public var id = UUID()
    public var name: String, icon: String?, includeNodes: Bool, proxies: [String]
    enum CodingKeys: String, CodingKey { case name, icon, includeNodes, proxies }
    public init(name: String = "", icon: String? = nil, includeNodes: Bool = true, proxies: [String] = []) {
        self.name = name; self.icon = icon; self.includeNodes = includeNodes; self.proxies = proxies
    }
}
public struct CustomRuleProvider: Codable, Identifiable, Sendable, Equatable {
    public var id = UUID()
    public var name: String, url: String, policy: String, behavior: String, format: String, interval: Int
    enum CodingKeys: String, CodingKey { case name, url, policy, behavior, format, interval }
    public init(name: String = "", url: String = "", policy: String = "", behavior: String = "classical", format: String = "yaml", interval: Int = 86400) {
        self.name = name; self.url = url; self.policy = policy; self.behavior = behavior; self.format = format; self.interval = interval
    }
}
public struct SubscriptionStrategy: Decodable, Sendable {
    public struct Icons: Decodable, Sendable {
        public let values: [String: String]
        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let map = try? container.decode([String: String].self) { values = map }
            else {
                let empty = try decoder.unkeyedContainer()
                guard empty.isAtEnd else { throw ClientError.invalidResponse }
                values = [:]
            }
        }
    }
    public let groupIcons: Icons?
    public let customizableGroups: [String], allGroupNames: [String], availableProxyNames: [String]
    public let groupLabels: [String: String]
    public let allowCustomHosts: Bool, allowCustomRules: Bool, allowCustomGroups: Bool, allowCustomRuleProviders: Bool
    public let maxCustomHosts: Int, maxCustomRules: Int, maxCustomGroups: Int, maxCustomRuleProviders: Int
    public let disabledGroups: [String]
    public let customHosts: String, customRules: String
    public let customGroups: [CustomProxyGroup], customRuleProviders: [CustomRuleProvider]
}
extension ClientSession {
    public func subscriptionStrategy() async throws -> SubscriptionStrategy {
        try await authenticated { try await api.request("/user/subscription-config", origin: endpoints.site, token: $0.token) }
    }
    public func saveSubscriptionStrategy(disabled: [String]? = nil, hosts: String? = nil, rules: String? = nil, groups: [CustomProxyGroup]? = nil, providers: [CustomRuleProvider]? = nil) async throws -> String {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        var body: [String: String] = [:]
        if let disabled { body["disabled_groups"] = String(decoding: try encoder.encode(disabled), as: UTF8.self) }
        if let hosts { body["custom_hosts"] = hosts }
        if let rules { body["custom_rules"] = rules }
        if let groups { body["custom_groups"] = String(decoding: try encoder.encode(groups), as: UTF8.self) }
        if let providers { body["custom_rule_providers"] = String(decoding: try encoder.encode(providers), as: UTF8.self) }
        let result = try await authenticated { try await api.perform("/user/subscription-config", origin: endpoints.site, token: $0.token, body: body).message }
        await loadNodes()
        return result
    }
}
