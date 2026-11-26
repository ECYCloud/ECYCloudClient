import Foundation
import Observation
import Testing
@testable import ECYCloudKit

@Suite("设置、语言与图标边界")
struct SettingsParityTests {
    @Test @MainActor func preferencesPersistAndKeepPacketFlowPortsClosed() throws {
        let suite = "ecycloud-settings-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ClientPreferences(defaults: defaults)
        #expect(preferences.mixedPort == 10203 && !preferences.ipv6 && !preferences.strictRoute && !preferences.autoConnect)
        preferences.allowLAN = true; preferences.mixedPort = 12000; preferences.strictRoute = true
        preferences.excludedRoutes = ["203.0.113.0/24", "2001:db8::/32"]
        preferences.systemProxyBypass = ["*.example.test"]
        preferences.language = .enUS; preferences.logLevel = "silent"; preferences.autoConnect = true
        let restored = ClientPreferences(defaults: defaults)
        #expect(restored.language == .enUS && restored.autoConnect && restored.logLevel == "silent")
        #expect(restored.systemProxyBypass == ["*.example.test"] && restored.mixedPort == 12000)
        #expect(restored.packetProfile.input == .packetFlow && restored.packetProfile.mixedPort == 0)
        #expect(restored.packetProfile.excludedRoutes == preferences.excludedRoutes)
    }
    @Test func bypassValidationAndSubnetMasks() throws {
        #expect(try NetworkSegments.parse("203.0.113.0/24;\n2001:db8::/32,203.0.113.0/24", routes: true) == ["203.0.113.0/24", "2001:db8::/32"])
        #expect(NetworkRoute("0.0.0.0/0")?.subnetMask == "0.0.0.0")
        #expect(NetworkRoute("203.0.113.1/32")?.subnetMask == "255.255.255.255")
        for value in ["127.0.0.1", "2001:db8::1", "*.local", "example.test", "192.168.*", "203.0.113.0/24"] { #expect(NetworkSegments.validProxyBypass(value)) }
        // 只有路由器 DNS 认识的局域网名字默认不进代理，与 Flutter 三个桌面端一致
        for value in ["*.local", "*.lan", "*.home.arpa", "*.internal", "*.localdomain"] {
            #expect(NetworkSegments.proxyDefaults.contains(value) && NetworkSegments.validProxyBypass(value))
        }
        for value in ["https://example.test", "x\ny", "../secret", "a", "999.999.999.999/32", "::1/129", "127.0.0.1/33"] {
            #expect(throws: Error.self) { try NetworkSegments.parse(value, routes: true) }
        }
    }
    // 与 OpenWrt TPROXY 保留网段同一份；包隧道按这份列表写排除路由，新增网段不能盖住隧道自身地址、内置 DNS 与 fake-ip 网段
    @Test func defaultExcludedRoutesAreReservedAndKeepTunnelTrafficInside() throws {
        #expect(NetworkSegments.routeDefaults == ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4",
                                                  "0.0.0.0/8", "100.64.0.0/10", "192.0.0.0/24", "192.88.99.0/24", "240.0.0.0/4",
                                                  "::1/128", "100::/64", "fc00::/7", "fe80::/10", "ff00::/8"])
        func bits(_ text: String) -> [UInt8] {
            var v4 = in_addr(), v6 = in6_addr()
            if inet_pton(AF_INET, text, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
            _ = inet_pton(AF_INET6, text, &v6)
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        func covers(_ route: NetworkRoute, _ address: String) -> Bool {
            let network = bits(route.address), target = bits(address)
            guard network.count == target.count else { return false }
            return (0..<route.prefix).allSatisfy { bit in (network[bit / 8] ^ target[bit / 8]) & (0x80 >> UInt8(bit % 8)) == 0 }
        }
        let routes = try NetworkSegments.routeDefaults.map { try #require(NetworkRoute($0)) }
        for route in routes {
            let network = bits(route.address)
            #expect((route.prefix..<(network.count * 8)).allSatisfy { bit in network[bit / 8] & (0x80 >> UInt8(bit % 8)) == 0 }, "\(route.address)/\(route.prefix) 不是网络地址")
        }
        #expect(["0.0.0.0/8", "100.64.0.0/10", "192.0.0.0/24", "192.88.99.0/24", "240.0.0.0/4"].map { NetworkRoute($0)!.subnetMask }
                == ["255.0.0.0", "255.192.0.0", "255.255.255.0", "255.255.255.0", "240.0.0.0"])
        // 内置 DNS 只被既有的 172.16.0.0/12 覆盖，由包隧道额外包含的 172.19.0.2/32 主机路由压过
        #expect(routes.filter { covers($0, "172.19.0.2") }.map(\.address) == ["172.16.0.0"])
        for address in ["198.18.0.1", "198.19.255.254", "223.5.5.5", "1.1.1.1", "8.8.8.8", "2001:4860:4860::8888"] {
            #expect(!routes.contains { covers($0, address) }, "\(address) 被默认排除")
        }
        let options = ProfileOptions.packetFlow
        let remote = Data(#"{"proxies":[{"name":"node-1","type":"socks5","server":"192.0.2.1","port":1080}],"proxy-groups":[{"name":"选择","type":"select","proxies":["node-1"]}],"rules":["MATCH,选择"]}"#.utf8)
        let assembled = try JSONSerialization.jsonObject(with: ProfileAssembler.assemble(remote, options: options).data) as! [String: Any]
        #expect((assembled["tun"] as? [String: Any])?["route-exclude-address"] as? [String] == NetworkSegments.routeDefaults)
    }
    @Test func languagesAndInterpolationMatchFlutterContract() {
        #expect(AppLanguage.resolve(nil, device: "zh-Hant-HK") == .zhTW)
        #expect(AppLanguage.resolve(nil, device: "fr-FR") == .enUS)
        #expect(AppLanguage.resolve("zh_CN", device: "en-US") == .zhCN)
        #expect(L10n.t("设置", language: .enUS) == "Settings")
        #expect(L10n.t("语言", language: .zhTW) == "語言")
        #expect(L10n.t("{0}（请在 {1} 秒后重试）", ["{1}", "30"], language: .enUS) == "{1} (try again in 30 seconds)")
        let token = try! NSRegularExpression(pattern: #"\{\d+\}|%(?:\d+\$)?(?:\.\d+)?[dfs@]"#)
        func slots(_ text: String) -> [String] {
            token.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range, in: text)!]) }.sorted()
        }
        for language in [AppLanguage.enUS, .zhTW] {
            for (key, value) in L10n.translations[language.rawValue]! { #expect(slots(key) == slots(value), "\(language.rawValue): \(key)") }
        }
    }
    @Test func releaseChannelsAndVersions() throws {
        let data = Data(#"[{"tag_name":"v0.2.0-test","published_at":"2026-10-20T00:00:00Z","draft":false,"prerelease":true},{"tag_name":"v0.1.2","published_at":"2026-10-19T00:00:00Z","draft":false,"prerelease":false}]"#.utf8)
        #expect(try ClientRelease.target(data, current: "0.1.1") == "0.1.2")
        #expect(try ClientRelease.target(data, current: "Pre 0.1.1") == "Pre 0.2.0")
        #expect(ClientRelease.newer("0.1.2", than: "Pre 0.2.0"))
        #expect(!ClientRelease.newer("0.1.2", than: "0.2.0"))
    }
    @Test func remoteIconsRejectUnsafeSchemesAndCredentials() {
        let origin = URL(string: "https://panel.example.test")!
        #expect(RemoteIconStore.resolve("/icons/group.svg", origin: origin)?.absoluteString == "https://panel.example.test/icons/group.svg")
        for raw in ["file:///tmp/a", "javascript:alert(1)", "http://example.test/icon", "https://user:password@example.test/icon"] {
            #expect(RemoteIconStore.resolve(raw, origin: origin) == nil)
        }
        #expect(RemoteIconStore.resolve(nil, origin: origin)?.absoluteString == "https://rules.ecydy.com/images/Custom.png")
    }
    @Test func diskLogThresholdDoesNotChangeViewerAndSilentDoesNotWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ecycloud-log-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClientLogStore(directory: directory, level: "warning")
        store.append(time: "synthetic", level: "info", message: "hidden-info")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        store.append(time: "synthetic", level: "error", message: "synthetic-error")
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let before = try Data(contentsOf: file)
        store.level = "silent"; store.append(time: "synthetic", level: "error", message: "hidden-error")
        #expect(try Data(contentsOf: file) == before)
        #expect(String(decoding: before, as: UTF8.self).contains("synthetic-error"))
    }
    @Test func diskLogRetainsRecentDataAndThirtyDays() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ecycloud-log-rotate-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        let file = directory.appendingPathComponent("app-\(formatter.string(from: .now)).log")
        try Data(repeating: 97, count: 10 * 1024 * 1024).write(to: file)
        let expired = directory.appendingPathComponent("app-\(formatter.string(from: Calendar.current.date(byAdding: .day, value: -30, to: .now)!)).log")
        let retained = directory.appendingPathComponent("app-\(formatter.string(from: Calendar.current.date(byAdding: .day, value: -29, to: .now)!)).log")
        try Data().write(to: expired); try Data().write(to: retained)
        let store = ClientLogStore(directory: directory, level: "warning")
        store.append(time: "synthetic", level: "warning", message: "newest-entry")
        let data = try Data(contentsOf: file)
        #expect(data.count > 8 * 1024 * 1024 && data.count < 10 * 1024 * 1024)
        #expect(String(decoding: data.suffix(100), as: UTF8.self).contains("newest-entry"))
        #expect(!FileManager.default.fileExists(atPath: expired.path))
        #expect(FileManager.default.fileExists(atPath: retained.path))
    }
    @Test @MainActor func vectorIconsRejectExecutableAndUnboundedContent() {
        #expect(SVGIcon(data: Data(##"<svg viewBox="0 0 24 24"><path fill="#123456" d="M2 2h20v20H2Z"/><circle cx="12" cy="12" r="3" fill="white"/></svg>"##.utf8)) != nil)
        let rejected = [
            #"<svg><script>alert(1)</script><rect width="24" height="24"/></svg>"#,
            #"<!DOCTYPE svg [<!ENTITY x SYSTEM "file:///private/secret">]><svg>&x;</svg>"#,
            #"<svg><rect width="inf" height="24"/></svg>"#,
            #"<svg><path d="M0 0 A1e-320 1e-320 0 0 0 24 24"/></svg>"#,
            #"<svg><rect width="24" height="24" fill="url(https://example.test/paint)"/></svg>"#,
            "<svg>" + String(repeating: "<g>", count: 65) + "<rect width=\"24\" height=\"24\"/>" + String(repeating: "</g>", count: 65) + "</svg>"
        ]
        for source in rejected { #expect(SVGIcon(data: Data(source.utf8)) == nil) }
    }
}

