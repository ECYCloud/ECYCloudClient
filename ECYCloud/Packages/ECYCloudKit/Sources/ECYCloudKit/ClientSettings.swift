import Foundation

public struct RuleProviderInfo: Decodable, Identifiable, Sendable {
    public let name: String
    public let ruleCount: Int
    public let behavior: String
    public let path: String
    public var id: String { name }
}

public enum ClientRelease {
    public static let releasesURL = URL(string: "https://github.com/ECYCloud/ECYCloudClient/releases")!
    public static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "ECYDisplayVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
    struct Entry: Decodable {
        let tagName: String, publishedAt: String?
        let draft: Bool, prerelease: Bool
    }
    static func version(_ tag: String) -> String? {
        guard let range = tag.range(of: #"^v?[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression) else { return nil }
        return String(tag[range]).replacingOccurrences(of: "v", with: "")
    }
    static func target(_ data: Data, current: String) throws -> String {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let entries = try decoder.decode([Entry].self, from: data).filter {
            !$0.draft && $0.publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) } != nil && version($0.tagName) != nil
        }.sorted { $0.publishedAt! > $1.publishedAt! }
        guard let entry = entries.first(where: { current.hasPrefix("Pre ") || !$0.prerelease }) else { throw ClientError.invalidResponse }
        return (entry.prerelease ? "Pre " : "") + version(entry.tagName)!
    }
    static func newer(_ latest: String, than current: String) -> Bool {
        if current.hasPrefix("Pre "), !latest.hasPrefix("Pre ") { return true }
        let a = version(latest.replacingOccurrences(of: "Pre ", with: ""))?.split(separator: ".").compactMap { Int($0) } ?? []
        let b = version(current.replacingOccurrences(of: "Pre ", with: ""))?.split(separator: ".").compactMap { Int($0) } ?? []
        return a.count == 3 && b.count == 3 && b.lexicographicallyPrecedes(a)
    }
}

extension ClientSession {
    public func applyLogLevel() async throws {
        guard phase == .signedIn, let connection, connection.controlPlaneReady else { return }
        _ = try await connection.request(.init(.logging, level: preferences.logLevel))
    }
    public func kernelVersion() async throws -> String {
        guard phase == .signedIn, let connection else { throw TunnelError.control }
        struct Version: Decodable { let version: String }
        let version = try JSONDecoder().decode(Version.self, from: await connection.request(.init(.version))).version
        return version.range(of: #"\d+(?:\.\d+)+\S*"#, options: .regularExpression).map { String(version[$0]) } ?? ""
    }
    public func latestKernelVersion() async throws -> String {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let entry = try decoder.decode(ClientRelease.Entry.self, from: await githubReleases("MetaCubeX/mihomo", path: "/latest"))
        guard !entry.draft, !entry.prerelease, let version = ClientRelease.version(entry.tagName) else { throw ClientError.invalidResponse }
        return version
    }
    public func updateGeoData() async throws {
        guard phase == .signedIn, let connection else { throw TunnelError.control }
        struct Progress: Decodable { let running: Bool?; let failed: Bool? }
        var progress = try JSONDecoder().decode(Progress.self, from: await connection.request(.init(.geodata)))
        while progress.running == true {
            try await Task.sleep(for: .milliseconds(500))
            progress = try JSONDecoder().decode(Progress.self, from: await connection.request(.init(.geodata, scope: "status")))
        }
        if progress.failed == true { throw ClientError.input(L10n.t("GeoData 更新失败，请稍后重试。")) }
    }
    public func ruleProviders() async throws -> [RuleProviderInfo] {
        guard phase == .signedIn, let connection else { throw TunnelError.control }
        struct Providers: Decodable { let providers: [String: RuleProviderInfo] }
        let data = try await connection.request(.init(.rules))
        return try JSONDecoder().decode(Providers.self, from: data).providers.values.sorted { $0.name < $1.name }
    }
    public func readRuleProvider(_ name: String) async throws -> String {
        guard phase == .signedIn, let connection else { throw TunnelError.control }
        struct Chunk: Decodable { let data: Data; let done: Bool; let version: String }
        var data = Data()
        var version = ""
        for page in 1...256 {
            let chunk = try JSONDecoder().decode(Chunk.self, from: await connection.request(.init(.rules, page: page, group: name, scope: "content", query: version)))
            guard page == 1 || version == chunk.version else { throw TunnelError.control }
            version = chunk.version
            guard data.count + chunk.data.count <= URLSessionTransport.maximumResponseBytes else { throw ClientError.responseTooLarge }
            data.append(chunk.data)
            if chunk.done {
                guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { return L10n.t("二进制规则集不能以文本显示。") }
                return text
            }
        }
        throw ClientError.responseTooLarge
    }
    public func checkClientUpdate() async throws -> (latest: String, outdated: Bool) {
        let current = ClientRelease.currentVersion
        let latest = try ClientRelease.target(await githubReleases("ECYCloud/ECYCloudClient", path: "?per_page=30"), current: current)
        return (latest, ClientRelease.newer(latest, than: current))
    }
    private func githubReleases(_ repository: String, path: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases\(path)")!, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let result = try await api.transport.send(request)
        guard result.status == 200, result.data.count <= 4 * 1024 * 1024 else { throw ClientError.invalidResponse }
        return result.data
    }
}
