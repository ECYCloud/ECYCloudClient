import Foundation
import CryptoKit
import Observation
#if DEBUG
import OSLog
#endif

@MainActor
@Observable
public final class ClientSession {
    public let icons = RemoteIconStore()
    public enum Phase: Equatable {
        case starting, signedOut, restoring, signedIn, restricted, cleanupFailed
    }

    public private(set) var phase: Phase = .starting
    public private(set) var busy = false
    public private(set) var sendingEmail = false
    public private(set) var needsTwoFactor = false
    public private(set) var profile: UserProfile?
    public private(set) var accountStatus: AccountStatus?
    public private(set) var catalog: NodeCatalog?
    public private(set) var nodeSelections: [String: String] = [:]
    public private(set) var nodesLoading = false
    public private(set) var options: AuthOptions?
    public private(set) var message: String?
    public private(set) var nodesError: String?
    public private(set) var updatedAt: Date?
    public private(set) var panelOffline = false
    public private(set) var endpoints: PanelEndpoints

    public let connection: ConnectionController?
    public let preferences: ClientPreferences
    public let nodeProbes: NodeProbeState
    public let trafficRank: TrafficRankStore
    public let announcementState: AnnouncementState

    @ObservationIgnored let api: PanelAPI
    @ObservationIgnored private let vault: any CredentialVault
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var saved: StoredSession?
    @ObservationIgnored private let cache: PanelResponseCache?
    // 凭离线缓存进入时为离线授权到期时间；面板重新可达后清空，回到以令牌有效期为准
    @ObservationIgnored private var offlineUntil: Date?
    // 对应 connection_controller.dart 的 _canUseOffline：授权窗口外的缓存配置只供显示，面板更新前不得拉起内核
    @ObservationIgnored private var catalogExpired = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var rememberedGeneration = 0
    @ObservationIgnored private var loggingOut = false
    @ObservationIgnored private var runtimeActive = true
    public private(set) var emailCodeAvailableAt: [EmailPurpose: Date] = [:]
    @ObservationIgnored var accountMailDates: [String: Date] = [:]
    @ObservationIgnored private var cooldown: Date?

    public init(endpoints: PanelEndpoints, api: PanelAPI, vault: any CredentialVault, connection: ConnectionController? = nil, preferences: ClientPreferences? = nil, announcementState: AnnouncementState? = nil, nodeProbes: NodeProbeState? = nil, trafficRank: TrafficRankStore? = nil, cache: PanelResponseCache? = nil, now: @escaping () -> Date = Date.init) {
        self.endpoints = vault.endpoints ?? endpoints
        self.api = api
        self.vault = vault
        self.cache = cache
        self.now = now
        self.connection = connection
        self.preferences = preferences ?? ClientPreferences()
        self.announcementState = announcementState ?? AnnouncementState()
        self.nodeProbes = nodeProbes ?? NodeProbeState(now: now)
        self.trafficRank = trafficRank ?? TrafficRankStore(now: now)
        connection?.runtimeDidReset = { [weak self] keepingResults in self?.nodeProbes.clear(keepingResults: keepingResults) }
        api.route.connected = { [weak connection] in connection?.state == .connected }
        api.route.proxyPort = { [weak connection] in connection?.panelProxyPort }
    }

    public func start() async {
        guard phase == .starting else { return }
        await restore()
        await reconcileConnection()
        if phase == .signedOut { await loadOptions() }
        if phase == .signedIn, preferences.autoConnect { await connect(reclaimed: false) }
    }

