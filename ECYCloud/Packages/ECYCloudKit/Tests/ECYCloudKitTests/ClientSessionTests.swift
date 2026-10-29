import Foundation
import Security
import Testing
@testable import ECYCloudKit

private enum Fixture {
    static let endpoints = try! PanelEndpoints(site: "https://site.example.test", config: "https://config.example.test")
    static let device = DeviceInfo(id: "synthetic-device", name: "测试设备", model: "iPhone", os: "iOS 17.0", platform: "iOS", version: "Pre 0.1.1")
    static let profile = #"""
    {"id":7,"email":"member@example.test","user_name":"测试账户","class":2,
     "class_expire":"2099-01-01 00:00:00","expire_in":"2099-01-01 00:00:00",
     "upload":100,"download":300,"transfer_enable":1000,"last_day_t":150,
     "node_speedlimit":100,"node_connector":3,"online_client_count":1,"money":12.5,
     "traffic_reset":"每月重置","plan":null,"config_revision":"revision-1",
     "api_origin":"https://config.example.test","site_origin":"https://site.example.test"}
    """#
    static let catalog = #"""
    {"revision":"revision-1","config":{"proxies":[],"proxy-providers":{
      "ecy-panel-nodes":{"type":"file","payload":[{"name":"node-12","type":"ss","password":"discarded-secret"}]}}},
     "node_labels":{"node-12":"测试节点"}}
    """#
    static let options = #"{"reg_mode":"open","enable_change_email":true,"enable_kill":true,"enable_password_change_reset_subscription":false,"email_verify":true,"api_origin":"https://config.example.test","site_origin":"https://site.example.test"}"#
    static let login = #"{"token":"synthetic-token","expires_at":"2099-01-01T00:00:00+00:00","user":\#(profile)}"#

    static func status(_ enable: Int = 1) -> String {
        #"{"enable":\#(enable),"email":"member@example.test","deletion_time":null,"ban_reason":"合成原因","ban_time_text":null,"support_email":"support@example.test"}"#
    }

    static func response(_ json: String) -> HTTPResult {
        HTTPResult(data: Data(#"{"ret":1,"data":\#(json)}"#.utf8), status: 200)
    }

    static var stored: StoredSession {
        StoredSession(token: "synthetic-token", expiresAt: Date(timeIntervalSince1970: 4_070_908_800),
                      email: "member@example.test", userID: 7, endpoints: endpoints)
    }
}

private actor FakeTransport: HTTPTransport {
    struct Step: Sendable {
        let path: String
        let result: Result<HTTPResult, ClientError>
        var paused = false
    }

    private var steps: [Step]
    private var requests: [URLRequest] = []
    private var pending: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    init(_ steps: [Step]) { self.steps = steps }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        requests.append(request)
        guard !steps.isEmpty else {
            Issue.record("收到未预期的请求：\(request.url!.path)")
            throw ClientError.network
        }
        let step = steps.removeFirst()
        #expect(request.url!.path == "/api/client/v1\(step.path)")
        if step.paused {
            await withCheckedContinuation { continuation in
                pending = continuation
                observers.forEach { $0.resume() }
                observers.removeAll()
            }
        }
        return try step.result.get()
    }

    func waitUntilPaused() async {
        if pending != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func resume() { pending?.resume(); pending = nil }
    func recorded() -> [URLRequest] { requests }
}

@MainActor
private final class MemoryVault: CredentialVault {
    var logoutPending = false
    var endpoints: PanelEndpoints?
    var value: StoredSession?
    var remembered: RememberedLogin?
    func loadRemembered() throws -> RememberedLogin? { remembered }
    func saveRemembered(_ login: RememberedLogin) throws { remembered = login }
    func clearRemembered() throws { remembered = nil }
    var failSave = false
    var failClear = false
    func load() throws -> StoredSession? { value }
    func save(_ session: StoredSession) throws {
        if failSave { throw ClientError.keychain(-1) }
        value = session
    }
    func clear() throws {
        if failClear { throw ClientError.keychain(-1) }
        value = nil
    }
}

private func reply(_ path: String, _ json: String, paused: Bool = false) -> FakeTransport.Step {
    .init(path: path, result: .success(Fixture.response(json)), paused: paused)
}

private func failure(_ path: String, status: Int, code: Int = 0, retry: Int? = nil) -> FakeTransport.Step {
    .init(path: path, result: .success(HTTPResult(
        data: Data(#"{"ret":\#(code),"msg":"合成错误"}"#.utf8), status: status, retryAfter: retry
    )))
}

@MainActor
private func makeSession(_ transport: FakeTransport, vault: MemoryVault = MemoryVault()) -> ClientSession {
    ClientSession(endpoints: Fixture.endpoints, api: PanelAPI(device: Fixture.device, transport: transport), vault: vault)
}

@Suite("认证与账户隔离", .timeLimit(.minutes(1)))
@MainActor
struct ClientSessionTests {
    @Test func profileRevisionsArePerPageAndOptional() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let legacy = try decoder.decode(UserProfile.self, from: Data(Fixture.profile.utf8))
        #expect(legacy.revision(.shop) == nil && legacy.revision(.tickets) == nil)
        let json = Fixture.profile.replacingOccurrences(of: #""plan":null,"#, with: #""plan":null,"revisions":{"shop":"0a1b2c3d4e5f6071","tickets":"8192a3b4c5d6e7f8"},"#)
        let current = try decoder.decode(UserProfile.self, from: Data(json.utf8))
        #expect(current.revision(.shop) == "0a1b2c3d4e5f6071" && current.revision(.tickets) == "8192a3b4c5d6e7f8")
        #expect(current.revision(.invite) == nil && current.revision(.unlock) == nil)
    }

    @Test func optionsRetryDNSOnceThenRecover() async {
        let transport = FakeTransport([
            .init(path: "/auth/options", result: .failure(.networkFailure(URLError.cannotFindHost.rawValue))),
            reply("/auth/options", Fixture.options)
        ])
        let session = makeSession(transport)
        await session.start()
        #expect(session.options?.emailVerify == true && session.message == nil && !session.busy)
        #expect(await transport.recorded().count == 2)
    }

    @Test func missingOptionsRemainUnknownAndForegroundCanRecover() async {
        let lookup = FakeTransport.Step(path: "/auth/options", result: .failure(.networkFailure(URLError.cannotFindHost.rawValue)))
        let transport = FakeTransport([lookup, lookup, lookup, reply("/auth/options", Fixture.options)])
        let session = makeSession(transport)
        await session.start()
        #expect(session.options == nil && !session.busy && session.phase == .signedOut)
        #expect(session.message?.contains("-1003") == true)
        #expect(await transport.recorded().count == 3)
        await session.sendEmailCode(email: "member@example.test")
        #expect(session.message == "尚未获取站点登录选项，请先重试。")
        #expect(await transport.recorded().count == 3)
        await session.refresh()
        #expect(session.options?.emailVerify == true && session.message == nil)
        #expect(await transport.recorded().count == 4)
        await session.refresh()
        #expect(await transport.recorded().count == 4)
    }

    @Test func disabledEmailLoginDoesNotSendMailOrLogin() async {
        let disabled = Fixture.options.replacingOccurrences(of: "true", with: "false")
        let transport = FakeTransport([reply("/auth/options", disabled)])
        let session = makeSession(transport)
        await session.start()
        await session.sendEmailCode(email: "member@example.test")
        await session.login(email: "member@example.test", password: "", code: "123456", emailCode: true)
        #expect(session.options?.emailVerify == false)
        #expect(session.message == "站点未开启邮箱验证码登录。")
        #expect(await transport.recorded().count == 1)
    }

    @Test func sendingEmailCodeLeavesLoginIdle() async {
        let transport = FakeTransport([reply("/auth/options", Fixture.options), reply("/auth/send-login-verify", "{}", paused: true)])
        let session = makeSession(transport)
        await session.start()
        let sending = Task { await session.sendEmailCode(email: "member@example.test") }
        await transport.waitUntilPaused()
        #expect(session.sendingEmail && !session.busy)
        await transport.resume(); await sending.value
        #expect(!session.sendingEmail && !session.busy && session.emailCooldown(.login) > 0)
    }

    // 对应 panel_api_client.dart：连接未建立时服务端必然未收到，登录也最多重来 3 轮；已发出的请求超时不重发
    @Test func loginPostRetriesOnlyUnestablishedConnections() async {
        let lookup = FakeTransport.Step(path: "/auth/login", result: .failure(.networkFailure(URLError.cannotFindHost.rawValue)))
        let transport = FakeTransport([lookup, lookup, lookup, .init(path: "/auth/login", result: .failure(.networkFailure(URLError.timedOut.rawValue)))])
        let session = makeSession(transport)
        await session.restore()
        await session.login(email: "member@example.test", password: "synthetic-password")
        #expect(session.phase == .signedOut && !session.busy)
        #expect(await transport.recorded().count == 3)
        await session.login(email: "member@example.test", password: "synthetic-password")
        #expect(session.phase == .signedOut && !session.busy)
        #expect(await transport.recorded().count == 4)
    }

    @Test func loginUsesExistingContractAndRealNodePayload() async throws {
        let transport = FakeTransport([reply("/auth/options", Fixture.options), reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog)])
        let vault = MemoryVault()
        let session = makeSession(transport, vault: vault)
        await session.start()
        await session.login(email: " MEMBER@example.test ", password: "synthetic-password")
        #expect(session.phase == .signedIn)
        #expect(!session.busy)
        #expect(session.profile?.remaining == 600)
        #expect(session.profile?.todayUsed == 250)
        #expect(session.catalog?.nodes.first?.id == "node-12")
        #expect(session.catalog?.nodes.first?.name == "测试节点")
        #expect(vault.value?.userID == 7)
        let requests = await transport.recorded()
        let login = requests[1]
        let body = try #require(JSONSerialization.jsonObject(with: login.httpBody!) as? [String: String])
        #expect(body["email"] == "member@example.test")
        #expect(body["passwd"] == "synthetic-password")
        #expect(body["device_id"] == "synthetic-device")
        #expect(login.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(login.value(forHTTPHeaderField: "User-Agent") == "ECYCloud/Pre0.1.1 (iOS)")
        #expect(login.value(forHTTPHeaderField: "X-Device-Name")?.removingPercentEncoding == "测试设备")
        #expect(requests[2].url?.host == "config.example.test")
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
        #expect(requests[2].value(forHTTPHeaderField: "X-ECY-Node-Providers") == "1")
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-ECY-Connected") == nil })
    }

    @Test func twoFactorChallengeAndWrongCodeDoNotCreateSession() async {
        let transport = FakeTransport([
            failure("/auth/login", status: 401, code: 2), failure("/auth/login", status: 401),
            reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog)
        ])
        let vault = MemoryVault()
        let session = makeSession(transport, vault: vault)
        await session.restore()
        await session.login(email: "member@example.test", password: "synthetic-password", rememberPassword: true)
        #expect(session.phase == .signedOut && session.needsTwoFactor)
        #expect(vault.value == nil && vault.remembered == nil)
        await session.login(email: "member@example.test", password: "synthetic-password", code: "000000", rememberPassword: true)
        #expect(session.phase == .signedOut && session.needsTwoFactor && !session.busy && vault.remembered == nil)
        await session.login(email: "member@example.test", password: "synthetic-password", code: "123456", rememberPassword: true)
        #expect(session.phase == .signedIn && !session.needsTwoFactor)
        #expect(vault.remembered?.email == "member@example.test" && vault.remembered?.password == "synthetic-password")
    }

    @Test func rememberedPairSurvivesLogoutAndEmailCodeLoginDoesNotReplaceIt() async throws {
        let vault = MemoryVault()
        vault.remembered = RememberedLogin(email: "previous@example.test", password: "previous-password", site: Fixture.endpoints.site)
        let transport = FakeTransport([reply("/auth/options", Fixture.options), reply("/auth/login-with-verify-code", Fixture.login), reply("/config/clash", Fixture.catalog), reply("/auth/logout", "{}")])
        let session = makeSession(transport, vault: vault)
        await session.start()
        #expect(try session.loadRememberedLogin()?.email == "previous@example.test")
        await session.login(email: "member@example.test", password: "unused", code: "ABC123", emailCode: true, rememberPassword: false)
        #expect(vault.remembered?.email == "previous@example.test" && vault.remembered?.password == "previous-password")
        await session.logout()
        #expect(try session.loadRememberedLogin()?.email == "previous@example.test")
        try session.clearRememberedLogin()
        #expect(try session.loadRememberedLogin() == nil)
    }
    @Test(arguments: [false, true]) func pendingLoginCannotRestoreClearedRememberedPassword(logout: Bool) async throws {
        let vault = MemoryVault()
        let steps = [reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog, paused: true)] + (logout ? [reply("/auth/logout", "{}")] : [])
        let transport = FakeTransport(steps)
        let session = makeSession(transport, vault: vault)
        await session.restore()
        let work = Task { await session.login(email: "member@example.test", password: "synthetic-password", rememberPassword: true) }
        await transport.waitUntilPaused()
        if logout { await session.logout() } else { try session.clearRememberedLogin() }
        await transport.resume(); await work.value
        #expect(vault.remembered == nil)
    }
    @Test func rememberedLoginIsNotFilledForAnotherSite() async throws {
        let vault = MemoryVault()
        vault.remembered = RememberedLogin(email: "other@example.test", password: "synthetic-password", site: URL(string: "https://other.example.test")!)
        let session = makeSession(FakeTransport([]), vault: vault)
        await session.restore()
        #expect(try session.loadRememberedLogin() == nil)
    }

    @Test(arguments: [0, -1]) func restrictedLoginDoesNotRequestNodes(enable: Int) async {
        let login = #"{"token":"synthetic-token","expires_at":"2099-01-01T00:00:00Z","account_status":\#(Fixture.status(enable))}"#
        let transport = FakeTransport([reply("/auth/login", login)])
        let session = makeSession(transport)
        await session.restore()
        await session.login(email: "member@example.test", password: "synthetic-password")
        #expect(session.phase == .restricted)
        #expect(session.catalog == nil && session.profile == nil)
        #expect(await transport.recorded().count == 1)
    }

    @Test func emailLoginRespectsOptionsAndOmitsPassword() async throws {
        let transport = FakeTransport([
            reply("/auth/options", Fixture.options), reply("/auth/send-login-verify", "{}"),
            reply("/auth/login-with-verify-code", Fixture.login), reply("/config/clash", Fixture.catalog)
        ])
        let session = makeSession(transport)
        await session.restore()
        await session.login(email: "member@example.test", password: "", code: "ABC123", emailCode: true)
        #expect(await transport.recorded().isEmpty)
        await session.loadOptions()
        await session.sendEmailCode(email: "member@example.test")
        await session.login(email: "member@example.test", password: "unused", code: "ABC123", emailCode: true)
        let requests = await transport.recorded()
        let body = try #require(JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: String])
        #expect(body["passwd"] == nil && body["code"] == "ABC123")
        #expect(session.phase == .signedIn)
    }

    @Test func offlineRestoreKeepsCredentialForRetry() async {
        let transport = FakeTransport([
            .init(path: "/user/account-status", result: .failure(.network)),
            reply("/user/account-status", Fixture.status()), reply("/user/profile", Fixture.profile), reply("/config/clash", Fixture.catalog)
        ])
        let vault = MemoryVault()
        vault.value = Fixture.stored
        let session = makeSession(transport, vault: vault)
        await session.restore()
        #expect(session.phase == .signedIn && vault.value != nil)
        #expect(session.profile == nil && session.catalog == nil)
        await session.refresh()
        #expect(session.phase == .signedIn && session.profile?.id == 7 && session.catalog != nil)
    }

    @Test func unauthorizedRestoreRemovesSession() async {
        let transport = FakeTransport([failure("/user/account-status", status: 401)])
        let vault = MemoryVault()
        vault.value = Fixture.stored
        let session = makeSession(transport, vault: vault)
        await session.restore()
        #expect(session.phase == .signedOut && vault.value == nil && !session.busy)
    }

    @Test func expiredSessionNeverSendsToken() async {
        let transport = FakeTransport([])
        let vault = MemoryVault()
        vault.value = StoredSession(token: "expired", expiresAt: .distantPast, email: "member@example.test", userID: 7, endpoints: Fixture.endpoints)
        let session = makeSession(transport, vault: vault)
        await session.restore()
        #expect(vault.value == nil && session.phase == .signedOut)
        #expect(await transport.recorded().isEmpty)
    }

    @Test func lateNodesCannotRestoreDataAfterLogout() async {
        let transport = FakeTransport([
            reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog, paused: true), reply("/auth/logout", "{}")
        ])
        let vault = MemoryVault()
        let session = makeSession(transport, vault: vault)
        await session.restore()
        let task = Task { await session.login(email: "member@example.test", password: "synthetic-password") }
        await transport.waitUntilPaused()
        await session.logout()
        await transport.resume()
        await task.value
        #expect(session.phase == .signedOut && session.profile == nil && session.catalog == nil)
        #expect(vault.value == nil && !session.busy && !session.nodesLoading)
    }

    @Test func lateProfileCannotOverwriteNextAccount() async {
        let transport = FakeTransport([
            reply("/user/account-status", Fixture.status()), reply("/user/profile", Fixture.profile, paused: true),
            reply("/auth/logout", "{}"),
            reply("/auth/login", Fixture.login.replacingOccurrences(of: "member@example.test", with: "second@example.test").replacingOccurrences(of: #""id":7"#, with: #""id":8"#)),
            reply("/config/clash", Fixture.catalog)
        ])
        let vault = MemoryVault()
        vault.value = Fixture.stored
        let session = makeSession(transport, vault: vault)
        let task = Task { await session.restore() }
        await transport.waitUntilPaused()
        await session.logout()
        await session.login(email: "second@example.test", password: "synthetic-password")
        await transport.resume()
        await task.value
        #expect(session.profile?.id == 8 && vault.value?.email == "second@example.test")
    }

    @Test func offlineLogoutClearsLocalButDoesNotClaimRemoteRevocation() async {
        let transport = FakeTransport([
            reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog),
            .init(path: "/auth/logout", result: .failure(.network))
        ])
        let vault = MemoryVault()
        let session = makeSession(transport, vault: vault)
        await session.restore()
        await session.login(email: "member@example.test", password: "synthetic-password")
        await session.logout()
        #expect(vault.value == nil && session.phase == .signedOut)
        #expect(session.message?.contains("未能确认服务器会话撤销") == true)
    }

    @Test func keychainDeletionFailureCannotRestoreOldLogin() async {
        let vault = MemoryVault()
        vault.value = Fixture.stored
        vault.logoutPending = true
        vault.failClear = true
        let transport = FakeTransport([])
        let session = makeSession(transport, vault: vault)
        await session.restore()
        #expect(session.phase == .cleanupFailed && vault.logoutPending)
        await session.login(email: "member@example.test", password: "synthetic-password")
        #expect(await transport.recorded().isEmpty)
        vault.failClear = false
        await session.logout()
        #expect(session.phase == .signedOut && vault.value == nil && !vault.logoutPending)
    }

    @Test func keychainSaveFailureRevokesIssuedTokenAndKeepsLoggedOut() async {
        let transport = FakeTransport([reply("/auth/login", Fixture.login), reply("/auth/logout", "{}")])
        let vault = MemoryVault()
        vault.failSave = true
        let session = makeSession(transport, vault: vault)
        await session.restore()
        await session.login(email: "member@example.test", password: "synthetic-password")
        #expect(session.phase == .signedOut && vault.value == nil && session.profile == nil)
        #expect(await transport.recorded().count == 2)
    }

    @Test func malformedNodeRefreshPreservesPreviousCatalog() async {
        let transport = FakeTransport([
            reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog),
            reply("/config/clash", #"{"revision":"bad","config":{"proxies":"wrong"},"node_labels":[]}"#)
        ])
        let session = makeSession(transport)
        await session.restore()
        await session.login(email: "member@example.test", password: "synthetic-password")
        await session.loadNodes()
        #expect(session.catalog?.revision == "revision-1" && session.nodesError != nil)
        #expect(!session.nodesLoading && session.phase == .signedIn)
    }

    @Test func rateLimitPreventsImmediateResubmission() async {
        let transport = FakeTransport([failure("/auth/login", status: 429, retry: 30)])
        let session = makeSession(transport)
        await session.restore()
        await session.login(email: "member@example.test", password: "synthetic-password")
        await session.login(email: "member@example.test", password: "synthetic-password")
        #expect(await transport.recorded().count == 1)
        #expect(!session.busy && session.phase == .signedOut)
    }

    @Test func changedAccountIdentityIsRejectedOnRestore() async {
        let transport = FakeTransport([
            reply("/user/account-status", Fixture.status()),
            reply("/user/profile", Fixture.profile.replacingOccurrences(of: #""id":7"#, with: #""id":999"#))
        ])
        let vault = MemoryVault()
        vault.value = Fixture.stored
        let session = makeSession(transport, vault: vault)
        await session.restore()
        #expect(session.phase == .signedIn && session.profile == nil && session.catalog == nil)
    }

    @Test func refreshFetchesNodesOnlyWhenRevisionChanges() async {
        let next = Fixture.catalog.replacingOccurrences(of: "revision-1", with: "revision-2")
        let transport = FakeTransport([
            reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog),
            reply("/user/account-status", Fixture.status()), reply("/user/profile", Fixture.profile),
            reply("/user/account-status", Fixture.status()), reply("/user/profile", Fixture.profile.replacingOccurrences(of: "revision-1", with: "revision-2")),
            reply("/config/clash", next)
        ])
        let session = makeSession(transport)
        await session.restore()
        await session.login(email: "member@example.test", password: "synthetic-password")
        await session.refresh()
        #expect(session.catalog?.revision == "revision-1")
        #expect(await transport.recorded().filter { $0.url?.path.hasSuffix("/config/clash") == true }.count == 1)
        await session.refresh()
        #expect(session.catalog?.revision == "revision-2")
        #expect(await transport.recorded().count == 7)
    }

    @Test func refreshRestrictionClearsPreviouslyLoadedNodes() async {
        let transport = FakeTransport([
            reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog),
            reply("/user/account-status", Fixture.status(0))
        ])
        let session = makeSession(transport)
        await session.restore()
        await session.login(email: "member@example.test", password: "synthetic-password")
        await session.refresh()
        #expect(session.phase == .restricted && session.catalog == nil && session.profile == nil)
    }

    @Test func advertisedOriginsApplyToFollowingRequestsAndPersist() async {
        let options = Fixture.options.replacingOccurrences(of: "site.example.test", with: "next-site.example.test")
        let transport = FakeTransport([
            reply("/auth/options", options), reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog)
        ])
        let vault = MemoryVault()
        let session = makeSession(transport, vault: vault)
        await session.start()
        #expect(vault.endpoints?.site.host == "next-site.example.test")
        await session.login(email: "member@example.test", password: "synthetic-password")
        let requests = await transport.recorded()
        #expect(requests[1].url?.host == "next-site.example.test")
        #expect(vault.value?.endpoints == Fixture.endpoints)
    }

    @Test(arguments: [
        #"{"token":"","expires_at":"2099-01-01T00:00:00Z","user":\#(Fixture.profile)}"#,
        #"{"token":"synthetic-token","expires_at":"not-a-date","user":\#(Fixture.profile)}"#,
        #"{"token":"synthetic-token","expires_at":"2099-01-01T00:00:00Z"}"#,
        #"{"token":"synthetic-token","expires_at":"2000-01-01T00:00:00Z","user":\#(Fixture.profile)}"#
    ]) func malformedLoginCannotCreateSession(payload: String) async {
        let transport = FakeTransport([reply("/auth/login", payload)])
        let vault = MemoryVault()
        let session = makeSession(transport, vault: vault)
        await session.restore()
        await session.login(email: "member@example.test", password: "synthetic-password")
        #expect(session.phase == .signedOut && !session.busy && vault.value == nil)
    }
}

@Suite("响应结构与地址边界")
struct ParsingTests {
    @Test func keychainErrorsIdentifyPermissionFailureWithoutAssumingLockedDevice() {
        let missingPermission = ClientError.keychain(errSecMissingEntitlement).localizedDescription
        #expect(missingPermission.contains("缺少钥匙串访问权限"))
        #expect(missingPermission.contains(String(errSecMissingEntitlement)))
        #expect(!missingPermission.contains("解锁"))
        let unknown = ClientError.keychain(-1).localizedDescription
        #expect(unknown.contains("-1") && !unknown.contains("解锁"))
        #expect(ClientError.keychain(errSecInteractionNotAllowed).localizedDescription.contains("确认设备已解锁"))
    }

    private func decode(_ json: String) throws -> NodeCatalog {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(NodeCatalog.self, from: Data(json.utf8))
    }

    @Test func supportsLegacyNodesAndEmptyPHPMaps() throws {
        let legacy = try decode(#"{"revision":"old","config":{"proxies":[{"name":"node-1","type":"trojan"}]},"node_labels":[]}"#)
        #expect(legacy.nodes.first?.name == "node-1")
        let empty = try decode(#"{"revision":"empty","config":{"proxies":[]},"node_labels":[]}"#)
        #expect(empty.nodes.isEmpty)
    }

    @Test(arguments: [
        #"{"revision":"bad","config":{"proxies":[]},"node_labels":["bad"]}"#,
        #"{"revision":"bad","config":{"proxies":[{"name":"a","type":"ss"},{"name":"a","type":"ss"}]},"node_labels":{}}"#,
        #"{"revision":"bad","config":{"proxies":[{"name":"a"}]},"node_labels":{}}"#
    ]) func rejectsInvalidNodeData(json: String) {
        #expect(throws: (any Error).self) { try decode(json) }
    }

    @Test(arguments: ["http://example.test", "file:///tmp/test", "https://user:pass@example.test", "https://", "https://example.test:99999"])
    func rejectsUnsafeOrigins(origin: String) {
        #expect(throws: ClientError.configuration) { try PanelEndpoints(site: origin, config: "https://example.test") }
    }

    @Test func originsStripPathsAndQueries() throws {
        let result = try PanelEndpoints(site: "https://example.test/nested?token=bad#anchor", config: "https://config.example.test:8443/a")
        #expect(result.site.absoluteString == "https://example.test")
        #expect(result.config.absoluteString == "https://config.example.test:8443")
    }
}


@Suite("注册、恢复与公共文档", .timeLimit(.minutes(1)))
@MainActor
struct AuthWorkflowTests {
    @Test func registrationUsesExistingContractAndStoresSession() async throws {
        let transport = FakeTransport([reply("/auth/options", Fixture.options), reply("/auth/register", Fixture.login), reply("/config/clash", Fixture.catalog)])
        let vault = MemoryVault()
        let session = makeSession(transport, vault: vault)
        await session.start()
        await session.register(name: " 测试账户 ", email: " MEMBER@example.test ", password: "synthetic-password", confirmation: "synthetic-password", invite: " invitation ", emailCode: "123456", agreed: true)
        #expect(session.phase == .signedIn && vault.value?.userID == 7)
        let requests = await transport.recorded()
        let body = try #require(JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: String])
        #expect(body["name"] == "测试账户" && body["email"] == "member@example.test")
        #expect(body["passwd"] == body["repasswd"] && body["code"] == "invitation")
        #expect(body["emailcode"] == "123456" && body["device_id"] == "synthetic-device")
        #expect(requests[1].url?.host == "site.example.test")
    }

    @Test(arguments: ["close", "invite"])
    func closedRegistrationAndMissingInvitationDoNotSubmit(mode: String) async {
        let options = Fixture.options.replacingOccurrences(of: "open", with: mode)
        let transport = FakeTransport([reply("/auth/options", options)])
        let session = makeSession(transport)
        await session.start()
        await session.register(name: "测试", email: "member@example.test", password: "synthetic-password", confirmation: "synthetic-password", invite: "", emailCode: "123456", agreed: true)
        #expect(session.phase == .signedOut && session.message != nil)
        #expect(await transport.recorded().count == 1)
    }

    @Test func registrationRequiresAgreementAndVerification() async {
        let transport = FakeTransport([reply("/auth/options", Fixture.options)])
        let session = makeSession(transport)
        await session.start()
        await session.register(name: "测试", email: "member@example.test", password: "synthetic-password", confirmation: "synthetic-password", invite: "", emailCode: "123456", agreed: false)
        #expect(session.message == "请先同意服务条款与隐私政策")
        await session.register(name: "测试", email: "member@example.test", password: "synthetic-password", confirmation: "synthetic-password", invite: "", emailCode: "", agreed: true)
        #expect(session.message == "请填写邮箱验证码。")
        #expect(await transport.recorded().count == 1)
    }

    @Test func failedCredentialSaveRevokesNewRegistrationSession() async {
        let transport = FakeTransport([reply("/auth/options", Fixture.options), reply("/auth/register", Fixture.login), reply("/auth/logout", "{}")])
        let vault = MemoryVault()
        vault.failSave = true
        let session = makeSession(transport, vault: vault)
        await session.start()
        await session.register(name: "测试", email: "member@example.test", password: "synthetic-password", confirmation: "synthetic-password", invite: "", emailCode: "123456", agreed: true)
        #expect(session.phase == .signedOut && vault.value == nil)
        #expect(await transport.recorded().last?.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
    }

    @Test func resetAcceptsEmailLinkAndUsesPasswordField() async throws {
        let response = HTTPResult(data: Data(#"{"ret":1,"msg":"密码已重置","data":\#(Fixture.login)}"#.utf8), status: 200)
        let transport = FakeTransport([.init(path: "/auth/password-reset/confirm", result: .success(response)), reply("/config/clash", Fixture.catalog)])
        let session = makeSession(transport)
        await session.restore()
        await session.resetPassword(tokenInput: "https://site.example.test/password/token/synthetic-reset", password: "synthetic-password", confirmation: "synthetic-password")
        #expect(session.phase == .signedIn && session.message == "密码已重置")
        let requests = await transport.recorded()
        let body = try #require(JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: String])
        #expect(body["token"] == "synthetic-reset" && body["password"] == "synthetic-password")
        #expect(body["passwd"] == nil && body["repasswd"] == body["password"])
    }

    @Test func resetReplyAfterLogoutCannotRestoreAccount() async {
        let transport = FakeTransport([reply("/auth/password-reset/confirm", Fixture.login, paused: true)])
        let vault = MemoryVault()
        let session = makeSession(transport, vault: vault)
        await session.restore()
        let request = Task { await session.resetPassword(tokenInput: "synthetic-reset", password: "synthetic-password", confirmation: "synthetic-password") }
        await transport.waitUntilPaused()
        await session.logout()
        await transport.resume()
        await request.value
        #expect(session.phase == .signedOut && session.profile == nil && vault.value == nil)
    }

    @Test func emailCooldownIsPerPurposeAndFailureDoesNotStartIt() async {
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = FakeTransport([
            reply("/auth/options", Fixture.options), reply("/auth/send-register-verify", "{}"),
            failure("/auth/password-reset", status: 503), reply("/auth/password-reset", "{}"), reply("/auth/send-register-verify", "{}")
        ])
        let session = ClientSession(endpoints: Fixture.endpoints, api: PanelAPI(device: Fixture.device, transport: transport), vault: MemoryVault(), now: { instant })
        await session.start()
        #expect(await session.sendEmail(email: "member@example.test", purpose: .registration))
        #expect(session.emailCooldown(.registration) == 60)
        #expect(!(await session.sendEmail(email: "member@example.test", purpose: .registration)))
        #expect(!(await session.sendEmail(email: "member@example.test", purpose: .passwordReset)))
        #expect(session.emailCooldown(.passwordReset) == 0)
        #expect(await session.sendEmail(email: "member@example.test", purpose: .passwordReset))
        instant += 61
        #expect(await session.sendEmail(email: "member@example.test", purpose: .registration))
        #expect(await transport.recorded().count == 5)
    }

    @Test func sensitiveResetValuesAreRemovedFromServerMessages() async {
        let reply = HTTPResult(data: Data(#"{"ret":0,"msg":"synthetic-reset synthetic-password"}"#.utf8), status: 400)
        let transport = FakeTransport([.init(path: "/auth/password-reset/confirm", result: .success(reply))])
        let session = makeSession(transport)
        await session.restore()
        await session.resetPassword(tokenInput: "synthetic-reset", password: "synthetic-password", confirmation: "synthetic-password")
        #expect(session.message?.contains("synthetic-") == false && session.phase == .signedOut)
    }
}

@Suite("文档与恢复令牌解析")
struct AuthParsingTests {
    @Test(arguments: ["", "javascript:alert(1)/bad", "https://example.test/not-reset/token", "https://user:pass@example.test/password/token/test", "https://example.test/password/token/a/b", "token with spaces", "file:///password/token/test", "https://example.test/password/token/a%2Fb"])
    func invalidResetInputsAreRejected(input: String) {
        #expect(PasswordResetToken.fromInput(input) == nil)
    }

    @Test func acceptsRawAndLinkedResetTokens() {
        #expect(PasswordResetToken.fromInput("  synthetic-token  ") == "synthetic-token")
        #expect(PasswordResetToken.fromInput("https://example.test/password/token/synthetic-token?language=en-US") == "synthetic-token")
    }

    @Test func nativeDocumentKeepsTextAndSafeLinksWithoutActiveContent() throws {
        let document = try RichDocument(html: #"<h1>标题</h1><p>A &amp; B <strong>加粗</strong><em>斜体</em></p><ul><li>内容</li></ul><a href='/user?a=1&amp;b=2'>链接</a><script>unsafe-script</script><iframe>unsafe-frame</iframe><svg><text>unsafe-svg</text></svg><img src='https://external.example.test/pixel'>"#, origin: Fixture.endpoints.site)
        #expect(document.plainText.contains("A & B"))
        #expect(document.plainText.contains("• 内容") && !document.plainText.contains("unsafe"))
        #expect(document.runs.contains { $0.bold && $0.text == "加粗" })
        #expect(document.runs.contains { $0.italic && $0.text == "斜体" })
        #expect(document.runs.first { $0.text == "链接" }?.link?.absoluteString == "https://site.example.test/user?a=1&b=2")
    }

    @Test(arguments: ["javascript:alert(1)", "jav&#x61;script:alert(1)", "data:text/html,test", "file:///private/test", "https://user:pass@example.test", "java&#x0a;script:alert(1)"])
    func rejectsActiveAndCredentialBearingLinks(href: String) throws {
        let document = try RichDocument(html: "<a href='\(href)'>text</a>", origin: Fixture.endpoints.site)
        #expect(document.plainText == "text" && document.runs.allSatisfy { $0.link == nil })
    }

    @Test func rejectsOversizeDocumentsAndDoesNotResolveExternalEntities() throws {
        #expect(throws: ClientError.responseTooLarge) {
            try RichDocument(html: String(repeating: "a", count: 1_048_577), origin: Fixture.endpoints.site)
        }
        let document = try RichDocument(html: #"<!DOCTYPE html [<!ENTITY external SYSTEM 'file:///etc/hosts'>]><html><body>&external;</body></html>"#, origin: Fixture.endpoints.site)
        #expect(!document.plainText.contains("127.0.0.1") && !document.plainText.contains("localhost"))
    }
}

@Suite("账户记录与设备操作", .timeLimit(.minutes(1)))
@MainActor
struct AccountHistoryTests {
    private let devices = #"{"items":[{"ip":"192.0.2.1","location":"测试地点","datetime":"2026-10-20 10:00:00","device":"测试设备","app_version":"0.1.1","device_id":"synthetic-device","online":true}],"current_page":1,"last_page":1,"total":1,"per_page":10,"log_keep_days":30}"#

    @Test func deviceHistoryUsesWebsiteAndEncodesSearchAsOneQueryValue() async throws {
        let transport = FakeTransport([reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog), reply("/user/devices", devices)])
        let session = makeSession(transport)
        await session.restore()
        await session.login(email: "member@example.test", password: "synthetic-password")
        let result = try await session.history(.devices, page: 1, search: "设备 & page=999#value")
        #expect(result.total == 1 && result.keepDays == 30 && result.rows[0].online == true && result.rows[0].currentDevice)
        let request = try #require(await transport.recorded().last)
        #expect(request.url?.host == "site.example.test")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.count == 3 && query.first { $0.name == "search" }?.value == "设备 & page=999#value")
        #expect(query.first { $0.name == "page" }?.value == "1")
    }

    @Test func expiredCredentialClearsBeforeRecordsAreRequested() async {
        let transport = FakeTransport([reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog)])
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let vault = MemoryVault()
        let session = ClientSession(endpoints: Fixture.endpoints, api: PanelAPI(device: Fixture.device, transport: transport), vault: vault, now: { instant })
        await session.restore()
        await session.login(email: "member@example.test", password: "synthetic-password")
        instant = Date(timeIntervalSince1970: 5_000_000_000)
        do { _ = try await session.history(.devices, page: 1, search: ""); Issue.record("过期会话不应继续") }
        catch is CancellationError { }
        catch { Issue.record("错误类型不符") }
        #expect(session.phase == .signedOut && vault.value == nil && session.profile == nil)
        #expect(await transport.recorded().count == 2)
    }

    @Test func lateHistoryAfterLogoutIsDiscarded() async {
        let transport = FakeTransport([reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog), reply("/user/devices", devices, paused: true), reply("/auth/logout", "{}")])
        let session = makeSession(transport)
        await session.restore()
        await session.login(email: "member@example.test", password: "synthetic-password")
        let pending = Task { try await session.history(.devices, page: 1, search: "") }
        await transport.waitUntilPaused()
        await session.logout()
        await transport.resume()
        do { _ = try await pending.value; Issue.record("迟到记录不得返回界面") }
        catch is CancellationError { }
        catch { Issue.record("错误类型不符") }
        #expect(session.phase == .signedOut && session.message == nil)
    }

    @Test func expiryDuringRefreshClearsBusyAndDiscardsLateProfile() async {
        let transport = FakeTransport([
            reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog),
            reply("/user/account-status", Fixture.status(), paused: true)
        ])
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let vault = MemoryVault()
        let session = ClientSession(endpoints: Fixture.endpoints, api: PanelAPI(device: Fixture.device, transport: transport), vault: vault, now: { instant })
        await session.restore()
        await session.login(email: "member@example.test", password: "synthetic-password")
        let refresh = Task { await session.refresh() }
        await transport.waitUntilPaused()
        #expect(session.busy)
        instant = Date(timeIntervalSince1970: 5_000_000_000)
        do { _ = try await session.history(.devices, page: 1, search: ""); Issue.record("过期会话不应继续") }
        catch is CancellationError { }
        catch { Issue.record("错误类型不符") }
        await transport.resume()
        await refresh.value
        #expect(session.phase == .signedOut && !session.busy && session.profile == nil && vault.value == nil)
        #expect(await transport.recorded().count == 3)
    }

    @Test func deviceKickUsesOnlySelectedDeviceAndDoesNotRetry() async throws {
        let transport = FakeTransport([reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog), failure("/user/kick-device", status: 403)])
        let session = makeSession(transport)
        await session.restore()
        await session.login(email: "member@example.test", password: "synthetic-password")
        do { _ = try await session.kickDevice("synthetic-other-device"); Issue.record("拒绝结果不应成功") }
        catch { #expect((error as? ClientError) != nil) }
        let requests = await transport.recorded()
        #expect(requests.count == 3 && session.phase == .signedIn)
        let body = try #require(JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: String])
        #expect(body == ["device_id": "synthetic-other-device"])
    }

    @Test func malformedPaginationIsRejected() async {
        let malformed = devices.replacingOccurrences(of: #""current_page":1"#, with: #""current_page":0"#)
        let transport = FakeTransport([reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog), reply("/user/devices", malformed)])
        let session = makeSession(transport)
        await session.restore()
        await session.login(email: "member@example.test", password: "synthetic-password")
        do { _ = try await session.history(.devices, page: 1, search: ""); Issue.record("损坏分页不应被接受") }
        catch { #expect(error as? ClientError == .invalidResponse) }
    }

    @Test func deletedRecordsCanShrinkLastPageBelowRequestedPage() async throws {
        let response = #"{"items":[],"current_page":2,"last_page":1,"total":0,"per_page":10,"log_keep_days":30}"#
        let transport = FakeTransport([reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog), reply("/user/login-logs", response)])
        let session = makeSession(transport)
        await session.restore()
        await session.login(email: "member@example.test", password: "synthetic-password")
        let history = try await session.history(.loginLogs, page: 2, search: "")
        #expect(history.currentPage == 2 && history.lastPage == 1 && history.rows.isEmpty)
    }
}

@Suite("节点测试", .timeLimit(.minutes(1))) @MainActor
struct NodeProbeTests {
    @Test func signedInStandbyTestsWithoutReportingConnectedOrTakingDeviceSlot() async throws {
        let catalog = #"{"revision":"revision-1","config":{"proxies":[{"name":"node-12","type":"socks5","server":"127.0.0.1","port":9}],"proxy-groups":[{"name":"select","type":"select","proxies":["node-12"]}],"rules":["MATCH,select"]},"node_labels":{"node-12":"测试节点"}}"#
        let transport = FakeTransport([
            reply("/auth/login", Fixture.login), reply("/config/clash", catalog),
            reply("/user/account-status", Fixture.status()), reply("/user/profile", Fixture.profile.replacingOccurrences(of: "revision-1", with: "revision-2")),
            reply("/config/clash", catalog.replacingOccurrences(of: "revision-1", with: "revision-2"))
        ])
        let driver = RecordingTunnelDriver(); driver.supportsStandby = true
        let value = ClientSession(endpoints: Fixture.endpoints, api: PanelAPI(device: Fixture.device, transport: transport),
                                  vault: MemoryVault(), connection: ConnectionController(driver: driver), nodeProbes: NodeProbeState(defaults: nil))
        await value.restore()
        await value.login(email: "member@example.test", password: "synthetic-password")
        try await value.ensureControlPlane()
        #expect(value.connection?.controlPlaneReady == true && value.connection?.state == .disconnected)
        driver.controlResponses = [Data(#"{"running":false,"failed":false,"delay":45,"speed":0}"#.utf8)]
        let result = try await value.measureNode("node-12", kind: .delay)
        #expect(result.delay == 45 && driver.starts.isEmpty && driver.standbyStarts.count == 1)
        await value.refresh()
        while driver.standbyStarts.count < 2 || value.connection?.controlPlaneReady != true { await Task.yield() }
        #expect(driver.standbyStarts.count == 2 && driver.stopCount == 1 && value.connection?.controlPlaneReady == true)
        #expect(value.nodeProbes.result("node-12", kind: .delay)?.delay == 45)
        let requests = await transport.recorded()
        #expect(requests.filter { $0.url?.path.hasSuffix("/user/profile") == true }.allSatisfy {
            $0.value(forHTTPHeaderField: "X-ECY-Connected") == nil && $0.value(forHTTPHeaderField: "X-ECY-Node-Used") == nil
        })
        let profile = try #require(driver.standbyStarts.first?.configuration)
        let config = try #require(JSONSerialization.jsonObject(with: profile) as? [String: Any])
        #expect(config["mixed-port"] as? Int == 0 && config["external-controller"] as? String == "")
        #expect((config["tun"] as? [String: Any])?["enable"] as? Bool == false)
        value.connection?.disconnect()
        #expect(value.nodeProbes.values.isEmpty)
    }

    @Test func unchangedRevisionRefreshStillRestoresStandby() async throws {
        let catalog = #"{"revision":"revision-1","config":{"proxies":[{"name":"node-12","type":"socks5","server":"127.0.0.1","port":9}],"proxy-groups":[{"name":"select","type":"select","proxies":["node-12"]}],"rules":["MATCH,select"]},"node_labels":{"node-12":"测试节点"}}"#
        let transport = FakeTransport([
            reply("/auth/login", Fixture.login), reply("/config/clash", catalog),
            reply("/user/account-status", Fixture.status()), reply("/user/profile", Fixture.profile)
        ])
        let driver = RecordingTunnelDriver(); driver.supportsStandby = true
        let value = ClientSession(endpoints: Fixture.endpoints, api: PanelAPI(device: Fixture.device, transport: transport),
                                  vault: MemoryVault(), connection: ConnectionController(driver: driver), nodeProbes: NodeProbeState(defaults: nil))
        await value.restore()
        await value.login(email: "member@example.test", password: "synthetic-password")
        try await value.ensureControlPlane()
        let started = driver.standbyStarts.count
        value.connection?.disconnect()
        #expect(value.connection?.controlPlaneReady == false)
        await value.refresh()
        while driver.standbyStarts.count == started || value.connection?.controlPlaneReady != true { await Task.yield() }
        #expect(driver.standbyStarts.count == started + 1)
        #expect(await transport.recorded().filter { $0.url?.path.hasSuffix("/config/clash") == true }.count == 1)
        value.connection?.disconnect()
    }

    private func session(_ transport: FakeTransport, driver: RecordingTunnelDriver, probes: NodeProbeState? = nil) async -> ClientSession {
        let value = ClientSession(endpoints: Fixture.endpoints, api: PanelAPI(device: Fixture.device, transport: transport),
                                  vault: MemoryVault(), connection: ConnectionController(driver: driver), nodeProbes: probes ?? NodeProbeState(defaults: nil))
        await value.restore()
        await value.login(email: "member@example.test", password: "synthetic-password")
        driver.statusChanged?(.connected)
        return value
    }
    @Test func deniedQuotaNeverStartsProbe() async throws {
        let transport = FakeTransport([reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog),
            reply("/user/speed-test", #"{"allowed":[],"denied":[{"proxy_name":"node-12","msg":"合成额度已用完"}]}"#)])
        let driver = RecordingTunnelDriver()
        let value = await session(transport, driver: driver)
        await #expect(throws: ClientError.input("合成额度已用完")) { try await value.measureNode("node-12", kind: .speed) }
        #expect(driver.commands.isEmpty && value.nodeProbes.testing.isEmpty)
        let request = try #require(await transport.recorded().last)
        let body = try JSONDecoder().decode([String: [String]].self, from: #require(request.httpBody))
        #expect(body == ["proxy_names": ["node-12"]])
    }
    @Test func successReportsOnlyMeasuredNodeAndBytes() async throws {
        let allowance = #"{"allowed":["node-12"],"denied":[]}"#
        let transport = FakeTransport([reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog),
            reply("/user/speed-test", allowance), reply("/user/speed-test", allowance)])
        let driver = RecordingTunnelDriver()
        driver.controlResponses = [Data(#"{"running":true,"failed":false,"delay":0,"speed":0}"#.utf8),
                                   Data(#"{"running":false,"failed":false,"delay":0,"speed":900000}"#.utf8)]
        let value = await session(transport, driver: driver)
        let result = try await value.measureNode("node-12", kind: .speed)
        #expect(result.speed == 900000 && driver.commands.map(\.action) == [.probe, .probes])
        #expect(driver.commands.allSatisfy { $0.node == "node-12" && $0.scope == "speed" })
        #expect(value.nodeProbes.result("node-12", kind: .speed)?.speed == 900000 && value.nodeProbes.testing.isEmpty)
        let request = try #require(await transport.recorded().last)
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]])
        #expect(body["results"]?.count == 1 && body["results"]?.first?["proxy_name"] as? String == "node-12")
        #expect(body["results"]?.first?["bytes_per_second"] as? Int == 900000)
    }
    @Test func logoutDuringQuotaCheckCannotStartOrPublishOldProbe() async throws {
        let transport = FakeTransport([reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog),
            reply("/user/speed-test", #"{"allowed":["node-12"],"denied":[]}"#, paused: true), reply("/auth/logout", "{}")])
        let driver = RecordingTunnelDriver()
        let value = await session(transport, driver: driver)
        let task = Task { try await value.measureNode("node-12", kind: .speed) }
        await transport.waitUntilPaused()
        await value.logout()
        await transport.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(driver.commands.isEmpty && value.nodeProbes.values.isEmpty && value.nodeProbes.testing.isEmpty)
    }
    @Test func automaticGroupTestsResolvedMembersOnceBeforeReselecting() async throws {
        let transport = FakeTransport([reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog)])
        let driver = RecordingTunnelDriver()
        driver.controlResponses = [
            Data(#"{"running":false,"failed":true,"delay":0,"speed":0}"#.utf8),
            Data(#"{"running":false,"failed":false,"delay":45,"speed":0}"#.utf8),
            Data(#"{"running":false,"failed":false,"delay":0,"speed":0}"#.utf8)
        ]
        let value = await session(transport, driver: driver)
        let group = NodeSelectionGroup(id: "automatic", members: ["nested", "node-12", "node-13"], type: "url-test")
        _ = try await value.measureGroup(group, selections: ["nested": "node-12"], kind: .delay)
        #expect(driver.commands.filter { $0.scope == "delay" }.map(\.node).sorted() == ["node-12", "node-13"])
        #expect(driver.commands.last?.scope == "reselect" && driver.commands.last?.node == "automatic")
        #expect(value.nodeProbes.testing.isEmpty && value.nodeProbes.testingGroups.isEmpty)
    }
    @Test func concurrentGroupsShareEightDelaySlotsAndDoNotReselectManualGroups() async throws {
        let transport = FakeTransport([reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog)])
        let driver = RecordingTunnelDriver()
        driver.controlDelay = .milliseconds(20)
        driver.controlResponses = Array(repeating: Data(#"{"running":false,"failed":false,"delay":45,"speed":0}"#.utf8), count: 20)
        let value = await session(transport, driver: driver)
        let first = NodeSelectionGroup(id: "first", members: (1...12).map { "node-\($0)" }, type: "select")
        let second = NodeSelectionGroup(id: "second", members: (9...20).map { "node-\($0)" }, type: "select")
        async let a = value.measureGroup(first, selections: [:], kind: .delay)
        async let b = value.measureGroup(second, selections: [:], kind: .delay)
        _ = try await (a, b)
        #expect(driver.maximumActiveControls <= 8)
        #expect(Set(driver.commands.map(\.node)).count == 20)
        #expect(driver.commands.allSatisfy { $0.scope == "delay" })
        #expect(value.nodeProbes.testing.isEmpty && value.nodeProbes.testingGroups.isEmpty)
    }
    @Test func groupSpeedReservesOneBatchAndSkipsDeniedAndNonOfficialMembers() async throws {
        let transport = FakeTransport([reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog),
            reply("/user/speed-test", #"{"allowed":["node-12"],"denied":[{"proxy_name":"node-13","msg":"额度已用完"}]}"#),
            reply("/user/speed-test", #"{"allowed":["node-12"],"denied":[]}"#)])
        let driver = RecordingTunnelDriver()
        driver.controlResponses = [Data(#"{"running":false,"failed":false,"delay":0,"speed":900000}"#.utf8)]
        let value = await session(transport, driver: driver)
        let group = NodeSelectionGroup(id: "manual", members: ["nested", "node-12", "DIRECT", "node-13"], type: "select")
        let notice = try await value.measureGroup(group, selections: ["nested": "node-12"], kind: .speed)
        #expect(notice == "已跳过 1 个达到测速次数上限的节点")
        #expect(driver.commands.map(\.node) == ["node-12"])
        let calls = await transport.recorded().filter { $0.url?.path.hasSuffix("/speed-test") == true }
        #expect(calls.count == 2)
        let body = try JSONDecoder().decode([String: [String]].self, from: #require(calls.first?.httpBody))
        #expect(body == ["proxy_names": ["node-12", "node-13"]])
        #expect(value.nodeProbes.testing.isEmpty && value.nodeProbes.testingGroups.isEmpty)
    }
    @Test func disconnectDuringQuotaCheckCannotResumeAfterReconnection() async throws {
        let transport = FakeTransport([reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog),
            reply("/user/speed-test", #"{"allowed":["node-12"],"denied":[]}"#, paused: true)])
        let driver = RecordingTunnelDriver()
        let value = await session(transport, driver: driver)
        let task = Task { try await value.measureNode("node-12", kind: .speed) }
        await transport.waitUntilPaused()
        value.connection?.disconnect()
        driver.statusChanged?(.connected)
        await transport.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(driver.commands.isEmpty && value.nodeProbes.values.isEmpty && value.nodeProbes.testing.isEmpty)
    }
    @Test func unavailableReportDoesNotEraseMeasuredSpeed() async throws {
        let transport = FakeTransport([reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog),
            reply("/user/speed-test", #"{"allowed":["node-12"],"denied":[]}"#), failure("/user/speed-test", status: 503)])
        let driver = RecordingTunnelDriver()
        driver.controlResponses = [Data(#"{"running":false,"failed":false,"delay":0,"speed":900000}"#.utf8)]
        let value = await session(transport, driver: driver)
        for _ in 0..<4 { value.nodeProbes.recordSpeed("node-12") }
        let result = try await value.measureNode("node-12", kind: .speed)
        #expect(result.speed == 900000 && !result.failed)
        #expect(!value.nodeProbes.canTestSpeed("node-12"))
        await #expect(throws: ClientError.input("该节点 1 小时内测速已达 5 次，请稍后再试")) { try await value.measureNode("node-12", kind: .speed) }
        #expect(await transport.recorded().count == 4 && driver.commands.count == 1)
    }
    @Test func speedQuotaPersistsPerAccountAndExpires() {
        let suite = "ECYCloud.ProbeQuotaTest.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let probes = NodeProbeState(defaults: defaults, now: { instant })
        probes.configure(site: Fixture.endpoints.site, userID: 7)
        for _ in 0..<5 { probes.recordSpeed("node-12") }
        let restored = NodeProbeState(defaults: defaults, now: { instant })
        restored.configure(site: Fixture.endpoints.site, userID: 7)
        #expect(!restored.canTestSpeed("node-12"))
        restored.configure(site: Fixture.endpoints.site, userID: 8)
        #expect(restored.canTestSpeed("node-12"))
        restored.configure(site: Fixture.endpoints.site, userID: 7)
        #expect(!restored.canTestSpeed("node-12"))
        instant.addTimeInterval(3601)
        #expect(restored.canTestSpeed("node-12"))
        restored.exhaustSpeed("node-12", resetAt: instant.timeIntervalSince1970 + 10)
        #expect(!restored.canTestSpeed("node-12"))
        instant.addTimeInterval(11)
        #expect(restored.canTestSpeed("node-12"))
    }
    @Test func failedSpeedDoesNotConsumeLocalQuota() async throws {
        let transport = FakeTransport([reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog),
            reply("/user/speed-test", #"{"allowed":["node-12"],"denied":[]}"#)])
        let driver = RecordingTunnelDriver()
        driver.controlResponses = [Data(#"{"running":false,"failed":true,"delay":0,"speed":0}"#.utf8)]
        let value = await session(transport, driver: driver)
        for _ in 0..<4 { value.nodeProbes.recordSpeed("node-12") }
        await #expect(throws: ClientError.input("测速失败")) { try await value.measureNode("node-12", kind: .speed) }
        #expect(value.nodeProbes.canTestSpeed("node-12"))
        #expect(await transport.recorded().count == 3)
    }
    @Test func kernelControlFailuresStayOnTheirOwnView() async throws {
        let transport = FakeTransport([reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog)])
        let driver = RecordingTunnelDriver()
        let value = await session(transport, driver: driver)
        driver.controlFailure = .control
        await #expect(throws: TunnelError.control) { try await value.measureNode("node-12", kind: .delay) }
        await #expect(throws: TunnelError.control) { try await value.tunnelSnapshot() }
        await #expect(throws: TunnelError.control) { try await value.tunnelLogs() }
        #expect(value.message == nil && value.nodeProbes.result("node-12", kind: .delay)?.failed == true)
    }
}

@Suite("账户资料修改", .timeLimit(.minutes(1))) @MainActor
struct AccountEditTests {
    @Test func liveModePersistsOnlyAfterCoreAcceptsTheChange() async throws {
        let suite = "ECYCloud.ModeTest.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ClientPreferences(defaults: defaults)
        let transport = FakeTransport([reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog)])
        let driver = RecordingTunnelDriver()
        let connection = ConnectionController(driver: driver)
        let session = ClientSession(endpoints: Fixture.endpoints, api: PanelAPI(device: Fixture.device, transport: transport),
                                    vault: MemoryVault(), connection: connection, preferences: preferences)
        await session.restore()
        await session.login(email: "member@example.test", password: "synthetic-password")
        driver.statusChanged?(.connected)
        driver.controlFailure = .control
        await #expect(throws: TunnelError.control) { try await session.setMode(.direct) }
        #expect(preferences.mode == .rule)
        driver.controlFailure = nil
        try await session.setMode(.global)
        #expect(preferences.mode == .global && driver.commands.last?.mode == "global")
        #expect(connection.state == .connected && driver.starts.isEmpty)
        connection.disconnect()
        let count = driver.commands.count
        try await session.setMode(.direct)
        #expect(preferences.mode == .direct && driver.commands.count == count)
    }

    @Test func passwordSuccessClearsCredentialsAndStopsTunnel() async throws {
        let transport = FakeTransport([reply("/auth/options", Fixture.options), reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog), reply("/user/password", "{}")])
        let driver = RecordingTunnelDriver(), vault = MemoryVault()
        let session = ClientSession(endpoints: Fixture.endpoints, api: PanelAPI(device: Fixture.device, transport: transport), vault: vault, connection: ConnectionController(driver: driver))
        await session.start()
        await session.login(email: "member@example.test", password: "synthetic-login")
        let stops = driver.stopCount
        try await session.updatePassword(old: "synthetic-old", password: "synthetic-new", confirmation: "synthetic-new")
        #expect(session.phase == .signedOut && session.profile == nil && session.catalog == nil && vault.value == nil && !session.busy)
        #expect(driver.stopCount == stops + 1)
        let request = try #require(await transport.recorded().last)
        let body = try JSONDecoder().decode([String: String].self, from: #require(request.httpBody))
        #expect(body == ["oldpwd": "synthetic-old", "pwd": "synthetic-new", "repwd": "synthetic-new"])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
    }
    @Test func passwordFailureKeepsSessionAndRedactsBeforeTruncation() async throws {
        let secret = String(repeating: "synthetic-long-password-", count: 30)
        let errorBody = try JSONSerialization.data(withJSONObject: ["ret": 0, "msg": "failure " + secret])
        let transport = FakeTransport([reply("/auth/options", Fixture.options), reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog), .init(path: "/user/password", result: .success(HTTPResult(data: errorBody, status: 200)))])
        let session = makeSession(transport)
        await session.start()
        await session.login(email: "member@example.test", password: "synthetic-login")
        do { try await session.updatePassword(old: secret, password: "synthetic-new", confirmation: "synthetic-new"); Issue.record("未拒绝密码修改") }
        catch { #expect(error.localizedDescription == "failure [已隐藏]") }
        #expect(session.phase == .signedIn && !session.busy)
    }
    @Test func usernameUsesServerProfileAndRejectsInvalidLocalInput() async throws {
        let updated = Fixture.profile.replacingOccurrences(of: "测试账户", with: "新用户名")
        let transport = FakeTransport([reply("/auth/options", Fixture.options), reply("/auth/login", Fixture.login), reply("/config/clash", Fixture.catalog), reply("/user/username", "{}"), reply("/user/profile", updated)])
        let session = makeSession(transport)
        await session.start(); await session.login(email: "member@example.test", password: "synthetic-login")
        do { _ = try await session.updateUsername("1234"); Issue.record("接受了纯数字用户名") } catch { }
        _ = try await session.updateUsername(" 新用户名 ")
        #expect(session.profile?.userName == "新用户名" && !session.busy)
        let request = await transport.recorded()[3]
        let body = try JSONDecoder().decode([String: String].self, from: #require(request.httpBody))
        #expect(body == ["newusername": "新用户名"])
    }
}

@Suite("原生业务契约与会话边界", .timeLimit(.minutes(1)))
@MainActor
struct BusinessSessionTests {
    private func restored(_ steps: [FakeTransport.Step]) async -> (ClientSession, FakeTransport) {
        let vault = MemoryVault(); vault.value = Fixture.stored
        let transport = FakeTransport([reply("/user/account-status", Fixture.status()), reply("/user/profile", Fixture.profile), reply("/config/clash", Fixture.catalog)] + steps)
        let session = makeSession(transport, vault: vault); await session.start()
        #expect(session.phase == .signedIn)
        return (session, transport)
    }
    @Test func strategySavesOnlyTheSelectedSectionAndPreservesExplicitClears() async throws {
        let (session, transport) = await restored([
            reply("/user/subscription-config", "{}"), reply("/config/clash", Fixture.catalog),
            reply("/user/subscription-config", "{}"), reply("/config/clash", Fixture.catalog),
            reply("/user/subscription-config", "{}"), reply("/config/clash", Fixture.catalog)
        ])
        _ = try await session.saveSubscriptionStrategy(disabled: ["synthetic-group"])
        _ = try await session.saveSubscriptionStrategy(hosts: "", rules: "DOMAIN,example.test,DIRECT")
        _ = try await session.saveSubscriptionStrategy(providers: [])
        let requests = await transport.recorded()
        let bodies = try [3, 5, 7].map { try JSONDecoder().decode([String: String].self, from: #require(requests[$0].httpBody)) }
        #expect(bodies[0] == ["disabled_groups": "[\"synthetic-group\"]"])
        #expect(bodies[1] == ["custom_hosts": "", "custom_rules": "DOMAIN,example.test,DIRECT"])
        #expect(bodies[2] == ["custom_rule_providers": "[]"])
        #expect(requests[3].value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
    }
    @Test func lateStrategySaveCannotRefreshNodesAfterLogout() async throws {
        let (session, transport) = await restored([
            reply("/user/subscription-config", "{}", paused: true), reply("/auth/logout", "{}")
        ])
        let work = Task { try await session.saveSubscriptionStrategy(disabled: []) }
        await transport.waitUntilPaused(); await session.logout(); await transport.resume()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(await transport.recorded().count == 5)
        #expect(session.catalog == nil)
    }
    @Test func ticketTextIsEscapedBeforeSubmitting() async throws {
        let (session, transport) = await restored([reply("/tickets", #"{"ticket_id":42}"#)])
        let id = try await session.createTicket(title: "Synthetic <title>", text: "<script>alert('x')</script>\n&文字")
        #expect(id == 42)
        let request = try #require(await transport.recorded().last)
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
        #expect(body["title"] == "Synthetic <title>")
        #expect(body["content"] == "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;<br>&amp;文字")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
    }
    @Test func ticketLengthAndWhitespaceAreRejectedWithoutRequest() async throws {
        let (session, transport) = await restored([])
        for text in ["  \n", String(repeating: "字", count: 1001)] {
            await #expect(throws: ClientError.self) { try await session.createTicket(title: "test", text: text) }
        }
        #expect(await transport.recorded().count == 3)
    }
    @Test func restrictedAccountCanReadItsTicketsButCannotPurchase() async throws {
        let vault = MemoryVault(); vault.value = Fixture.stored
        let transport = FakeTransport([reply("/user/account-status", Fixture.status(0)), reply("/tickets", #"{"tickets":[],"banned":false,"enable_ticket":true,"current_page":1,"last_page":1,"total":0,"per_page":10}"#)])
        let session = makeSession(transport, vault: vault); await session.start()
        let tickets = try await session.tickets(page: 1, search: "")
        #expect(tickets.total == 0)
        await #expect(throws: CancellationError.self) { try await session.shop() }
        #expect(await transport.recorded().count == 2)
    }
    @Test func staleAnnouncementResponseIsDiscardedOnLogout() async throws {
        let (session, transport) = await restored([reply("/announcements", #"{"announcements":[],"popup":null}"#, paused: true), reply("/auth/logout", "{}")])
        let task = Task { try await session.announcements() }
        await transport.waitUntilPaused(); await session.logout(); await transport.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(session.phase == .signedOut)
    }
    @Test func emailSuccessClearsSessionAndFailureKeepsIt() async throws {
        let (session, _) = await restored([failure("/user/email", status: 400), reply("/user/email", "{}")])
        await #expect(throws: ClientError.self) { try await session.updateEmail("next@example.test", oldCode: "123456", newCode: "654321") }
        #expect(session.phase == .signedIn)
        try await session.updateEmail("next@example.test", oldCode: "123456", newCode: "654321")
        #expect(session.phase == .signedOut); #expect(session.profile == nil); #expect(session.catalog == nil)
    }
    @Test func twoFactorCheckFailureNeverEnablesFactor() async throws {
        let (session, transport) = await restored([failure("/user/ga-check", status: 200)])
        await #expect(throws: ClientError.self) { try await session.enableTwoFactor(code: "123456") }
        #expect(await transport.recorded().count == 4)
    }
    @Test func twoFactorEnableChecksPossessionFirst() async throws {
        let (session, transport) = await restored([reply("/user/ga-check", "{}"), reply("/user/ga-set", "{}")])
        _ = try await session.enableTwoFactor(code: "123456")
        let requests = await transport.recorded()
        let body = try #require(JSONSerialization.jsonObject(with: requests.last!.httpBody!) as? [String: String])
        #expect(body == ["enable": "1"])
    }
    @Test func failedEmailSendDoesNotStartCooldownAndSuccessDoes() async throws {
        let (session, transport) = await restored([failure("/user/send-old-email-verify", status: 400), reply("/user/send-old-email-verify", "{}")])
        await #expect(throws: ClientError.self) { try await session.sendAccountEmail(.oldEmail) }
        #expect(session.accountEmailCooldown(.oldEmail) == 0)
        _ = try await session.sendAccountEmail(.oldEmail)
        #expect(session.accountEmailCooldown(.oldEmail) > 0)
        await #expect(throws: ClientError.self) { try await session.sendAccountEmail(.oldEmail) }
        #expect(await transport.recorded().count == 5)
    }
    @Test func paymentPendingIsNeverReportedPaid() async throws {
        let (session, _) = await restored([reply("/shop/payment-status", #"{"paid":false,"total":12.5,"card_key":""}"#)])
        #expect(try await session.paymentStatus("2026102000001").paid == false)
        await #expect(throws: ClientError.self) { try await session.paymentStatus("../another-user") }
    }
    @Test func noAutomaticRetryForRechargeAfterNetworkFailure() async throws {
        let (session, transport) = await restored([.init(path: "/user/recharge/epay", result: .failure(.networkFailure(URLError.networkConnectionLost.rawValue)))])
        await #expect(throws: ClientError.self) { try await session.recharge(amount: "12.50", payment: "alipay") }
        #expect(await transport.recorded().count == 4)
    }
    @Test func nestedWithdrawalAccountIsJSONAndResetUsesPUT() async throws {
        let (session, transport) = await restored([reply("/user/withdraw/apply", "{}"), reply("/user/invite", "{}")])
        _ = try await session.withdraw(amount: "10.25", channel: "3", account: ["账号": "synthetic"], save: true)
        _ = try await session.resetInvite()
        let requests = await transport.recorded()
        let body = try #require(JSONSerialization.jsonObject(with: requests[3].httpBody!) as? [String: Any])
        #expect(body["account_info"] as? [String: String] == ["账号": "synthetic"])
        #expect(body["save_account"] as? Bool == true)
        #expect(body["amount"] as? String == "10.25")
        #expect(requests.last?.httpMethod == "PUT")
    }
    @Test func inviteRecordListsKeepSeparateSearches() async throws {
        let (session, transport) = await restored([reply("/user/invite", "{}")])
        _ = try? await session.invite(invitedPage: 1, invitedSearch: "a", paybackPage: 2, paybackSearch: "b", withdrawPage: 3, withdrawSearch: "c")
        let url = try #require(await transport.recorded().last?.url)
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["invited_search"] == "a" && items["payback_search"] == "b" && items["withdraw_search"] == "c")
        #expect(items["payback_page"] == "2" && items["withdraw_page"] == "3")
    }
    @Test func malformedPaginationIsRejected() async throws {
        let (session, _) = await restored([reply("/tickets", #"{"tickets":[],"banned":false,"enable_ticket":true,"current_page":0,"last_page":0,"total":-1,"per_page":10}"#)])
        await #expect(throws: ClientError.self) { try await session.tickets(page: 1, search: "") }
    }
    @Test func additionalVerificationCodesAreRedacted() async throws {
        let transport = FakeTransport([.init(path: "/user/email", result: .success(HTTPResult(data: Data(#"{"ret":0,"msg":"123456 654321 synthetic-token"}"#.utf8), status: 400)))])
        let api = PanelAPI(device: Fixture.device, transport: transport)
        do {
            _ = try await api.perform("/user/email", origin: Fixture.endpoints.site, token: "synthetic-token", body: ["old_emailcode": "123456", "new_emailcode": "654321"])
            Issue.record("应拒绝失败响应")
        } catch let error as ClientError {
            #expect(!error.localizedDescription.contains("123456")); #expect(!error.localizedDescription.contains("654321")); #expect(!error.localizedDescription.contains("synthetic-token"))
        }
    }
}

@Suite("业务响应解析")
struct BusinessModelTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: Data(json.utf8))
    }
    @Test func emptyPHPMapsAndMalformedMaps() throws {
        let prefix = #""total_upload":"0B","total_download":"0B","total_usage":"0B","total_rate_info":"无","log_keep_days":30"#
        let empty = try decode(TrafficHistory.self, "{\(prefix),\"traffic\":[],\"node_traffic\":[]}")
        #expect(empty.traffic.isEmpty && empty.nodeTraffic.isEmpty)
        #expect(throws: (any Error).self) { try decode(TrafficHistory.self, "{\(prefix),\"traffic\":[1],\"node_traffic\":[]}") }
    }
    @Test func quoteSupportsCooldownAndServerAmounts() throws {
        let cooldown = try decode(ShopQuote.self, #"{"plan_cooldown":true,"plan_cooldown_msg":"稍后重试","plan_cooldown_remaining":60}"#)
        #expect(!cooldown.canPurchase)
        let quote = try decode(ShopQuote.self, #"{"total":"1,200.50","hasValidOrder":1,"couponApplied":true,"couponMsg":"已应用","credit":10,"remaining_value":"200.00","refund_amount":"1.00","has_refund":true}"#)
        #expect(quote.canPurchase && quote.hasValidOrder == 1 && quote.couponApplied == true)
        #expect(quote.remainingValue == "200.00" && quote.refundAmount == "1.00" && quote.hasRefund == true)
    }
    @Test func moneyAndExternalLinksRejectUnsafeValues() {
        #expect(MoneyInput.amount("1,200.50") == Decimal(string: "1200.50"))
        for text in ["NaN", "-1", "1.001", "1e3", "1,2", ""] { #expect(MoneyInput.amount(text) == nil) }
        for text in ["javascript:alert(1)", "file:///etc/passwd", "https://user:secret@example.test", "https://example.test\n/", "https:"] { #expect(ClientLink.external(text) == nil) }
        #expect(ClientLink.external("weixin://wxpay/synthetic") != nil)
    }
    @Test func subscriptionDraftEncodingPreservesMihomoFieldsAndOmitsLocalID() throws {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(CustomProxyGroup(name: "synthetic", includeNodes: true, proxies: ["DIRECT"]))
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["id"] == nil); #expect(body["include_nodes"] as? Bool == true); #expect(body["proxies"] as? [String] == ["DIRECT"])
    }
}

extension BusinessSessionTests {
    @Test func directAttachmentOnlyReceivesScopedUploadToken() async throws {
        let grant = #"{"direct":1,"upload_url":"https://files.example.test/api/client/v1/upload","token":"scoped-upload-token","url":"https://files.example.test/file.jpg","originalName":"file.jpg","kind":"image"}"#
        let (session, transport) = await restored([reply("/tickets/upload", grant), reply("/upload", "{}")])
        let attachment = try await session.uploadTicketAttachment(data: Data([1, 2, 3]), name: "file.jpg")
        #expect(attachment.url == "https://files.example.test/file.jpg")
        let upload = try #require(await transport.recorded().last)
        #expect(upload.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(upload.value(forHTTPHeaderField: "X-Files-Token") == "scoped-upload-token")
        #expect(upload.value(forHTTPHeaderField: "X-Device-Name") == nil)
        #expect(upload.httpBody == Data([1, 2, 3]) && upload.httpMethod == "POST")
    }
    @Test func directAttachmentRejectsInsecureURLBeforeSendingToken() async throws {
        let grant = #"{"direct":1,"upload_url":"http://files.example.test/api/client/v1/upload","token":"scoped-upload-token","url":"https://files.example.test/file.jpg","originalName":"file.jpg","kind":"image"}"#
        let (session, transport) = await restored([reply("/tickets/upload", grant)])
        await #expect(throws: ClientError.self) { try await session.uploadTicketAttachment(data: Data([1]), name: "file.jpg") }
        #expect(await transport.recorded().count == 4)
    }
    @Test func multipartUploadUsesAuthenticatedPanelAndEscapesFilename() async throws {
        let (session, transport) = await restored([reply("/tickets/upload", #"{"direct":0}"#), reply("/tickets/upload", #"{"url":"/upload/file.txt","originalName":"file.txt","kind":"file"}"#)])
        let result = try await session.uploadTicketAttachment(data: Data("synthetic-content".utf8), name: "quote\".txt")
        #expect(result.url == "https://site.example.test/upload/file.txt")
        let request = try #require(await transport.recorded().last)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data;") == true)
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(body.contains("filename=\"quote_.txt\"") && body.contains("synthetic-content"))
    }
    @Test func lateAttachmentResultAfterLogoutIsDiscarded() async throws {
        let (session, transport) = await restored([reply("/tickets/upload", #"{"direct":0}"#), reply("/tickets/upload", #"{"url":"/upload/file.txt","originalName":"file.txt","kind":"file"}"#, paused: true), reply("/auth/logout", "{}")])
        let work = Task { try await session.uploadTicketAttachment(data: Data([1]), name: "file.txt") }
        await transport.waitUntilPaused(); await session.logout(); await transport.resume()
        await #expect(throws: CancellationError.self) { try await work.value }
    }
    @Test func phpEmptyPurchaseResultSucceedsButNonemptyArrayFails() async throws {
        let transport = FakeTransport([reply("/shop/buy-traffic-package", "[]"), reply("/shop/buy-traffic-package", "[1]")])
        let api = PanelAPI(device: Fixture.device, transport: transport)
        let result = try await api.purchase(Fixture.endpoints, token: "synthetic-token", path: "/shop/buy-traffic-package", body: ["shop": "1"])
        #expect(!result.needsPayment)
        await #expect(throws: ClientError.self) { try await api.purchase(Fixture.endpoints, token: "synthetic-token", path: "/shop/buy-traffic-package", body: ["shop": "1"]) }
    }
    @Test func profileReportsConnectionOnlyWhenActuallyConnected() async throws {
        let transport = FakeTransport([reply("/user/profile", Fixture.profile), reply("/user/profile", Fixture.profile)])
        let api = PanelAPI(device: Fixture.device, transport: transport)
        _ = try await api.profile(Fixture.endpoints, token: "synthetic-token", connected: false)
        _ = try await api.profile(Fixture.endpoints, token: "synthetic-token", connected: true)
        let requests = await transport.recorded()
        #expect(requests[0].value(forHTTPHeaderField: "X-ECY-Connected") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "X-ECY-Connected") == "1")
        #expect(requests[1].value(forHTTPHeaderField: "X-ECY-Node-Used") == "1")
    }
    @Test func deviceNoticeStopsExistingConnectionWithoutAutomaticAcknowledgement() async {
        let kicked = Fixture.profile.replacingOccurrences(of: #""online_client_count":1"#, with: #""online_client_count":3,"online_client_self":false,"device_kick_notice":true,"device_kick_reason":"remove""#)
        let transport = FakeTransport([reply("/user/account-status", Fixture.status()), reply("/user/profile", Fixture.profile), reply("/config/clash", Fixture.catalog), reply("/user/account-status", Fixture.status()), reply("/user/profile", kicked)])
        let vault = MemoryVault(); vault.value = Fixture.stored
        let driver = RecordingTunnelDriver()
        let tracked = ConnectionController(driver: driver)
        let session = ClientSession(endpoints: Fixture.endpoints, api: PanelAPI(device: Fixture.device, transport: transport), vault: vault, connection: tracked)
        await session.start(); driver.statusChanged?(.connected)
        let previous = driver.stopCount
        await session.refresh()
        #expect(tracked.state == .disconnected && driver.stopCount > previous)
        #expect(session.profile?.deviceKickNotice == true && session.needsDeviceSlot)
        #expect(await transport.recorded().count == 5)
    }
    @Test func failedCheckinCannotChangeQuota() async throws {
        let increased = Fixture.profile.replacingOccurrences(of: #""transfer_enable":1000"#, with: #""transfer_enable":2048"#)
        let (session, _) = await restored([failure("/user/checkin", status: 400), reply("/user/checkin", increased)])
        await #expect(throws: ClientError.self) { try await session.checkin() }
        #expect(session.profile?.transferEnable == 1000)
        _ = try await session.checkin()
        #expect(session.profile?.transferEnable == 2048)
    }
}
extension BusinessModelTests {
    @Test func attachmentLimitsAndHTMLCannotIntroduceActiveMarkup() throws {
        for name in ["../file.txt", "file\n.txt", "file.exe", "file\\name.txt"] {
            #expect(throws: ClientError.self) { try TicketUpload.validate(name: name, size: 1) }
        }
        #expect(throws: ClientError.self) { try TicketUpload.validate(name: "file.zip", size: TicketUpload.maximumBytes + 1) }
        let content = try TicketContent.html("", attachments: [.init(url: "https://files.example.test/a?x=1&y=2", originalName: "<script>.txt", kind: "file")])
        #expect(!content.contains("<script>") && content.contains("&amp;y=2"))
        #expect(throws: ClientError.self) { try TicketContent.html("", attachments: [.init(url: "javascript:alert(1)", originalName: "x", kind: "file")]) }
        #expect(throws: ClientError.self) { try TicketContent.html(String(repeating: "字", count: 1000), attachments: [.init(url: "https://example.test/file.txt", originalName: "file.txt", kind: "file")]) }
    }
    @Test func ticketAttachmentsUseMediaTagsByKind() throws {
        let content = try TicketContent.html("a\nb", attachments: [
            .init(url: "https://files.example.test/p.png", originalName: "p\".png", kind: "image"),
            .init(url: "https://files.example.test/v.mp4", originalName: "v.mp4", kind: "video"),
            .init(url: "https://files.example.test/l.log", originalName: "l.log", kind: "file")])
        #expect(content == #"a<br>b<p><img src="https://files.example.test/p.png" alt="p&quot;.png"></p><p><video src="https://files.example.test/v.mp4" controls></video></p><p><a href="https://files.example.test/l.log">l.log</a></p>"#)
    }
    @Test func ticketMessageNameFallsBackWhenMissing() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let messages = try decoder.decode([TicketDetail.Message].self, from: Data(#"[{"id":1,"is_admin":true,"user_name":" ","content":"","datetime":""},{"id":2,"is_admin":false,"content":"","datetime":""}]"#.utf8))
        #expect(messages.map(\.userName) == [L10n.t("管理员"), L10n.t("我")])
    }
    @MainActor @Test func announcementBrowserOpensNewestUnreadThenNewest() {
        let suite = "announcement-open-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let state = AnnouncementState(defaults: defaults)
        state.configure(site: URL(string: "https://site.example.test"), userID: 7)
        let items = [Announcement(id: 1, title: "", date: "2026-03-01", updatedAt: "2026-03-01 00:00:00", content: ""),
                     Announcement(id: 2, title: "", date: "2026-01-01", updatedAt: "2026-01-01 08:00:00", content: ""),
                     Announcement(id: 3, title: "", date: "2026-02-01", updatedAt: "2026-02-01T08:00:00Z", content: "")]
        state.accept(AnnouncementBundle(announcements: items, popup: nil))
        #expect(state.openIndex(items) == 2)
        state.markAllSeen()
        #expect(state.openIndex(items) == 2)
        #expect(state.openIndex([items[0]]) == 0)
    }
    @Test func richMediaBecomesSafeLinksWithoutLoadingResources() throws {
        let html = #"<img src='/image.jpg' alt='图片'><video><source src='https://files.example.test/movie.mp4'></video><img src='javascript:alert(1)'><a href='file:///secret'>禁止本地链接</a>"#
        let document = try RichDocument(html: html, origin: URL(string: "https://site.example.test")!)
        #expect(document.runs.compactMap(\.link).map(\.absoluteString) == ["https://site.example.test/image.jpg", "https://files.example.test/movie.mp4"])
    }
}

@MainActor @Suite struct AnnouncementTests {
    private func bundle(_ revision: String = "2026-01-01", popup: Int = 2) throws -> AnnouncementBundle {
        let data = Data("""
        {"announcements":[{"id":1,"title":"固定公告","date":"","updated_at":"fixed","content":""},{"id":2,"title":"新公告","date":"2026-01-01","updated_at":"\(revision)","content":"正文"}],"popup":{"id":\(popup),"title":"公告","date":"","updated_at":"\(revision)","content":"正文"}}
        """.utf8)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(AnnouncementBundle.self, from: data)
    }
    @Test func revisionChangesBecomeUnreadAndFixedNoticeDoesNot() throws {
        let suite = "ECYCloudTests.announcements.\(UUID())", site = Fixture.endpoints.site
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let state = AnnouncementState(defaults: defaults)
        state.configure(site: site, userID: 7); state.accept(try bundle())
        #expect(state.hasUnread)
        state.markSeen(try bundle().announcements[1]); #expect(!state.hasUnread)
        state.accept(try bundle("2026-01-02")); #expect(state.hasUnread)
        state.markAllSeen(); #expect(!state.hasUnread)
        let restored = AnnouncementState(defaults: defaults)
        restored.configure(site: site, userID: 7); restored.accept(try bundle("2026-01-02"))
        #expect(!restored.hasUnread)
    }
    @Test func popupOnlyAcknowledgementPersistsAndChangesShowAgain() throws {
        let suite = "ECYCloudTests.announcements.\(UUID())", site = Fixture.endpoints.site
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let state = AnnouncementState(defaults: defaults)
        state.configure(site: site, userID: 7); state.accept(try bundle())
        #expect(state.takePopup() != nil); #expect(state.takePopup() == nil)
        state.configure(site: nil, userID: nil); state.configure(site: site, userID: 7); state.accept(try bundle())
        let popup = try #require(state.takePopup()); state.dismissPopup(popup)
        state.configure(site: nil, userID: nil); state.configure(site: site, userID: 7); state.accept(try bundle())
        #expect(state.takePopup() == nil)
        state.accept(try bundle("2026-01-02")); #expect(state.takePopup() != nil)
    }
    @Test func accountAndSiteChangesCannotReuseAnotherAccountsState() throws {
        let suite = "ECYCloudTests.announcements.\(UUID())", site = Fixture.endpoints.site
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let state = AnnouncementState(defaults: defaults)
        state.configure(site: site, userID: 7); state.accept(try bundle()); state.markAllSeen()
        state.configure(site: site, userID: 8)
        #expect(state.bundle == nil && state.seen.isEmpty)
        state.accept(try bundle()); #expect(state.hasUnread)
        state.configure(site: URL(string: "https://other.example.test"), userID: 7)
        state.accept(try bundle()); #expect(state.hasUnread)
        state.configure(site: nil, userID: nil); state.accept(try bundle())
        #expect(state.bundle == nil && state.seen.isEmpty && state.takePopup() == nil)
    }
}

extension BusinessSessionTests {
    @Test func announcementResponseAfterLogoutCannotRestoreContent() async throws {
        let announcement = #"{"announcements":[{"id":2,"title":"旧账户公告","date":"","updated_at":"revision","content":"旧账户正文"}],"popup":null}"#
        let (session, transport) = await restored([reply("/announcements", announcement, paused: true), reply("/auth/logout", "{}")])
        let request = Task { try await session.announcements() }
        await transport.waitUntilPaused()
        await session.logout()
        await transport.resume()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(session.announcementState.bundle == nil && session.phase == .signedOut)
    }
}
