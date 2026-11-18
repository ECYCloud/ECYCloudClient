import Foundation
import Testing
@testable import ECYCloudKit

private enum Offline {
    static let endpoints = try! PanelEndpoints(site: "https://site.example.test", config: "https://config.example.test")
    static let device = DeviceInfo(id: "synthetic-device", name: "测试设备", model: "Mac（Swift）", os: "macOS 14.0", platform: "macOS", version: "Pre 0.1.1")
    static let now = Date(timeIntervalSince1970: 1_500_000_000)
    static let status = #"{"enable":1,"email":"member@example.test","deletion_time":null,"ban_reason":null,"ban_time_text":null,"support_email":"support@example.test"}"#

    static func profile(kick: String? = nil) -> String {
        #"""
        {"id":7,"email":"member@example.test","user_name":"测试账户","class":2,
         "class_expire":"2099-01-01 00:00:00","expire_in":"2099-01-01 00:00:00",
         "upload":100,"download":300,"transfer_enable":1000,"last_day_t":150,
         "node_speedlimit":100,"node_connector":3,"online_client_count":1,"money":12.5,
         "traffic_reset":"每月重置","plan":null,"config_revision":"revision-1",
         "device_kick_reason":\#(kick.map { "\"\($0)\"" } ?? "null"),
         "api_origin":"https://config.example.test","site_origin":"https://site.example.test"}
        """#
    }

    static func catalog(until: Int = 1_600_000_000) -> String {
        #"""
        {"revision":"revision-1","config":{"proxies":[],"proxy-providers":{
          "ecy-panel-nodes":{"type":"file","path":"ecy-panel-nodes.json","payload":[{"name":"node-12","type":"ss"}]}},
          "proxy-groups":[{"name":"主节点","type":"select","use":["ecy-panel-nodes"]}],"rules":["MATCH,主节点"]},
         "node_labels":{"node-12":"测试节点"},
         "offline_authorization":{"issued_at":1400000000,"valid_until":\#(until)}}
        """#
    }

    static func envelope(_ json: String) -> Data { Data(#"{"ret":1,"data":\#(json)}"#.utf8) }
    static func ok(_ json: String) -> Result<HTTPResult, ClientError> { .success(HTTPResult(data: envelope(json), status: 200)) }
    static func unreachable(_ code: URLError.Code) -> Result<HTTPResult, ClientError> { .failure(.networkFailure(code.rawValue)) }

    static var stored: StoredSession {
        StoredSession(token: "synthetic-token", expiresAt: Date(timeIntervalSince1970: 4_070_908_800),
                      email: "member@example.test", userID: 7, endpoints: endpoints)
    }
}

private actor Script: HTTPTransport {
    private var results: [Result<HTTPResult, ClientError>]
    private(set) var methods: [String] = []
    init(_ results: [Result<HTTPResult, ClientError>]) { self.results = results }
    func send(_ request: URLRequest) async throws -> HTTPResult {
        methods.append(request.httpMethod ?? "GET")
        guard !results.isEmpty else { throw ClientError.network }
        return try results.removeFirst().get()
    }
    func count() -> Int { methods.count }
}

@MainActor
private final class Vault: CredentialVault {
    var logoutPending = false
    var endpoints: PanelEndpoints?
    var value: StoredSession? = Offline.stored
    func load() throws -> StoredSession? { value }
    func save(_ session: StoredSession) throws { value = session }
    func clear() throws { value = nil }
    func loadRemembered() throws -> RememberedLogin? { nil }
    func saveRemembered(_ login: RememberedLogin) throws {}
    func clearRemembered() throws {}
}

@MainActor
private final class PortDriver: TunnelDriver {
    var statusChanged: (@MainActor (ConnectionState) -> Void)?
    var panelProxyPort: Int? { 7890 }
    var started = false
    func reconcile(owner: String?) async {}
    func start(_ lease: TunnelLease) async throws { started = true }
    func stop() { statusChanged?(.disconnected) }
}

@MainActor
private final class OrderedDriver: TunnelDriver {
    var statusChanged: (@MainActor (ConnectionState) -> Void)?
    let transport: Script
    var requestsBeforeStart: Int?
    init(_ transport: Script) { self.transport = transport }
    func reconcile(owner: String?) async {}
    func start(_ lease: TunnelLease) async throws { requestsBeforeStart = await transport.count() }
    func stop() { statusChanged?(.disconnected) }
}

@Suite("面板离线缓存与代理回退", .timeLimit(.minutes(1)), .isolatedUserData)
@MainActor
struct OfflinePanelTests {
    private func withCache(_ body: (PanelResponseCache) async throws -> Void) async rethrows {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ecycloud-offline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(PanelResponseCache(directory: directory))
    }

    private func seed(_ cache: PanelResponseCache, token: String = "synthetic-token", kick: String? = nil, until: Int = 1_600_000_000) {
        let api = PanelAPI(device: Offline.device, transport: Script([]))
        cache.saveProfile(Offline.envelope(Offline.profile(kick: kick)), account: "Member@Example.test")
        cache.saveConfig(Offline.envelope(Offline.catalog(until: until)), account: "member@example.test", binding: api.cacheBinding(Offline.endpoints, token: token),
                         sealKey: api.cacheKey(token: token), updateIntervalHours: nil)
    }

    private func session(_ transport: Script, cache: PanelResponseCache, vault: Vault = Vault(), connection: ConnectionController? = nil) -> ClientSession {
        ClientSession(endpoints: Offline.endpoints, api: PanelAPI(device: Offline.device, transport: transport),
                      vault: vault, connection: connection, cache: cache, now: { Offline.now })
    }

    @Test func unreachablePanelRestoresFromValidCache() async {
        await withCache { cache in
            seed(cache)
            let vault = Vault()
            let value = session(Script([Offline.unreachable(.cannotConnectToHost)]), cache: cache, vault: vault)
            await value.restore()
            #expect(value.phase == .signedIn && value.profile?.id == 7 && value.catalog?.revision == "revision-1")
            #expect(value.message == nil && vault.value != nil)
        }
    }

    // 对应 connection_controller.dart 的 _hydrateRemoteFromCache：缓存里结构检查不通过的节点目录不用，也不能凭它离线拉起内核
    @Test func invalidCachedCatalogIsIgnoredOnRestore() async {
        await withCache { cache in
            let api = PanelAPI(device: Offline.device, transport: Script([]))
            let binding = api.cacheBinding(Offline.endpoints, token: "synthetic-token")
            cache.saveProfile(Offline.envelope(Offline.profile()), account: "member@example.test")
            let invalid = Offline.catalog(until: 1_600_000_000)
                .replacingOccurrences(of: #""rules":["MATCH,主节点"]"#, with: #""rules":["MATCH,主节点"],"geox-url":{"mmdb":"http://example.test/geoip.metadb"}"#)
            cache.saveConfig(Offline.envelope(invalid), account: "member@example.test", binding: binding,
                             sealKey: api.cacheKey(token: "synthetic-token"), updateIntervalHours: nil)
            let driver = PortDriver()
            let value = session(Script([Offline.unreachable(.cannotConnectToHost)]), cache: cache, connection: ConnectionController(driver: driver))
            await value.restore()
            #expect(value.phase == .signedIn && value.profile?.id == 7 && value.catalog == nil)
            await value.connect()
            #expect(!driver.started)
        }
    }

    // 授权窗口外或设备被移除时仍凭缓存资料与节点进入界面，令牌已换时节点缓存解不开、只显示资料，面板更新前都不得拉起内核
    @Test(arguments: [("another-token", nil, 1_600_000_000), ("synthetic-token", nil, 1_400_000_001),
                      ("synthetic-token", "remove", 1_600_000_000)] as [(String, String?, Int)])
    func unusableConfigIsShownButCannotStartKernel(token: String, kick: String?, until: Int) async {
        await withCache { cache in
            seed(cache, token: token, kick: kick, until: until)
            let driver = PortDriver()
            let value = session(Script([Offline.unreachable(.cannotConnectToHost)]), cache: cache, connection: ConnectionController(driver: driver))
            await value.restore()
            let sameLogin = token == "synthetic-token"
            #expect(value.phase == .signedIn && value.profile?.id == 7 && value.catalog?.revision == (sameLogin ? "revision-1" : nil))
            await value.connect()
            #expect(!driver.started)
            if sameLogin && kick == nil { #expect(value.message == L10n.t("本地配置授权已到期，请连接面板更新后重试")) }
        }
    }

    @Test func validOfflineWindowConnectsBeforeVerifyingWithPanel() async {
        await withCache { cache in
            seed(cache, until: 4_000_000_000)
            let transport = Script([Offline.unreachable(.cannotConnectToHost), Offline.ok(Offline.status), Offline.ok(Offline.profile())])
            let driver = OrderedDriver(transport)
            let value = session(transport, cache: cache, connection: ConnectionController(driver: driver))
            await value.restore()
            #expect(await transport.count() == 1)
            await value.connect()
            #expect(driver.requestsBeforeStart == 1)
            while await transport.count() < 3 { await Task.yield() }
            while value.panelOffline { await Task.yield() }
            #expect(value.phase == .signedIn && value.profile?.id == 7)
            value.connection?.disconnect()
        }
    }

    @Test func expiredOfflineWindowCannotStartKernelAndSaysWhy() async {
        await withCache { cache in
            seed(cache, until: 4_000_000_000)
            var instant = Offline.now
            let driver = PortDriver()
            let value = ClientSession(endpoints: Offline.endpoints, api: PanelAPI(device: Offline.device, transport: Script([Offline.unreachable(.cannotConnectToHost)])),
                                      vault: Vault(), connection: ConnectionController(driver: driver), cache: cache, now: { instant })
            await value.restore()
            #expect(value.catalog != nil)
            instant = Date(timeIntervalSince1970: 4_000_000_001)
            await value.connect()
            #expect(!driver.started && value.message == L10n.t("本地配置授权已到期，请连接面板更新后重试"))
        }
    }

    @Test func backgroundRefreshFailureIsSilentButManualRefreshReports() async {
        await withCache { cache in
            seed(cache)
            let unreachable = Offline.unreachable(.cannotConnectToHost)
            let value = session(Script([unreachable, unreachable, unreachable, Offline.ok(Offline.status), Offline.ok(Offline.profile())]), cache: cache)
            await value.restore()
            #expect(value.panelOffline && value.message == nil)
            await value.refresh(silently: true)
            #expect(value.panelOffline && value.message == nil && value.phase == .signedIn)
            await value.refresh()
            #expect(value.message != nil)
            await value.refresh(silently: true)
            #expect(!value.panelOffline && value.profile?.id == 7)
        }
    }

    @Test func pageLoadsWhilePanelUnreachableDoNotRaiseGlobalNotice() async {
        await withCache { cache in
            seed(cache)
            let unreachable = Offline.unreachable(.cannotConnectToHost)
            let value = session(Script([unreachable, unreachable, unreachable, unreachable,
                                        .success(HTTPResult(data: Data(#"{"ret":0,"msg":"合成业务错误"}"#.utf8), status: 200))]), cache: cache)
            await value.restore()
            await #expect(throws: ClientError.unreachable(URLError.cannotConnectToHost.rawValue)) { _ = try await value.trafficHistory() }
            #expect(value.message == nil && value.panelOffline && value.phase == .signedIn)
            await #expect(throws: ClientError.self) { _ = try await value.trafficHistory() }
            #expect(value.message != nil)
        }
    }

    @Test func signedInWithoutCacheEntersImmediately() async {
        await withCache { cache in
            let vault = Vault()
            let value = session(Script([Offline.unreachable(.cannotConnectToHost)]), cache: cache, vault: vault)
            await value.restore()
            #expect(value.phase == .signedIn && value.profile == nil && value.catalog == nil && vault.value != nil)
        }
    }

    @Test func mismatchedStatusKeepsCacheButAppliesNothing() async {
        await withCache { cache in
            seed(cache)
            let value = session(Script([Offline.ok(Offline.status.replacingOccurrences(of: "member@", with: "other@"))]), cache: cache)
            await value.restore()
            #expect(value.phase == .signedIn && value.profile?.id == 7 && value.accountStatus == nil)
        }
    }

    @Test func revokedTokenClearsCache() async {
        await withCache { cache in
            seed(cache)
            let value = session(Script([.success(HTTPResult(data: Data(#"{"ret":0,"msg":"合成错误"}"#.utf8), status: 401))]), cache: cache)
            await value.restore()
            #expect(value.phase == .signedOut)
            let api = PanelAPI(device: Offline.device, transport: Script([]))
            let binding = api.cacheBinding(Offline.endpoints, token: "synthetic-token")
            #expect(cache.restore(account: "member@example.test", binding: binding, sealKey: api.cacheKey(token: "synthetic-token"), now: Offline.now) == nil)
        }
    }

    @Test func onlineRestoreRefreshesCache() async {
        await withCache { cache in
            let value = session(Script([Offline.ok(Offline.status), Offline.ok(Offline.profile()), Offline.ok(Offline.catalog())]), cache: cache)
            await value.restore()
            #expect(value.phase == .signedIn && value.catalog?.revision == "revision-1")
            let api = PanelAPI(device: Offline.device, transport: Script([]))
            let binding = api.cacheBinding(Offline.endpoints, token: "synthetic-token")
            let key = api.cacheKey(token: "synthetic-token")
            #expect(cache.restore(account: "member@example.test", binding: binding, sealKey: key, now: Offline.now)?.profile.id == 7)
            #expect(cache.restore(account: "member@example.test", binding: binding, sealKey: key, now: Date(timeIntervalSince1970: 1_600_000_000))?.validUntil == nil)
            #expect(cache.restore(account: "member@example.test", binding: binding, sealKey: key, now: Date(timeIntervalSince1970: 1_399_999_990))?.validUntil != nil)
            #expect(cache.restore(account: "member@example.test", binding: binding, sealKey: key, now: Date(timeIntervalSince1970: 1_399_999_989))?.validUntil == nil)
        }
    }

    // 配置缓存只以令牌派生的密钥加密落盘：文件里没有节点凭据原文，换了登录或拷到别的设备都解不开，旧版本明文缓存读到即删除
    @Test func cachedConfigIsSealedWithTokenDerivedKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ecycloud-offline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PanelResponseCache(directory: directory)
        seed(cache)
        let file = directory.appendingPathComponent("config.json")
        let raw = try String(contentsOf: file, encoding: .utf8)
        let plain = Offline.envelope(Offline.catalog(until: 1_600_000_000))
        #expect(!raw.contains(plain.base64EncodedString().prefix(64)) && !raw.contains("revision-1"))
        let api = PanelAPI(device: Offline.device, transport: Script([]))
        let binding = api.cacheBinding(Offline.endpoints, token: "synthetic-token")
        #expect(cache.restore(account: "member@example.test", binding: binding, sealKey: api.cacheKey(token: "synthetic-token"), now: Offline.now)?.catalog?.revision == "revision-1")
        let otherDevice = PanelAPI(device: DeviceInfo(id: "other-device", name: Offline.device.name, model: Offline.device.model, os: Offline.device.os,
                                                      platform: Offline.device.platform, version: Offline.device.version), transport: Script([]))
        #expect(cache.restore(account: "member@example.test", binding: binding, sealKey: otherDevice.cacheKey(token: "synthetic-token"), now: Offline.now)?.catalog == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        seed(cache)
        #expect(cache.restore(account: "member@example.test", binding: binding, sealKey: api.cacheKey(token: "other-token"), now: Offline.now)?.catalog == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        struct Legacy: Encodable { let account: String; let binding: String; let response: Data }
        try JSONEncoder().encode(Legacy(account: "member@example.test", binding: binding, response: plain)).write(to: file)
        #expect(cache.restore(account: "member@example.test", binding: binding, sealKey: api.cacheKey(token: "synthetic-token"), now: Offline.now)?.catalog == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func directFailureRetriesThroughLocalProxyOnlyWhenSafe() async throws {
        let direct = Script([
            Offline.unreachable(.timedOut), Offline.unreachable(.timedOut), Offline.unreachable(.cannotConnectToHost),
            .success(HTTPResult(data: Data(#"{"ret":0,"msg":"合成错误"}"#.utf8), status: 500)), Offline.unreachable(.timedOut)
        ])
        let proxy = Script([Offline.ok("{}"), Offline.ok("{}")])
        let api = PanelAPI(device: Offline.device, transport: direct) { port in
            #expect(port == 7890)
            return proxy
        }
        var port: Int? = 7890
        var connected = true
        api.route.connected = { connected }
        api.route.proxyPort = { port }

        _ = try await api.perform("/user/account-status", origin: Offline.endpoints.site, token: "synthetic-token")
        await #expect(throws: ClientError.networkFailure(URLError.timedOut.rawValue)) {
            _ = try await api.perform("/tickets", origin: Offline.endpoints.site, token: "synthetic-token", body: [:])
        }
        _ = try await api.perform("/tickets", origin: Offline.endpoints.site, token: "synthetic-token", body: [:])
        await #expect(throws: ClientError.self) {
            _ = try await api.perform("/user/account-status", origin: Offline.endpoints.site, token: "synthetic-token")
        }
        port = nil
        connected = false
        await #expect(throws: ClientError.networkFailure(URLError.timedOut.rawValue)) {
            _ = try await api.perform("/user/account-status", origin: Offline.endpoints.site, token: "synthetic-token")
        }
        #expect(await proxy.methods == ["GET", "POST"])
        #expect(await direct.count() == 5)
    }

    // 移动端接管时没有混合端口：先走绑定物理网卡的直连，连不上再用普通请求进入 VPN 隧道；未接管时只走普通请求
    @Test func takeoverWithoutProxyPortFallsBackIntoTunnel() async throws {
        let bound = Script([Offline.unreachable(.cannotConnectToHost), Offline.unreachable(.timedOut)])
        let tunnel = Script([Offline.ok("{}"), Offline.ok("{}")])
        let api = PanelAPI(device: Offline.device, transport: tunnel, direct: bound) { _ in Script([]) }
        var connected = true
        api.route.connected = { connected }
        _ = try await api.perform("/tickets", origin: Offline.endpoints.site, token: "synthetic-token", body: [:])
        await #expect(throws: ClientError.networkFailure(URLError.timedOut.rawValue)) {
            _ = try await api.perform("/tickets", origin: Offline.endpoints.site, token: "synthetic-token", body: [:])
        }
        connected = false
        _ = try await api.perform("/announcements", origin: Offline.endpoints.site, token: "synthetic-token")
        #expect(await bound.methods == ["POST", "POST"])
        #expect(await tunnel.methods == ["POST", "GET"])
    }

    @Test func unestablishedConnectionsRetryThreeTimesExceptAccountStatus() async throws {
        let refused = Offline.unreachable(.cannotConnectToHost)
        let direct = Script([refused, refused, refused, refused, refused, Offline.ok("{}")])
        let api = PanelAPI(device: Offline.device, transport: direct) { _ in Script([]) }
        await #expect(throws: ClientError.unreachable(URLError.cannotConnectToHost.rawValue)) {
            _ = try await api.perform("/announcements", origin: Offline.endpoints.site, token: "synthetic-token")
        }
        #expect(await direct.count() == 3)
        await #expect(throws: ClientError.networkFailure(URLError.cannotConnectToHost.rawValue)) {
            _ = try await api.perform("/user/account-status", origin: Offline.endpoints.site, token: "synthetic-token")
        }
        #expect(await direct.count() == 4)
        _ = try await api.perform("/announcements", origin: Offline.endpoints.site, token: "synthetic-token")
        #expect(await direct.count() == 6)
    }

    @Test func runtimeConfigurationShowsNodeAndGroupLabels() throws {
        let catalog: NodeCatalog = try PanelAPI.decode(Offline.envelope(#"""
        {"revision":"r","config":{"proxies":[{"name":"node-12","type":"ss"}],"proxy-groups":[{"name":"main","type":"select","proxies":["node-12"]}]},
         "node_labels":{"node-12":"德国 \"A1\""},"group_labels":{"main":"主节点"}}
        """#))
        let text = catalog.annotateRuntimeConfiguration(#"{"proxies":["node-12","node-120"],"rules":["MATCH,main"],"note":"node-12 via","host":"main.example"}"#)
        #expect(text == #"{"proxies":["德国 \"A1\"",""],"rules":["MATCH,主节点"],"note":" via","host":"main.example"}"#)
    }

    // 对应 assets_test.dart 的日志用例：完整标识才换，保留名字自带的国旗，名字为 node-数字 或空时换成空，空键不参与
    @Test func logsShowNodeAndGroupLabelsLikeFlutter() throws {
        let catalog: NodeCatalog = try PanelAPI.decode(Offline.envelope(#"""
        {"revision":"r","config":{"proxies":[{"name":"node-120","type":"ss"},{"name":"node-12","type":"ss"},{"name":"node-9","type":"ss"},
         {"name":"node-5","type":"ss"},{"name":"node-6","type":"ss"}],
         "proxy-groups":[{"name":"主节点","type":"select","proxies":["node-120"]},{"name":"Google服务","type":"select","proxies":["主节点"]}]},
         "node_labels":{"node-120":"🇭🇰 香港 01","node-12":"备用","node-9":"Fixture node","node-5":"node-7","node-6":"","":"空键节点"},
         "group_labels":{"主节点":"Main nodes","Google服务":"Google services","":"空键分组"}}
        """#))
        #expect(catalog.annotateLogs([
            "[TCP] 198.18.0.1:23016(ECYCloud.exe) --> owo.ecycloud.com:443 match Match using 主节点[node-120]",
            "node-12 and node-120", "match Match using Google服务[主节点[node-9]] (a, b)", "Match using 主节点备份[node-9]",
            "via node-5|node-6|node-99", "DIRECT"
        ]) == [
            "[TCP] 198.18.0.1:23016(ECYCloud.exe) --> owo.ecycloud.com:443 match Match using Main nodes → 🇭🇰 香港 01",
            "备用 and 🇭🇰 香港 01", "match Match using Google services[Main nodes[Fixture node]] (a, b)", "Match using 主节点备份 → Fixture node",
            "via ||", "DIRECT"
        ])
    }

    // 空标签键在每个边界都能匹配，运行配置里的空串与逗号会被改写成标签
    @Test func emptyLabelKeysDoNotRewriteRuntimeConfiguration() throws {
        let catalog: NodeCatalog = try PanelAPI.decode(Offline.envelope(#"""
        {"revision":"r","config":{"proxies":[{"name":"node-12","type":"ss"}],"proxy-groups":[{"name":"main","type":"select","proxies":["node-12"]}]},
         "node_labels":{"node-12":"德国","":"空键节点"},"group_labels":{"":"空键分组"}}
        """#))
        let text = catalog.annotateRuntimeConfiguration(#"{"external-ui":"","proxies":["node-12"],"rules":["MATCH,main"]}"#)
        #expect(text == #"{"external-ui":"","proxies":["德国"],"rules":["MATCH,main"]}"#)
    }

    @Test func runtimeConfigurationHidesControlSecrets() throws {
        let raw = Data(#"{"secret":"control-secret","external-controller":"127.0.0.1:9090","listeners":[{"name":"ecy-speed","port":10204,"users":[{"username":"ecy-speed","password":"speed-digest"}]}],"proxies":[{"name":"node-1","server":"node.example.test","uuid":"device-uuid"}],"proxy-providers":{"ecy-panel-nodes":{"type":"inline","payload":[{"name":"node-2","password":"device-password","plugin-opts":{"password":"nested-secret"}},{"name":"node-3","auth":"device-auth"}]}}}"#.utf8)
        let text = try ClientSession.maskedRuntimeConfiguration(raw)
        #expect(!text.contains("control-secret") && !text.contains("speed-digest"))
        #expect(!text.contains("device-uuid") && !text.contains("device-password") && !text.contains("nested-secret") && !text.contains("device-auth"))
        #expect(text.contains("node.example.test") && text.contains("node-3"))
        #expect(text.contains("127.0.0.1:9090") && text.contains("10204") && text.contains("******"))
        #expect(throws: TunnelError.self) { try ClientSession.maskedRuntimeConfiguration(Data("[]".utf8)) }
    }

    @Test func runtimeConfigurationListsPanelNodesOnce() throws {
        let group = "ecy-panel-" + String(repeating: "a", count: 64)
        let raw = Data(#"{"proxy-providers":{"ecy-panel-nodes":{"type":"file","path":"ecy-panel-nodes.json","payload":[{"name":"node-1","server":"node.example.test","uuid":"node-credential","reality-opts":{"public-key":"reality-public-key","short-id":"0123abcd"}}]},"\#(group)":{"type":"file","path":"\#(group).json","payload":[{"name":"node-1","server":"node.example.test","uuid":"node-credential"}]},"custom":{"type":"inline","payload":[{"name":"c","password":"custom-secret"}]}}}"#.utf8)
        let text = try ClientSession.maskedRuntimeConfiguration(raw)
        let providers = (try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])["proxy-providers"] as! [String: [String: Any]]
        #expect((providers["ecy-panel-nodes"]?["payload"] as? [Any])?.count == 1)
        #expect(providers[group]?["payload"] == nil && providers[group]?["path"] as? String == "\(group).json")
        #expect((providers["custom"]?["payload"] as? [Any])?.count == 1)
        #expect(text.components(separatedBy: "node.example.test").count == 2)
        #expect(!text.contains("node-credential") && !text.contains("custom-secret"))
        #expect(!text.contains("reality-public-key") && !text.contains("0123abcd"))
    }

    @Test func proxyPortOnlyWhileConnected() async {
        let driver = PortDriver()
        let controller = ConnectionController(driver: driver)
        let lease = TunnelLease(owner: "synthetic-owner", expiresAt: .now.addingTimeInterval(3600), configuration: Data("synthetic-config".utf8))
        await controller.reconcile(owner: lease.owner, expiresAt: lease.expiresAt)
        await controller.connect(lease)
        #expect(controller.panelProxyPort == nil)
        driver.statusChanged?(.connected)
        #expect(controller.panelProxyPort == 7890)
    }
}