private final class IconProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        let path = request.url!.path
        if path == "/wait" { return }
        let redirect = ["/redirect", "/downgrade", "/loop"].contains(path)
        var headers: [String: String] = [:]
        if path == "/redirect" { headers["Location"] = "https://icons.example.test/icon" }
        if path == "/downgrade" { headers["Location"] = "http://icons.example.test/unsafe" }
        if path == "/loop" { headers["Location"] = "https://icons.example.test/loop" }
        if path == "/length" { headers["Content-Length"] = String(RemoteIconStore.maximumBytes + 1) }
        #expect(path != "/unsafe")
        let response = HTTPURLResponse(url: request.url!, statusCode: redirect ? 302 : 200, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !redirect { client?.urlProtocol(self, didLoad: path == "/chunks" ? Data(repeating: 1, count: RemoteIconStore.maximumBytes + 1) : Data([137, 80, 78, 71, 13, 10, 26, 10])) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("图标下载限制", .timeLimit(.minutes(1))) @MainActor
struct IconTransportTests {
    private func store() -> RemoteIconStore {
        RemoteIconStore {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [IconProtocol.self]
            return configuration
        }
    }
    @Test func secureRedirectAndCache() async throws {
        let store = store(), url = URL(string: "https://icons.example.test/redirect")!
        let first = try await store.load(url)
        #expect(first == Data([137, 80, 78, 71, 13, 10, 26, 10]))
        #expect(try await store.load(url) == first)
    }
    @Test(arguments: ["length", "chunks", "downgrade", "loop"])
    func refusesUnsafeOrOversizedImages(_ path: String) async {
        let store = store()
        await #expect(throws: Error.self) { try await store.load(URL(string: "https://icons.example.test/" + path)!) }
    }
    @Test func logoutCancelsPendingDownload() async {
        let store = store()
        let task = Task { try await store.load(URL(string: "https://icons.example.test/wait")!) }
        await Task.yield()
        store.clear()
        await #expect(throws: Error.self) { try await task.value }
    }
    @Test func iconsPersistLocallyAndAccountChangesRemoveOldFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ecycloud-icon-cache-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = String(repeating: "a", count: 64)
        let first = RemoteIconStore(directory: directory) {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [IconProtocol.self]
            return config
        }
        first.configure(owner: owner)
        let url = URL(string: "https://icons.example.test/icon")!
        let data = try await first.load(url)
        let restored = RemoteIconStore(directory: directory) {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [OfflineIconProtocol.self]
            return config
        }
        restored.configure(owner: owner)
        #expect(try await restored.load(url) == data)
        restored.configure(owner: String(repeating: "b", count: 64))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(owner).path))
        await #expect(throws: Error.self) { try await restored.load(url) }
        first.clear(); restored.clear()
    }
}

private final class OfflineIconProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
}
