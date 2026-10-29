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
          "ecy-panel-nodes":{"type":"file","payload":[{"name":"node-12","type":"ss"}]}}},
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

@Suite("面板离线缓存与代理回退", .timeLimit(.minutes(1)))
@MainActor
struct OfflinePanelTests {
    private func withCache(_ body: (PanelResponseCache) async throws -> Void) async rethrows {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ecycloud-offline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(PanelResponseCache(directory: directory))
    }

    private func seed(_ cache: PanelResponseCache, token: String = "synthetic-token", kick: String? = nil, until: Int = 1_600_000_000) {
        let binding = PanelAPI(device: Offline.device, transport: Script([])).cacheBinding(Offline.endpoints, token: token)
        cache.saveProfile(Offline.envelope(Offline.profile(kick: kick)), account: "Member@Example.test")
        cache.saveConfig(Offline.envelope(Offline.catalog(until: until)), account: "member@example.test", binding: binding)
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

    // 授权窗口外、令牌已换或设备被移除时仍凭缓存资料与节点进入界面，但面板更新前不得拉起内核
    @Test(arguments: [("another-token", nil, 1_600_000_000), ("synthetic-token", nil, 1_400_000_001),
                      ("synthetic-token", "remove", 1_600_000_000)] as [(String, String?, Int)])
    func unusableConfigIsShownButCannotStartKernel(token: String, kick: String?, until: Int) async {
        await withCache { cache in
            seed(cache, token: token, kick: kick, until: until)
            let driver = PortDriver()
            let value = session(Script([Offline.unreachable(.cannotConnectToHost)]), cache: cache, connection: ConnectionController(driver: driver))
            await value.restore()
            #expect(value.phase == .signedIn && value.profile?.id == 7 && value.catalog?.revision == "revision-1")
            await value.connect()
            #expect(!driver.started)
            if kick == nil { #expect(value.message == L10n.t("本地配置授权已到期，请连接面板更新后重试")) }
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
            let binding = PanelAPI(device: Offline.device, transport: Script([])).cacheBinding(Offline.endpoints, token: "synthetic-token")
            #expect(cache.restore(account: "member@example.test", binding: binding, now: Offline.now) == nil)
        }
    }

    @Test func onlineRestoreRefreshesCache() async {
        await withCache { cache in
            let value = session(Script([Offline.ok(Offline.status), Offline.ok(Offline.profile()), Offline.ok(Offline.catalog())]), cache: cache)
            await value.restore()
            #expect(value.phase == .signedIn && value.catalog?.revision == "revision-1")
            let binding = PanelAPI(device: Offline.device, transport: Script([])).cacheBinding(Offline.endpoints, token: "synthetic-token")
            #expect(cache.restore(account: "member@example.test", binding: binding, now: Offline.now)?.profile.id == 7)
            #expect(cache.restore(account: "member@example.test", binding: binding, now: Date(timeIntervalSince1970: 1_600_000_000))?.validUntil == nil)
        }
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
