import Foundation
import Darwin

public struct NetworkRoute: Equatable, Sendable {
    public let address: String
    public let prefix: Int
    public let ipv6: Bool
    public var subnetMask: String {
        let bits = prefix == 0 ? UInt32(0) : UInt32.max << (32 - prefix)
        return [24, 16, 8, 0].map { String((bits >> $0) & 255) }.joined(separator: ".")
    }
    public init?(_ text: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]) else { return nil }
        var v4 = in_addr(), v6 = in6_addr()
        let address = String(parts[0])
        if inet_pton(AF_INET, address, &v4) == 1, (0...32).contains(prefix) { ipv6 = false }
        else if inet_pton(AF_INET6, address, &v6) == 1, (0...128).contains(prefix) { ipv6 = true }
        else { return nil }
        self.address = address; self.prefix = prefix
    }
}

public enum NetworkSegments {
    public static let proxyDefaults = ["127.0.0.1", "localhost", "*.local", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"]
    public static let routeDefaults = ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8"]
    public static func split(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",;\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    public static func parse(_ text: String, routes: Bool) throws -> [String] {
        let values = split(text)
        guard values.count <= 256, values.allSatisfy({ routes ? NetworkRoute($0) != nil : validProxyBypass($0) }) else {
            throw ClientError.input(routes ? L10n.t("仅支持 IPv4/IPv6 CIDR") : L10n.t("仅支持主机名、IP、CIDR 或通配"))
        }
        return unique(values)
    }
    public static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
    public static func validProxyBypass(_ value: String) -> Bool {
        guard value.utf8.count <= 253 else { return false }
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, value, &v4) == 1 || inet_pton(AF_INET6, value, &v6) == 1 || NetworkRoute(value) != nil { return true }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        if labels.allSatisfy({ $0 == "*" || Int($0).map { (0...255).contains($0) } == true }), labels.count <= 4 { return true }
        return labels.allSatisfy { $0.range(of: #"^(?:\*|[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)$"#, options: .regularExpression) != nil }
    }
}