    public func loadOptions() async {
        guard phase == .signedOut, !busy, canRequest() else { return }
        busy = true
        message = nil
        let operation = generation
        defer { if operation == generation { busy = false } }
        do {
            let value = try await api.options(endpoints)
            guard operation == generation else { return }
            try applyOrigins(site: value.siteOrigin, config: value.apiOrigin)
            options = value
            #if DEBUG
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "ECYCloudKit", category: "LoginOptions")
                .info("login_options_loaded email_login_enabled=\(value.emailVerify, privacy: .public)")
            #endif
        } catch {
            #if DEBUG
            if case ClientError.networkFailure(let code) = error {
                Logger(subsystem: Bundle.main.bundleIdentifier ?? "ECYCloudKit", category: "LoginOptions")
                    .error("login_options_network_error code=\(code, privacy: .public)")
            }
            #endif
            if operation == generation { report(error) }
        }
    }

    public func restore() async {
        guard !busy, phase == .starting else { return }
        busy = true
        phase = .restoring
        message = nil
        let operation = generation
        defer { if operation == generation { busy = false } }
        do {
            if vault.logoutPending {
                guard clearLocal() else { return }
                return
            }
            guard let session = try vault.load() else {
                phase = .signedOut
                return
            }
            guard session.expiresAt > now(), !session.token.isEmpty else {
                _ = clearLocal()
                return
            }
            endpoints = try PanelEndpoints(site: session.endpoints.site.absoluteString, config: session.endpoints.config.absoluteString)
            saved = session
            // 对应 auth_controller.dart：本机登录有效即凭缓存进入界面，不等面板；账户状态与资料随后由面板覆盖
            if let restored = cache?.restore(account: session.email, binding: api.cacheBinding(endpoints, token: session.token), now: now()),
               restored.profile.email == session.email, session.userID == nil || restored.profile.id == session.userID {
                profile = restored.profile
                catalog = restored.catalog
                offlineUntil = restored.validUntil
                catalogExpired = restored.catalog != nil && restored.validUntil == nil
            }
            let userID = profile?.id ?? session.userID
            announcementState.configure(site: endpoints.site, userID: userID)
            nodeProbes.configure(site: endpoints.site, userID: userID)
            trafficRank.configure(site: endpoints.site, userID: userID)
            phase = .signedIn
            await reconcileConnection()
            guard operation == generation else { return }
            let status = try await api.accountStatus(endpoints, token: session.token)
            guard operation == generation else { return }
            guard status.email == session.email else { throw ClientError.invalidResponse }
            if !status.isNormal {
                announcementState.configure(site: nil, userID: nil)
                connection?.disconnect()
                profile = nil
                catalog = nil
                offlineUntil = nil
                accountStatus = status
                phase = .restricted
                return
            }
            let response = try await api.profileResponse(endpoints, token: session.token, connected: connection?.state == .connected)
            guard operation == generation else { return }
            try accept(response.value, session: session)
            cache?.saveProfile(response.data, account: session.email)
            offlineUntil = nil
            phase = .signedIn
            await reconcileConnection()
            await loadNodes()
        } catch {
            guard operation == generation else { return }
            if (error as? ClientError)?.unauthorized == true {
                if clearLocal() { message = L10n.t("登录已失效，请重新登录。") }
            } else {
                // 面板暂时不可达或响应异常：保持登录与缓存，由定时刷新继续向面板核实
                panelOffline = true
                recordCooldown(error)
            }
        }
    }

    public func login(email: String, password: String, code: String = "", emailCode: Bool = false, rememberPassword: Bool? = nil) async {
        guard phase == .signedOut, !busy, canRequest() else { return }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty, emailCode ? !code.isEmpty : !password.isEmpty else {
            message = emailCode ? L10n.t("请输入邮箱和验证码。") : L10n.t("请输入邮箱和密码。")
            return
        }
        guard !emailCode || canUseEmailLogin() else { return }
        let operation = generation + 1
        let rememberedOperation = rememberedGeneration
        await authenticate(.login) { try await api.login(endpoints, email: email, password: password, code: code, emailCode: emailCode) }
        guard !Task.isCancelled, generation == operation, rememberedGeneration == rememberedOperation, [.signedIn, .restricted].contains(phase),
              saved?.email.lowercased() == email, !emailCode, let rememberPassword else { return }
        do {
            if rememberPassword { try vault.saveRemembered(RememberedLogin(email: email, password: password, site: endpoints.site)) }
            else { try vault.clearRemembered() }
        } catch { message = L10n.t("记住账号密码：") + errorText(error) }
    }

    public func loadRememberedLogin() throws -> RememberedLogin? {
        guard phase == .signedOut, let login = try vault.loadRemembered(), login.site == endpoints.site else { return nil }
        return login
    }

    public func clearRememberedLogin() throws { rememberedGeneration += 1; try vault.clearRemembered() }

    public func register(name: String, email: String, password: String, confirmation: String,
                         invite: String, emailCode: String, agreed: Bool) async {
        guard phase == .signedOut, !busy, canRequest() else { return }
        guard let options else { message = L10n.t("尚未获取站点注册选项，请先重试。"); return }
        guard !options.registrationClosed else { message = L10n.t("当前未开放注册"); return }
        guard agreed else { message = L10n.t("请先同意服务条款与隐私政策"); return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, !email.isEmpty else { message = L10n.t("请填写用户名和邮箱。"); return }
        guard password.utf8.count >= 8, password == confirmation else { message = L10n.t("密码至少 8 位，且两次输入必须一致。"); return }
        let invite = invite.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !options.inviteRequired || !invite.isEmpty else { message = L10n.t("请填写邀请码。"); return }
        guard !options.emailVerify || !emailCode.isEmpty else { message = L10n.t("请填写邮箱验证码。"); return }
        await authenticate(.registration) {
            try await api.register(endpoints, name: name, email: email, password: password,
                                   confirmation: confirmation, invite: invite, emailCode: emailCode)
        }
    }

    public func resetPassword(tokenInput: String, password: String, confirmation: String) async {
        guard phase == .signedOut, !busy, canRequest() else { return }
        guard let token = PasswordResetToken.fromInput(tokenInput) else { message = L10n.t("请填写有效的重置链接或 Token。"); return }
        guard password.utf8.count >= 8, password == confirmation else { message = L10n.t("密码至少 8 位，且两次输入必须一致。"); return }
        await authenticate(.reset) {
            try await api.resetPassword(endpoints, token: token, password: password, confirmation: confirmation)
        }
    }

    public func document(_ kind: LegalDocumentKind) async throws -> RichDocument {
        try await api.document(endpoints, kind: kind)
    }

    public func dismissMessage() { message = nil }

    public func history(_ kind: AccountHistoryKind, page: Int, search: String) async throws -> AccountHistory {
        guard page > 0 else { throw ClientError.invalidResponse }
        return try await authenticated { session in
            try await api.history(endpoints, token: session.token, kind: kind, page: page, search: search)
        }
    }

    public func updateUsername(_ name: String) async throws -> String {
        guard !busy else { throw CancellationError() }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.unicodeScalars.count <= 15,
              name.range(of: #"^[\p{L}\d _-]+$"#, options: .regularExpression) != nil,
              name.range(of: #"--|__| {2,}|^\d+$"#, options: .regularExpression) == nil else {
            throw ClientError.server(status: 400, code: 0, message: L10n.t("用户名需为 1–15 个文字、字母、数字、-、_ 或空格；不能为纯数字或连续使用分隔符。"), retryAfter: nil)
        }
        busy = true
        let operation = generation
        defer { if operation == generation { busy = false } }
        let result = try await authenticated { try await api.updateUsername(endpoints, token: $0.token, name: name) }
        do {
            let value = try await authenticated { try await api.profile(endpoints, token: $0.token) }
            if let saved { try accept(value, session: saved) }
        } catch {
            if operation != generation { throw CancellationError() }
            return result + L10n.t(" 账户刷新未完成，请稍后刷新。")
        }
        return result
    }

    public func updatePassword(old: String, password: String, confirmation: String) async throws {
        guard !busy else { throw CancellationError() }
        guard !old.isEmpty, password.utf8.count >= 8, password == confirmation,
              old.utf8.count <= 4096, password.utf8.count <= 4096 else {
            throw ClientError.server(status: 400, code: 0, message: L10n.t("请输入当前密码；新密码至少 8 位，且两次输入必须一致。"), retryAfter: nil)
        }
        busy = true
        let operation = generation
        defer { if operation == generation { busy = false } }
        let result = try await authenticated { try await api.updatePassword(endpoints, token: $0.token, old: old, password: password, confirmation: confirmation) }
        finishCredentialChange(result.isEmpty ? L10n.t("密码已修改，请使用新密码重新登录。") : result)
    }

    func finishCredentialChange(_ text: String) {
        generation += 1; busy = false
        if clearLocal() { message = text }
    }

    public var needsDeviceSlot: Bool {
        guard let profile else { return false }
        return profile.deviceKickReason == "limit_denied" ||
            (profile.nodeConnector > 0 && profile.onlineClientCount >= profile.nodeConnector && profile.onlineClientSelf == false)
    }

    // 对应 auth_controller.dart 的 ticketReplyUnread / markTicketsSeen
    public var hasUnreadTicketReply: Bool {
        guard let profile, let latest = profile.latestAdminReplyAt, !latest.isEmpty,
              preferences.ticketInbox["user_id"] as? Int == profile.id else { return false }
        return latest > (preferences.ticketInbox["seen_admin_reply_at"] as? String ?? "")
    }

    public func markTicketsSeen() {
        guard let profile, preferences.ticketInbox["user_id"] as? Int != profile.id || hasUnreadTicketReply else { return }
        preferences.ticketInbox = ["user_id": profile.id, "seen_admin_reply_at": profile.latestAdminReplyAt ?? ""]
    }

    public var refreshInterval: TimeInterval {
        connection?.state == .connecting || (connection?.state == .connected && (profile?.nodeConnector ?? 0) > 0 && profile?.onlineClientSelf == false) ? 5 : 60
    }

    private func stopKickedConnection() {
        if profile?.deviceKickNotice == true { connection?.disconnect() }
    }

    public func acknowledgeDeviceKick() async throws {
        guard !busy else { throw CancellationError() }
        busy = true
        do {
            _ = try await authenticated { try await api.perform("/user/device-kick-ack", origin: endpoints.site, token: $0.token, body: [:]) }
            busy = false
            await refresh()
        } catch { busy = false; throw error }
    }

    public func onlineDevices() async throws -> [OnlineDevice] {
        try await authenticated { try await api.request("/user/online-devices", origin: endpoints.site, token: $0.token) }
    }

    public func reclaimDeviceSlot(_ deviceID: String) async throws {
        guard !busy, connection?.state == .disconnected else { throw CancellationError() }
        guard deviceID.utf8.count <= 256 else { throw ClientError.invalidResponse }
        busy = true
        do {
            _ = try await authenticated { try await api.perform("/user/device-reclaim", origin: endpoints.site, token: $0.token, body: ["target_device_id": deviceID]) }
            _ = try await authenticated { try await api.perform("/user/device-kick-ack", origin: endpoints.site, token: $0.token, body: [:]) }
            busy = false
            await connect(reclaimed: true)
        } catch { busy = false; throw error }
    }

    public func checkin() async throws -> String {
        guard !busy else { throw CancellationError() }
        busy = true
        defer { busy = false }
        let value: UserProfile = try await authenticated { try await api.request("/user/checkin", origin: endpoints.site, token: $0.token, body: [:]) }
        try value.validate()
        guard let saved else { throw CancellationError() }
        try accept(value, session: saved)
        return L10n.t("签到成功，流量已更新。")
    }

    public func kickDevice(_ deviceID: String) async throws -> String {
        guard !deviceID.isEmpty else { throw ClientError.invalidResponse }
        return try await authenticated { session in
            try await api.kickDevice(endpoints, token: session.token, deviceID: deviceID)
        }
    }

    func authenticated<Value: Sendable>(allowRestricted: Bool = false, silently: Bool = false, _ request: (StoredSession) async throws -> Value) async throws -> Value {
        guard (phase == .signedIn || (allowRestricted && phase == .restricted)), let session = saved else { throw CancellationError() }
        guard session.expiresAt > now() else {
            generation += 1
            busy = false
            _ = clearLocal()
            throw CancellationError()
        }
        guard canRequest() else {
            throw ClientError.server(status: 429, code: 0, message: L10n.t("请求过于频繁，请稍后重试。"), retryAfter: nil)
        }
        let operation = generation
        do {
            let value = try await request(session)
            try Task.checkCancellation()
            guard operation == generation, (phase == .signedIn || (allowRestricted && phase == .restricted)) else { throw CancellationError() }
            return value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard operation == generation else { throw CancellationError() }
            // 连不上面板属于会话状态，由各页自身的加载错误与首页连接状态呈现，不再逐个写进全局提示
            let unreachable = switch error as? ClientError { case .network, .networkFailure, .unreachable: true; default: false }
            if unreachable { panelOffline = true }
            if (silently || unreachable) && (error as? ClientError)?.unauthorized != true { recordCooldown(error) } else { handleAuthenticatedError(error) }
            throw error
        }
    }

    public enum Authentication: Sendable { case login, registration, reset }
    public private(set) var authentication: Authentication?

    private func authenticate(_ kind: Authentication, _ request: () async throws -> LoginResult) async {
        busy = true
        message = nil
        generation += 1
        let operation = generation
        defer { if operation == generation { busy = false } }
        do {
            let result = try await request()
            guard operation == generation else { return }
            let expiration = try result.expiration()
            guard expiration > now() else { throw ClientError.invalidResponse }
            if let user = result.user {
                try applyOrigins(site: user.siteOrigin, config: user.apiOrigin)
            }
            let session = StoredSession(
                token: result.token, expiresAt: expiration,
                email: result.user?.email ?? result.accountStatus!.email,
                userID: result.user?.id, endpoints: endpoints
            )
            do { try vault.save(session) }
            catch {
                try? await api.logout(endpoints, token: result.token)
                throw error
            }
            guard operation == generation else { return }
            saved = session
            offlineUntil = nil
            needsTwoFactor = false
            profile = result.user
            panelOffline = false
            announcementState.configure(site: endpoints.site, userID: result.user?.id)
            nodeProbes.configure(site: endpoints.site, userID: result.user?.id)
            trafficRank.configure(site: endpoints.site, userID: result.user?.id)
            stopKickedConnection()
            accountStatus = result.accountStatus
            authentication = kind
            phase = result.accountStatus?.isNormal == false ? .restricted : .signedIn
            updatedAt = now()
            message = result.message.flatMap { $0.isEmpty ? nil : $0 }
            await reconcileConnection()
            if phase == .signedIn { await loadNodes() }
        } catch {
            guard operation == generation else { return }
            if (error as? ClientError)?.needsTwoFactor == true { needsTwoFactor = true }
            report(error)
        }
    }

    public func sendEmailCode(email: String) async {
        _ = await sendEmail(email: email, purpose: .login)
    }

    public func emailCooldown(_ purpose: EmailPurpose) -> Int {
        max(0, Int(ceil(emailCodeAvailableAt[purpose]?.timeIntervalSince(now()) ?? 0)))
    }

    @discardableResult
    public func sendEmail(email: String, purpose: EmailPurpose) async -> Bool {
        guard phase == .signedOut, !busy, !sendingEmail, canRequest(), emailCooldown(purpose) == 0 else { return false }
        if purpose == .login && !canUseEmailLogin() { return false }
        if purpose == .registration {
            guard let options else { message = L10n.t("尚未获取站点注册选项，请先重试。"); return false }
            guard !options.registrationClosed, options.emailVerify else { message = L10n.t("站点当前不提供注册邮箱验证。"); return false }
        }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty else { message = L10n.t("请输入邮箱。"); return false }
        sendingEmail = true
        message = nil
        let operation = generation
        defer { sendingEmail = false }
        do {
            let result = try await api.requestEmail(endpoints, purpose: purpose, email: email)
            guard operation == generation else { return false }
            message = result
            emailCodeAvailableAt[purpose] = now().addingTimeInterval(60)
            return true
        } catch {
            if operation == generation { report(error) }
            return false
        }
    }

    // silently 对应 auth_controller.dart 的后台 refreshProfile：面板失败只记状态不提示，登录失效仍照常处理
    public func refresh(silently: Bool = false) async {
        if phase == .signedOut && options == nil {
            await loadOptions()
            return
        }
        guard !busy, !nodesLoading, let session = saved, canRequest(), [.signedIn, .restricted].contains(phase) else { return }
        busy = true
        message = nil
        let operation = generation
        defer { if operation == generation { busy = false } }
        do {
            guard session.expiresAt > now() else {
                if clearLocal() { message = L10n.t("登录已过期，请重新登录。") }
                return
            }
            let status = try await api.accountStatus(endpoints, token: session.token)
            guard operation == generation else { return }
            guard status.email == session.email else { throw ClientError.invalidResponse }
            accountStatus = status
            if !status.isNormal {
                announcementState.configure(site: nil, userID: nil)
                connection?.disconnect()
                profile = nil
                catalog = nil
                nodesError = nil
                offlineUntil = nil
                phase = .restricted
                return
            }
            let response = try await api.profileResponse(endpoints, token: session.token, connected: connection?.state == .connected)
            guard operation == generation else { return }
            let value = response.value
            try accept(value, session: session)
            cache?.saveProfile(response.data, account: session.email)
            offlineUntil = nil
            phase = .signedIn
            await reconcileConnection()
            if catalog?.revision != value.configRevision {
                await loadNodes()
            } else if runtimeActive, connection?.supportsStandby == true, connection?.state == .disconnected {
                Task { [weak self] in
                    guard let self else { return }
                    do { try await ensureControlPlane() }
                    catch is CancellationError {}
                    catch { if operation == generation { nodesError = errorText(error) } }
                }
            }
        } catch is CancellationError {
        } catch {
            guard operation == generation else { return }
            if (error as? ClientError)?.unauthorized != true { panelOffline = true }
            if silently && panelOffline { recordCooldown(error) } else { handleAuthenticatedError(error) }
        }
    }

    public func loadNodes() async {
        guard !nodesLoading, phase == .signedIn, let session = saved, canRequest() else { return }
        guard session.expiresAt > now() else {
            generation += 1
            busy = false
            if clearLocal() { message = L10n.t("登录已过期，请重新登录。") }
            return
        }
        nodesLoading = true
        nodesError = nil
        let operation = generation
        defer { if operation == generation { nodesLoading = false } }
        do {
            let response = try await api.nodes(endpoints, token: session.token)
            guard operation == generation, phase == .signedIn else { return }
            let result = response.value
            let previousRevision = catalog?.revision
            catalog = result
            catalogExpired = false
            cache?.saveConfig(response.data, account: session.email, binding: api.cacheBinding(endpoints, token: session.token))
            if offlineUntil != nil {
                offlineUntil = nil
                await reconcileConnection()
            }
            nodeSelections = nodeSelections.filter { group, node in result.selectionGroups.contains { $0.id == group && $0.members.contains(node) } }
            if let previousRevision, previousRevision != result.revision, connection?.state == .connected {
                try await applyProxySettings()
            } else if runtimeActive, connection?.supportsStandby == true, connection?.state == .disconnected {
                Task { [weak self] in
                    guard let self, operation == generation, runtimeActive, connection?.state == .disconnected,
                          catalog?.revision == result.revision else { return }
                    do {
                        if let previousRevision, previousRevision != result.revision, connection?.controlPlaneReady == true {
                            try await connection?.returnToStandby(makeLease(takeover: false))
                        } else {
                            try await ensureControlPlane()
                        }
                    } catch is CancellationError {
                    } catch {
                        if operation == generation { nodesError = errorText(error) }
                    }
                }
            }
        } catch is CancellationError {
        } catch {
            guard operation == generation else { return }
            if (error as? ClientError)?.unauthorized == true {
                handleAuthenticatedError(error)
            } else {
                nodesError = errorText(error)
                recordCooldown(error)
            }
        }
    }

    private var connectionOwner: String? {
        guard let saved, phase == .signedIn else { return nil }
        return SHA256.hash(data: Data(saved.token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public var logDirectory: URL? { connectionOwner.flatMap(ClientLogStore.directory) }

    private var sessionExpiry: Date? {
        guard let expiresAt = saved?.expiresAt else { return nil }
        return offlineUntil.map { min($0, expiresAt) } ?? expiresAt
    }

    private func reconcileConnection() async {
        if let owner = connectionOwner { icons.configure(owner: owner) }
        await connection?.reconcile(owner: connectionOwner, expiresAt: sessionExpiry)
    }

    public func selectNode(group: String, node: String) {
        guard phase == .signedIn,
              let group = catalog?.selectionGroups.first(where: { $0.id == group }) else { return }
        if node.isEmpty { nodeSelections.removeValue(forKey: group.id) }
        else if group.members.contains(node) { nodeSelections[group.id] = node }
    }

    public func connect() async { await connect(reclaimed: false) }

    public func ensureControlPlane() async throws {
        guard phase == .signedIn, runtimeActive, let connection else { throw TunnelError.control }
        if connection.controlPlaneReady { return }
        let lease = try makeLease(takeover: false)
        await reconcileConnection()
        guard phase == .signedIn, connectionOwner == lease.owner, runtimeActive else { throw CancellationError() }
        try await connection.prepareStandby(lease)
    }

    public func setRuntimeActive(_ active: Bool) async {
        if !active { trafficRank.flush() }
        #if os(iOS) || os(tvOS) || os(visionOS)
        runtimeActive = active
        if !active, connection?.state == .disconnected { connection?.disconnect() }
        #endif
        if active, phase == .signedIn, connection?.supportsStandby == true, connection?.state == .disconnected {
            try? await ensureControlPlane()
        }
    }

    public func disconnectToStandby() async {
        guard let connection else { return }
        let operation = generation
        do {
            if connection.controlPlaneReady {
                let snapshot = try? await tunnelSnapshot()
                for (group, node) in snapshot?.selections ?? [:] { selectNode(group: group, node: node) }
            }
            guard operation == generation, runtimeActive else { throw CancellationError() }
            try await connection.returnToStandby(makeLease(takeover: false))
        } catch is CancellationError {
        } catch { if operation == generation { report(error) } }
    }

    public func applyProxySettings() async throws {
        guard let connection, phase == .signedIn, connection.controlPlaneReady else { return }
        let operation = generation
        let takeover = connection.state == .connected
        guard takeover || connection.state == .disconnected else { throw TunnelError.control }
        let snapshot = try? await tunnelSnapshot()
        guard operation == generation else { throw CancellationError() }
        for (group, node) in snapshot?.selections ?? [:] { selectNode(group: group, node: node) }
        try await connection.restart(makeLease(takeover: takeover), takeover: takeover)
        if let message = connection.message { throw ClientError.input(message) }
    }

    public func runtimeConfigurationText() throws -> String {
        guard phase == .signedIn, let data = connection?.runtimeConfiguration else { throw TunnelError.control }
        let object = try JSONSerialization.jsonObject(with: data)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        return catalog?.annotateRuntimeConfiguration(text) ?? text
    }

    private func makeLease(takeover: Bool) throws -> TunnelLease {
        guard let connection, phase == .signedIn, let saved, let catalog, let owner = connectionOwner else { throw TunnelError.control }
        guard !catalogExpired else { throw ClientError.input(L10n.t("本地配置授权已到期，请连接面板更新后重试")) }
        var options = try connection.profileOptions(preferences)
        if !takeover { options.tunEnabled = false }
        let profile = try catalog.assemble(options: options, selections: nodeSelections)
        return TunnelLease(owner: owner, expiresAt: sessionExpiry ?? saved.expiresAt, configuration: profile.data,
                           validationConfiguration: options.input == .proxy ? profile.validationData : nil, logLevel: preferences.logLevel)
    }

    private func connect(reclaimed: Bool) async {
        guard let connection, connection.state == .disconnected, !busy else { return }
        await refresh()
        guard phase == .signedIn, let saved, catalog != nil, let owner = connectionOwner else { return }
        guard reclaimed || profile?.deviceKickNotice != true else { message = L10n.t("设备下线通知尚未处理，请先查看通知。"); return }
        guard reclaimed || !needsDeviceSlot else { message = L10n.t("在线客户端名额已满，请选择一台设备下线后连接。"); return }
        let operation = generation
        do {
            if connection.controlPlaneReady {
                let snapshot = try? await tunnelSnapshot()
                for (group, node) in snapshot?.selections ?? [:] { selectNode(group: group, node: node) }
            }
            guard operation == generation else { return }
            let lease = try makeLease(takeover: true)
            await connection.reconcile(owner: owner, expiresAt: sessionExpiry ?? saved.expiresAt)
            guard operation == generation, phase == .signedIn else { return }
            await connection.connect(lease)
        } catch { report(error) }
    }

    public func logout() async {
        guard !loggingOut else { return }
        loggingOut = true
        generation += 1
        let session = saved
        let origins = endpoints
        busy = true
        message = nil
        let cleared = clearLocal()
        if let session {
            do { try await api.logout(origins, token: session.token) }
            catch {
                if cleared && (error as? ClientError)?.unauthorized != true {
                    message = L10n.t("已清除本机登录信息，但未能确认服务器会话撤销。可在网站设备管理中核查。")
                }
            }
        }
        busy = false
        loggingOut = false
    }

    private func accept(_ value: UserProfile, session: StoredSession) throws {
        guard value.email == session.email, session.userID == nil || value.id == session.userID else {
            throw ClientError.invalidResponse
        }
        try applyOrigins(site: value.siteOrigin, config: value.apiOrigin)
        let updated = StoredSession(token: session.token, expiresAt: session.expiresAt,
                                    email: value.email, userID: value.id, endpoints: endpoints)
        try vault.save(updated)
        saved = updated
        profile = value
        panelOffline = false
        announcementState.configure(site: endpoints.site, userID: value.id)
        nodeProbes.configure(site: endpoints.site, userID: value.id)
        trafficRank.configure(site: endpoints.site, userID: value.id)
        stopKickedConnection()
        accountStatus = nil
        updatedAt = now()
    }

    private func applyOrigins(site: String, config: String) throws {
        let next = try endpoints.updating(site: site, config: config)
        endpoints = next
        vault.endpoints = next
    }

    private func clearLocal() -> Bool {
        icons.clear()
        nodeProbes.configure(site: nil, userID: nil)
        trafficRank.configure(site: nil, userID: nil)
        connection?.disconnect(clearLogsFor: connectionOwner)
        vault.logoutPending = true
        cache?.clear()
        saved = nil
        offlineUntil = nil
        catalogExpired = false
        announcementState.configure(site: nil, userID: nil)
        accountMailDates = [:]
        profile = nil
        accountStatus = nil
        catalog = nil
        nodeSelections = [:]
        nodesError = nil
        nodesLoading = false
        updatedAt = nil
        panelOffline = false
        cooldown = nil
        needsTwoFactor = false
        do {
            try vault.clear()
            vault.logoutPending = false
            phase = .signedOut
            return true
        } catch {
            phase = .cleanupFailed
            message = errorText(error)
            return false
        }
    }

    private func handleAuthenticatedError(_ error: any Error) {
        if (error as? ClientError)?.unauthorized == true {
            generation += 1
            busy = false
            if clearLocal() { message = L10n.t("登录已失效，请重新登录。") }
        } else {
            report(error)
        }
    }

    private func report(_ error: any Error) {
        message = errorText(error)
        recordCooldown(error)
    }

    private func recordCooldown(_ error: any Error) {
        if case .server(429, _, _, let seconds) = error as? ClientError {
            cooldown = now().addingTimeInterval(TimeInterval(seconds ?? 6))
        }
    }

    private func canUseEmailLogin() -> Bool {
        guard let options else {
            message = L10n.t("尚未获取站点登录选项，请先重试。")
            return false
        }
        guard options.emailVerify else {
            message = L10n.t("站点未开启邮箱验证码登录。")
            return false
        }
        return true
    }

    private func canRequest() -> Bool {
        guard let cooldown, cooldown > now() else { return true }
        message = L10n.t("请求过于频繁，请稍后重试。")
        return false
    }

    private func errorText(_ error: any Error) -> String {
        (error as? ClientError)?.localizedDescription ?? (error as? TunnelError)?.localizedDescription ?? L10n.t("操作未完成，请稍后重试。")
    }
}
