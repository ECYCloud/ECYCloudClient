import Foundation
import CryptoKit
import Observation
import OSLog

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
    // 对应 connection_controller.dart 的 onConfigAlert：结构检查不通过时弹窗列出问题，同一组问题只弹一次
    public var configAlert: String?
    @ObservationIgnored private var lastConfigAlert: String?
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
    @ObservationIgnored private let bundled: PanelEndpoints
    @ObservationIgnored private var unreachable: [String: (failures: Int, since: Date)] = [:]
    @ObservationIgnored private var probedAt: [String: Date] = [:]
    @ObservationIgnored private var offered: [Bool: URL] = [:]
    // 最近一轮新地址探测；测试据此等探测结束
    @ObservationIgnored var originProbe: Task<Void, Never>?
    @ObservationIgnored let now: () -> Date
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
    @ObservationIgnored private var connecting = false
    public private(set) var emailCodeAvailableAt: [EmailPurpose: Date] = [:]
    @ObservationIgnored var accountMailDates: [String: Date] = [:]
    @ObservationIgnored private var cooldown: Date?

    public init(endpoints: PanelEndpoints, api: PanelAPI, vault: any CredentialVault, connection: ConnectionController? = nil, preferences: ClientPreferences? = nil, announcementState: AnnouncementState? = nil, nodeProbes: NodeProbeState? = nil, trafficRank: TrafficRankStore? = nil, cache: PanelResponseCache? = nil, now: @escaping () -> Date = Date.init) {
        self.endpoints = vault.endpoints ?? endpoints
        self.bundled = endpoints
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
        api.route.reached = { [weak self] url, reachable in self?.reached(url, reachable) }
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
            applyOrigins(site: value.siteOrigin, config: value.apiOrigin)
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
            if let restored = cache?.restore(account: session.email, binding: api.cacheBinding(endpoints, token: session.token),
                                             sealKey: api.cacheKey(token: session.token), now: now()),
               restored.profile.email == session.email, session.userID == nil || restored.profile.id == session.userID {
                // 对应 connection_controller.dart 的 _hydrateRemoteFromCache：缓存的节点目录同样先过结构检查，不通过就不用这份缓存
                let usable = restored.catalog.flatMap { (try? $0.validate()) != nil ? $0 : nil }
                if restored.catalog != nil, usable == nil {
                    Logger(subsystem: Bundle.main.bundleIdentifier ?? "ECYCloudKit", category: "PanelCache").warning("cached_catalog_invalid")
                }
                profile = restored.profile
                catalog = usable
                offlineUntil = usable == nil ? nil : restored.validUntil
                catalogExpired = usable != nil && restored.validUntil == nil
            }
            let userID = profile?.id ?? session.userID
            announcementState.configure(site: endpoints.site, userID: userID)
            nodeProbes.configure(site: endpoints.site, userID: userID)
            if nodeSelections.isEmpty { nodeSelections = nodeProbes.savedSelections() }
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
            } else if phase == .restoring {
                phase = .starting
                message = errorText(error)
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
        if emailCode, options == nil { await loadOptions() }
        guard phase == .signedOut, !busy, !emailCode || canUseEmailLogin() else { return }
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
    public private(set) var passwordResetNotice: String?
    public func dismissPasswordResetNotice() { passwordResetNotice = nil }

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
                applyOrigins(site: user.siteOrigin, config: user.apiOrigin)
            }
            let session = StoredSession(
                token: result.token, expiresAt: expiration,
                email: result.user?.email ?? result.accountStatus!.email,
                userID: result.user?.id, endpoints: endpoints
            )
            do { try vault.save(session) }
            catch { Logger(subsystem: Bundle.main.bundleIdentifier ?? "ECYCloudKit", category: "Session").warning("session_save_failed") }
            guard operation == generation else { return }
            saved = session
            offlineUntil = nil
            needsTwoFactor = false
            profile = result.user
            panelOffline = false
            announcementState.configure(site: endpoints.site, userID: result.user?.id)
            nodeProbes.configure(site: endpoints.site, userID: result.user?.id)
            if nodeSelections.isEmpty { nodeSelections = nodeProbes.savedSelections() }
            trafficRank.configure(site: endpoints.site, userID: result.user?.id)
            stopKickedConnection()
            accountStatus = result.accountStatus
            authentication = kind
            phase = result.accountStatus?.isNormal == false ? .restricted : .signedIn
            updatedAt = now()
            message = result.message.flatMap { $0.isEmpty ? nil : $0 }
            await reconcileConnection()
            if phase == .signedIn { await loadNodes() }
        } catch ClientError.passwordChanged(let notice) where kind == .reset {
            if operation == generation { passwordResetNotice = notice }
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
        if options == nil { await loadOptions() }
        guard phase == .signedOut, !busy, !sendingEmail else { return false }
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
            if catalog?.revision != value.configRevision || catalog?.updateDue(at: now()) == true {
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
            // 对应 connection_controller.dart 的 _acceptRemote：结构检查不通过就保留上一份目录与缓存
            try result.validate()
            lastConfigAlert = nil
            let previousRevision = catalog?.revision
            catalog = result
            catalogExpired = false
            cache?.saveConfig(response.data, account: session.email, binding: api.cacheBinding(endpoints, token: session.token),
                              sealKey: api.cacheKey(token: session.token), updateIntervalHours: result.updateIntervalHours)
            if offlineUntil != nil {
                offlineUntil = nil
                await reconcileConnection()
            }
            nodeSelections = nodeSelections.filter { group, node in result.selectionGroups.contains { $0.id == group && $0.members.contains(node) } }
            if let previousRevision, previousRevision != result.revision, let connection, connection.state == .connected {
                var updated = false
                if let live = try connection.liveProfileOptions(preferences) {
                    updated = try await connection.updateNodes(makeLease(takeover: true, options: live))
                }
                if !updated { try await applyProxySettings() }
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
                if let invalid = error as? ProfileValidationError, invalid.issues.joined(separator: "\n") != lastConfigAlert {
                    lastConfigAlert = invalid.issues.joined(separator: "\n")
                    configAlert = lastConfigAlert
                }
                recordCooldown(error)
            }
        }
    }

    private var connectionOwner: String? {
        guard let saved, phase == .signedIn else { return nil }
        return Self.owner(of: saved)
    }
    private static func owner(of session: StoredSession) -> String {
        SHA256.hash(data: Data(session.token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    // 与 auth_controller.dart 的 _accountDirKey 逐字节一致：sha256(jsonEncode([Uri.origin, email.trim().toLowerCase()]))
    nonisolated static func accountKey(site: URL, email: String) -> String {
        var origin = "https://" + (site.host ?? "").lowercased()
        if let port = site.port, port != 443 { origin += ":\(port)" }
        let key = [origin, email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
        let data = (try? JSONSerialization.data(withJSONObject: key, options: [.withoutEscapingSlashes])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func accountKey(of session: StoredSession) -> String { accountKey(site: session.endpoints.site, email: session.email) }
    public var logDirectory: URL? { connectionOwner.flatMap(ClientLogStore.directory) }

    private var authorizationLimitsSession: Bool {
        guard let offlineUntil, let expiresAt = saved?.expiresAt else { return false }
        return offlineUntil < expiresAt
    }

    private var sessionExpiry: Date? {
        guard let expiresAt = saved?.expiresAt else { return nil }
        return offlineUntil.map { min($0, expiresAt) } ?? expiresAt
    }

    private func reconcileConnection() async {
        if let owner = connectionOwner { icons.configure(owner: owner) }
        await connection?.reconcile(owner: connectionOwner, expiresAt: sessionExpiry, authorizationExpiry: authorizationLimitsSession)
    }

    public func selectNode(group: String, node: String) {
        guard phase == .signedIn,
              let group = catalog?.selectionGroups.first(where: { $0.id == group }) else { return }
        if node.isEmpty { nodeSelections.removeValue(forKey: group.id) }
        else if group.members.contains(node) { nodeSelections[group.id] = node }
        nodeProbes.saveSelections(nodeSelections)
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

    public func applySystemProxySettings() async throws {
        guard let connection, phase == .signedIn else { return }
        try await connection.applySystemProxy(preferences)
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

    public func applyTunSettings() async throws {
        guard connection?.state != .disconnected else { return }
        try await applyProxySettings()
    }

    public func runtimeConfigurationText() throws -> String {
        guard phase == .signedIn, let data = connection?.runtimeConfiguration else { throw TunnelError.control }
        let text = try Self.maskedRuntimeConfiguration(data)
        return catalog?.annotateRuntimeConfiguration(text) ?? text
    }

    // 运行配置只供查看：控制面 secret、本设备的节点凭据与测速入站口令都不得出现在界面上。
    // 与 connection_controller.dart 的 maskRuntimeSecrets 一致：节点只在 ecy-panel-nodes 下列一次，各组节点 provider 不再重复列出
    nonisolated static func maskedRuntimeConfiguration(_ data: Data) throws -> String {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TunnelError.control }
        if object["secret"] != nil { object["secret"] = "******" }
        for key in ["proxies", "listeners"] where object[key] != nil { object[key] = maskCredentials(object[key]!) }
        if let providers = object["proxy-providers"] as? [String: Any] {
            object["proxy-providers"] = Dictionary(uniqueKeysWithValues: providers.map { name, provider -> (String, Any) in
                guard var provider = provider as? [String: Any], let payload = provider["payload"] else { return (name, provider) }
                if name.hasPrefix("ecy-panel-"), name != "ecy-panel-nodes" { provider["payload"] = nil }
                else { provider["payload"] = maskCredentials(payload) }
                return (name, provider)
            })
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    private nonisolated static func maskCredentials(_ value: Any) -> Any {
        if let list = value as? [Any] { return list.map(maskCredentials) }
        guard let map = value as? [String: Any] else { return value }
        return Dictionary(uniqueKeysWithValues: map.map { key, item -> (String, Any) in
            if ["uuid", "password", "auth", "auth-str", "obfs-password", "private-key", "pre-shared-key", "public-key", "short-id", "psk", "token"].contains(key), let text = item as? String, !text.isEmpty { return (key, "******") }
            return (key, maskCredentials(item))
        })
    }

    private func makeLease(takeover: Bool, options: ProfileOptions? = nil) throws -> TunnelLease {
        guard let connection, phase == .signedIn, let saved, let catalog, let owner = connectionOwner else { throw TunnelError.control }
        guard !catalogExpired, offlineUntil.map({ $0 > now() }) != false else { throw ClientError.input(L10n.t("本地配置授权已到期，请连接面板更新后重试")) }
        var options = try options ?? connection.profileOptions(preferences)
        if !takeover { options.tunEnabled = false }
        let profile = try catalog.assemble(options: options, selections: nodeSelections)
        return TunnelLease(owner: owner, cacheKey: Self.accountKey(of: saved), expiresAt: sessionExpiry ?? saved.expiresAt, configuration: profile.data,
                           validationConfiguration: options.input == .proxy ? profile.validationData : nil, logLevel: preferences.logLevel)
    }

    private func connect(reclaimed: Bool) async {
        guard let connection, connection.state == .disconnected, !connecting else { return }
        connecting = true
        defer { connecting = false }
        // 对应 connection_controller.dart 的 _attemptConnect：离线授权窗口内先连接，面板核实放到连接之后
        let offline = catalog != nil && saved.flatMap {
            cache?.restore(account: $0.email, binding: api.cacheBinding(endpoints, token: $0.token), sealKey: api.cacheKey(token: $0.token),
                           now: now())?.validUntil
        } != nil
        if !offline { await refresh() }
        guard phase == .signedIn, let saved, let owner = connectionOwner else { return }
        guard catalog != nil else { message = nodesError ?? L10n.t("尚未获取面板配置"); return }
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
            await connection.reconcile(owner: owner, expiresAt: sessionExpiry ?? saved.expiresAt, authorizationExpiry: authorizationLimitsSession)
            guard operation == generation, phase == .signedIn else { return }
            await connection.connect(lease)
        } catch { report(error) }
        if offline { Task { [weak self] in if self?.generation == operation { await self?.refresh(silently: true) } } }
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
        applyOrigins(site: value.siteOrigin, config: value.apiOrigin)
        let updated = StoredSession(token: session.token, expiresAt: session.expiresAt,
                                    email: value.email, userID: value.id, endpoints: endpoints)
        if updated.userID != session.userID || updated.endpoints != session.endpoints {
            do { try vault.save(updated) } catch { message = errorText(error) }
        }
        saved = updated
        profile = value
        panelOffline = false
        announcementState.configure(site: endpoints.site, userID: value.id)
        nodeProbes.configure(site: endpoints.site, userID: value.id)
        if nodeSelections.isEmpty { nodeSelections = nodeProbes.savedSelections() }
        trafficRank.configure(site: endpoints.site, userID: value.id)
        stopKickedConnection()
        accountStatus = nil
        updatedAt = now()
    }

    // 对应 auth_controller.dart 的 _offerOrigin：面板下发的地址与当前不同就先不带令牌探一次，收到任何 HTTP 响应才切换并落盘，
    // 网络层失败保持当前地址，同一新地址 10 分钟内只探一次。回退到出包地址后面板仍会下发那个连不上的旧地址，不探就会来回切换
    private func applyOrigins(site: String, config: String) {
        let site = (try? PanelEndpoints.origin(site)) ?? endpoints.site
        let config = (try? PanelEndpoints.origin(config)) ?? endpoints.config
        guard let delivered = try? endpoints.updating(site: site.absoluteString, config: config.absoluteString) else { return }
        guard delivered != endpoints else {
            offered = [:]
            vault.endpoints = delivered
            return
        }
        var probes: [(URL, Bool)] = []
        for config in [false, true] {
            let next = config ? delivered.config : delivered.site
            guard next != (config ? endpoints.config : endpoints.site) else { offered[config] = nil; continue }
            offered[config] = next
            let key = (config ? "config " : "site ") + next.absoluteString
            if let last = probedAt[key], now().timeIntervalSince(last) < 600 { continue }
            probedAt[key] = now()
            probes.append((next, config))
        }
        guard !probes.isEmpty else { return }
        let previous = originProbe
        originProbe = Task { [weak self, api] in
            await previous?.value
            for (origin, config) in probes {
                let reachable = await api.probe(origin, config: config)
                self?.adopt(origin, config: config, reachable: reachable)
            }
        }
    }

    private func adopt(_ origin: URL, config: Bool, reachable: Bool) {
        guard reachable, offered[config] == origin,
              let next = try? endpoints.updating(site: (config ? endpoints.site : origin).absoluteString,
                                                 config: (config ? origin : endpoints.config).absoluteString) else { return }
        offered[config] = nil
        unreachable[(config ? "config " : "site ") + origin.absoluteString] = nil
        endpoints = next
        persistOrigin(origin, config: config)
    }

    // 对应 auth_controller.dart 的 _reach：连续 3 次网络层失败且已持续 10 分钟，才在持久化地址与出包地址之间切换（只限这两个 https 地址）；
    // 出包地址恢复可达后落盘
    private func reached(_ url: URL, _ reachable: Bool) {
        let persisted = saved?.endpoints ?? vault.endpoints ?? bundled
        for config in [false, true] {
            let current = config ? endpoints.config : endpoints.site
            guard url.scheme == current.scheme, url.host == current.host, url.port == current.port else { continue }
            let original = config ? bundled.config : bundled.site, stored = config ? persisted.config : persisted.site
            let key = (config ? "config " : "site ") + current.absoluteString
            if reachable {
                unreachable[key] = nil
                if current == original, stored != original { persistOrigin(original, config: config) }
                continue
            }
            let streak = (failures: (unreachable[key]?.failures ?? 0) + 1, since: unreachable[key]?.since ?? now())
            unreachable[key] = streak
            let next = current == original ? stored : original
            guard streak.failures >= 3, now().timeIntervalSince(streak.since) >= 600, next != current,
                  let updated = try? endpoints.updating(site: (config ? endpoints.site : next).absoluteString,
                                                        config: (config ? next : endpoints.config).absoluteString) else { continue }
            unreachable[key] = nil
            endpoints = updated
        }
    }

    private func persistOrigin(_ origin: URL, config: Bool) {
        let persisted = saved?.endpoints ?? vault.endpoints ?? bundled
        guard let next = try? persisted.updating(site: (config ? persisted.site : origin).absoluteString,
                                                 config: (config ? origin : persisted.config).absoluteString) else { return }
        vault.endpoints = next
        guard let session = saved else { return }
        let updated = StoredSession(token: session.token, expiresAt: session.expiresAt, email: session.email, userID: session.userID, endpoints: next)
        if (try? vault.save(updated)) != nil { saved = updated }
    }

    // 受限、启动时令牌过期或上次清理未完成时并未进入已登录态，归属仍按本机保存的会话计算
    private func clearLocal() -> Bool {
        let previous = saved ?? (try? vault.load())
        let owner = previous.map(Self.owner)
        if let owner { icons.configure(owner: owner) }
        icons.clear()
        nodeProbes.configure(site: nil, userID: nil)
        trafficRank.configure(site: nil, userID: nil)
        connection?.disconnect(clearLogsFor: owner, account: previous.map(Self.accountKey))
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
        (error as? ClientError)?.localizedDescription ?? (error as? TunnelError)?.localizedDescription
            ?? (error as? ProfileValidationError)?.localizedDescription ?? L10n.t("操作未完成，请稍后重试。")
    }
}
