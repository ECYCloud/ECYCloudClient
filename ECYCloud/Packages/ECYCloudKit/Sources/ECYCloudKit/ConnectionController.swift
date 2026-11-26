import Foundation
import Observation

public struct TunnelLease: Codable, Sendable {
    public let id: UUID
    public let owner: String
    public let cacheKey: String
    public let expiresAt: Date
    public let configuration: Data
    public let validationConfiguration: Data?
    public let logLevel: String?
    public init(id: UUID = UUID(), owner: String, cacheKey: String? = nil, expiresAt: Date, configuration: Data, validationConfiguration: Data? = nil, logLevel: String? = nil) {
        self.id = id; self.owner = owner; self.cacheKey = cacheKey ?? owner; self.expiresAt = expiresAt; self.configuration = configuration
        self.validationConfiguration = validationConfiguration
        self.logLevel = logLevel
    }
    func validate(owner: String, id: UUID, now: Date = .now) throws {
        guard self.id == id, self.owner == owner, expiresAt > now else { throw TunnelError.expired }
        guard !configuration.isEmpty, configuration.count <= URLSessionTransport.maximumResponseBytes else { throw TunnelError.configuration }
    }
}

public enum ConnectionState: String, Sendable {
    case disconnected, preparing, connecting, connected, reconnecting, disconnecting
    public var title: String {
        switch self {
        case .disconnected: L10n.t("未连接")
        case .preparing: L10n.t("正在准备配置")
        case .connecting: L10n.t("正在连接")
        case .connected: L10n.t("已连接")
        case .reconnecting: L10n.t("正在重新连接")
        case .disconnecting: L10n.t("正在断开")
        }
    }
    // 按需连接开着的包隧道断开后的去向：应用发起的启动进入连接后又断开是启动失败；租约有效时系统会重新拉起。
    // startVPNTunnel 返回时系统状态可能还没离开已断开
    static func tunnelDisconnected(starting: Bool, progressed: Bool, leaseValid: @autoclosure () -> Bool) -> ConnectionState {
        if starting && progressed || !leaseValid() { return .disconnected }
        return starting ? .connecting : .reconnecting
    }
}

public protocol StandbyRuntime: Actor {
    func start(_ lease: TunnelLease) async throws
    func stop() async
    func request(_ command: TunnelCommand) async throws -> Data
    func updateNodes(_ lease: TunnelLease) async throws -> Bool
}

@MainActor public protocol TunnelDriver: AnyObject {
    var statusChanged: (@MainActor (ConnectionState) -> Void)? { get set }
    var failureOccurred: (@MainActor (TunnelError) -> Void)? { get set }
    func reconcile(owner: String?) async
    func profileOptions(_ preferences: ClientPreferences) throws -> ProfileOptions
    func start(_ lease: TunnelLease) async throws
    var supportsStandby: Bool { get }
    var restoredConfiguration: Data? { get }
    func startStandby(_ lease: TunnelLease) async throws
    func liveProfileOptions(_ preferences: ClientPreferences) throws -> ProfileOptions?
    func updateNodes(_ lease: TunnelLease) async throws -> Bool
    func stop()
    func stopStandby()
    func waitUntilStopped() async throws
    func request(_ command: TunnelCommand) async throws -> Data
    func clearCache(account: String) async
    func applySystemProxy(enabled: Bool, bypass: [String]) async throws
    var panelProxyPort: Int? { get }
}

public extension TunnelDriver {
    var failureOccurred: (@MainActor (TunnelError) -> Void)? { get { nil } set {} }
    func clearCache(account: String) async {}
    func applySystemProxy(enabled: Bool, bypass: [String]) async throws {}
    func profileOptions(_ preferences: ClientPreferences) throws -> ProfileOptions { preferences.packetProfile }
    var supportsStandby: Bool { false }
    var restoredConfiguration: Data? { nil }
    func startStandby(_ lease: TunnelLease) async throws { throw TunnelError.unavailable }
    func liveProfileOptions(_ preferences: ClientPreferences) throws -> ProfileOptions? { nil }
    func updateNodes(_ lease: TunnelLease) async throws -> Bool { false }
    func stopStandby() { stop() }
    func waitUntilStopped() async throws {}
    func request(_ command: TunnelCommand) async throws -> Data { throw TunnelError.unavailable }
    var panelProxyPort: Int? { nil }
}

public enum TunnelError: Error, LocalizedError, Equatable {
    case configuration, permission, unavailable, start, expired, control, helperUnavailable, helperTimeout, installation, proxyRestore, noNodes
    case mixedPortInUse(Int), controllerPortInUse(Int), speedPortInUse(Int)
    case failed(String), exited(String)
    public var errorDescription: String? {
        switch self {
        case .configuration: L10n.t("VPN 配置无效，请刷新节点后重试。")
        case .permission: L10n.t("无法保存系统 VPN 配置，请检查是否允许添加 VPN，以及扩展的签名和权限。")
        case .unavailable: L10n.t("此构建未包含可用的 VPN 扩展。")
        case .start: L10n.t("VPN 未能启动，请重新连接。")
        case .control: L10n.t("无法读取或修改内核运行状态，请刷新后重试。")
        case .expired: L10n.t("登录已过期，请重新登录。")
        case .helperUnavailable: L10n.t("后台服务未安装或不可用，请重新运行完整的 macOS 安装包。")
        case .helperTimeout: L10n.t("后台服务响应超时")
        case .installation: L10n.t("请运行完整的 macOS 安装包，然后从“应用程序”打开 ECYCloud。")
        case .proxyRestore: L10n.t("系统代理还原失败，请在系统设置中检查网络代理。")
        case .noNodes: L10n.t("面板未下发任何可用节点")
        case .failed(let text), .exited(let text): text
        case .mixedPortInUse(let port): L10n.t("混合端口 {0} 已被其它程序占用，请在设置中更换端口后重新连接", [String(port)])
        case .controllerPortInUse(let port): L10n.t("控制面端口 {0} 已被其它程序占用，请重新连接", [String(port)])
        case .speedPortInUse(let port): L10n.t("测速端口 {0}（混合端口 + 1）已被其它程序占用，请在设置中更换混合端口后重新连接", [String(port)])
        }
    }
}

@MainActor @Observable public final class ConnectionController {
    public private(set) var state: ConnectionState = .disconnected {
        didSet { if state != oldValue { connectedAt = state == .connected ? Date() : nil } }
    }
    public private(set) var connectedAt: Date?
    public private(set) var controlPlaneReady = false
    public private(set) var preparingStandby = false
    public private(set) var message: String?
    // 对应 connection_controller.dart 的 _standbyError
    public private(set) var standbyMessage: String?
    public private(set) var runtimeConfiguration: Data?
    public var supportsStandby: Bool { driver.supportsStandby }
    var panelProxyPort: Int? { state == .connected ? driver.panelProxyPort : nil }
    var leaseExpiry: Date? { lastLaunch?.lease.expiresAt }
    @ObservationIgnored private let driver: any TunnelDriver
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var owner: String?
    @ObservationIgnored private var expirationDate: Date?
    @ObservationIgnored private var expiration: Task<Void, Never>?
    @ObservationIgnored private var standbyTask: Task<Void, Error>?
    @ObservationIgnored private var reconciling: Task<Void, Never>?
    @ObservationIgnored private var transitioning = false
    @ObservationIgnored private var authorizationExpiry = false
    @ObservationIgnored private var lastLaunch: (lease: TunnelLease, takeover: Bool)?
    @ObservationIgnored private var restartAttempt = 0
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var relaunching = false
    // 与 connection_controller.dart 的 _backoff 一致
    @ObservationIgnored var restartBackoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]
    @ObservationIgnored var runtimeDidReset: ((_ keepingResults: Bool) -> Void)?
    // 对应 connection_controller.dart 重启前的 _captureSelectorSnapshot / _rebuildProfile：按当前的模式与节点选择重新装配
    @ObservationIgnored var relaunchLease: ((_ takeover: Bool) -> TunnelLease?)?
    public init(driver: any TunnelDriver) {
        self.driver = driver
        driver.statusChanged = { [weak self] state in
            guard let self else { return }
            if self.owner == nil && state != .disconnected && state != .disconnecting { return }
            if self.transitioning && (state == .disconnected || state == .disconnecting) { return }
            if state == .disconnected, self.state == .disconnected, !self.controlPlaneReady { return }
            self.state = state
            self.controlPlaneReady = state == .connected
            if state == .disconnected { self.generation += 1; self.runtimeConfiguration = nil; self.runtimeDidReset?(false) }
        }
        driver.failureOccurred = { [weak self] error in
            guard let self else { return }
            if case .exited(let reason) = error, self.owner != nil, let launch = self.lastLaunch { self.kernelExited(reason, launch) }
            else { self.message = error.localizedDescription }
        }
    }
    private var expiryNotice: String {
        authorizationExpiry ? L10n.t("本地配置授权已到期，请连接面板更新后重试") : TunnelError.expired.localizedDescription
    }
    public func reconcile(owner: String?, expiresAt: Date?, authorizationExpiry: Bool = false) async {
        self.authorizationExpiry = authorizationExpiry
        if let expiresAt, expiresAt <= Date() { disconnect(); return }
        if let owner, owner == self.owner, expiresAt == expirationDate { return }
        let ownerChanged = owner != self.owner
        if ownerChanged {
            cancelRestart()
            runtimeConfiguration = nil
            generation += 1
            standbyTask?.cancel(); standbyTask = nil; preparingStandby = false
            controlPlaneReady = false
            runtimeDidReset?(false)
        }
        self.owner = owner
        expirationDate = expiresAt
        expiration?.cancel()
        if let expiresAt {
            let duration = expiresAt.timeIntervalSinceNow
            guard duration > 0 else { disconnect(); return }
            expiration = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(duration)) } catch { return }
                guard let self else { return }
                self.disconnect()
                self.message = self.expiryNotice
            }
        }
        if ownerChanged || owner == nil {
            let operation = generation
            let task = Task { [driver] in await driver.reconcile(owner: owner) }
            reconciling = task
            await task.value
            if reconciling == task { reconciling = nil }
            if generation == operation, controlPlaneReady { runtimeConfiguration = driver.restoredConfiguration }
        }
    }
    public func connect(_ lease: TunnelLease) async {
        await reconciling?.value
        guard state == .disconnected, owner == lease.owner else { return }
        guard lease.expiresAt > Date() else { message = expiryNotice; return }
        if !relaunching { cancelRestart() }
        generation += 1
        let operation = generation
        let pending = standbyTask
        pending?.cancel()
        let mustStop = controlPlaneReady || preparingStandby
        controlPlaneReady = false
        runtimeDidReset?(true)
        transitioning = true
        state = .preparing; message = nil; standbyMessage = nil
        do {
            if mustStop {
                driver.stop()
                _ = try? await pending?.value
            }
            try await driver.waitUntilStopped()
            guard operation == generation else { return }
            standbyTask = nil; preparingStandby = false
            transitioning = false
            try await driver.start(lease)
            guard operation == generation else { return }
            lastLaunch = (lease, true)
            runtimeConfiguration = lease.configuration
            if state == .preparing { state = .connecting }
        } catch {
            guard operation == generation else { return }
            transitioning = false
            standbyTask = nil; preparingStandby = false
            driver.stop()
            if state != .disconnecting { state = .disconnected }
            if !(error is CancellationError) { message = (error as? TunnelError)?.localizedDescription ?? Self.startFailure }
        }
    }
    public func prepareStandby(_ lease: TunnelLease) async throws {
        await reconciling?.value
        guard owner == lease.owner, lease.expiresAt > Date() else { throw TunnelError.expired }
        if controlPlaneReady { return }
        if let standbyTask { return try await standbyTask.value }
        guard supportsStandby else { throw TunnelError.control }
        guard state == .disconnected, !transitioning else { throw CancellationError() }
        if !relaunching { cancelRestart() }
        generation += 1
        let operation = generation
        preparingStandby = true
        standbyMessage = nil
        let task = Task {
            defer {
                if operation == generation { standbyTask = nil; preparingStandby = false }
            }
            do {
                try await driver.startStandby(lease)
                try Task.checkCancellation()
                guard operation == generation, owner == lease.owner else { throw CancellationError() }
                controlPlaneReady = true
                lastLaunch = (lease, false)
                runtimeConfiguration = lease.configuration
            } catch {
                if operation == generation {
                    standbyTask = nil; preparingStandby = false
                    driver.stopStandby()
                    if !(error is CancellationError) { standbyMessage = error.localizedDescription }
                }
                throw error
            }
        }
        standbyTask = task
        try await task.value
    }
    public func returnToStandby(_ lease: TunnelLease) async throws {
        try await restart(lease, takeover: false)
    }
    public func restart(_ lease: TunnelLease, takeover: Bool) async throws {
        guard (state == .connected || state == .disconnected), controlPlaneReady, owner == lease.owner else { throw TunnelError.control }
        cancelRestart()
        generation += 1
        let operation = generation
        transitioning = true
        controlPlaneReady = false
        runtimeDidReset?(true)
        state = .disconnecting
        message = nil
        driver.stop()
        do { try await driver.waitUntilStopped() }
        catch {
            if operation == generation { transitioning = false; message = error.localizedDescription }
            throw error
        }
        guard operation == generation else { throw CancellationError() }
        transitioning = false
        state = .disconnected
        runtimeConfiguration = nil
        let notice = message
        if takeover { await connect(lease) }
        else { try await prepareStandby(lease); message = message ?? notice }
    }
    public func profileOptions(_ preferences: ClientPreferences) throws -> ProfileOptions { try driver.profileOptions(preferences) }
    func liveProfileOptions(_ preferences: ClientPreferences) throws -> ProfileOptions? {
        controlPlaneReady && (state == .connected || state == .disconnected) ? try driver.liveProfileOptions(preferences) : nil
    }
    // 对应 connection_controller.dart 的 _hotReloadPanelProfile：只有节点变化时不重启内核，已有连接不断开。
    // 待机内核同样适用：选用或测试未装入的节点（NodeWorkingSet）时只重读节点文件
    func updateNodes(_ lease: TunnelLease) async throws -> Bool {
        guard controlPlaneReady, state == .connected || state == .disconnected, owner == lease.owner else { return false }
        let takeover = state == .connected
        let operation = generation
        guard try await driver.updateNodes(lease) else { return false }
        guard operation == generation else { throw CancellationError() }
        lastLaunch = (lease, takeover)
        runtimeConfiguration = lease.configuration
        return true
    }
    public func applySystemProxy(_ preferences: ClientPreferences) async throws {
        try await driver.applySystemProxy(enabled: preferences.systemProxy, bypass: preferences.systemProxyBypass)
    }
    public func request(_ command: TunnelCommand) async throws -> Data {
        guard controlPlaneReady, owner != nil else { throw TunnelError.control }
        let operation = generation
        let data = try await driver.request(command)
        try Task.checkCancellation()
        guard operation == generation, controlPlaneReady, owner != nil else { throw CancellationError() }
        guard !data.isEmpty, data.count <= URLSessionTransport.maximumResponseBytes else { throw TunnelError.control }
        return data
    }
    public func disconnect(clearLogsFor previousOwner: String? = nil, account: String? = nil) {
        let logs = previousOwner.flatMap(ClientLogStore.directory)
        cancelRestart()
        lastLaunch = nil
        generation += 1
        transitioning = false
        controlPlaneReady = false
        runtimeConfiguration = nil
        standbyTask?.cancel(); standbyTask = nil; preparingStandby = false
        runtimeDidReset?(false)
        message = nil; standbyMessage = nil
        expiration?.cancel(); expiration = nil
        owner = nil; expirationDate = nil
        driver.stop()
        if state != .disconnected { state = .disconnecting }
        if let previousOwner {
            Task {
                do {
                    try await driver.waitUntilStopped()
                    guard owner != previousOwner else { return }
                    if let account { await driver.clearCache(account: account) }
                    if let logs { try FileManager.default.removeItem(at: logs) }
                } catch {}
            }
        }
    }
    #if os(macOS)
    static var startFailure: String { L10n.t("内核启动失败，请重试") }
    #else
    static var startFailure: String { TunnelError.start.localizedDescription }
    #endif
    private func cancelRestart() {
        restartTask?.cancel(); restartTask = nil
        restartAttempt = 0
    }
    // 对应 connection_controller.dart 的 _onKernelStatus / _scheduleRestart：非用户停止的内核退出按退避重启，接管与待机各自恢复
    private func kernelExited(_ reason: String, _ launch: (lease: TunnelLease, takeover: Bool)) {
        generation += 1
        standbyTask?.cancel(); standbyTask = nil; preparingStandby = false
        transitioning = true
        controlPlaneReady = false
        runtimeConfiguration = nil
        runtimeDidReset?(true)
        state = launch.takeover ? .reconnecting : .disconnected
        func notify(_ text: String) { if launch.takeover { message = text } else { standbyMessage = text } }
        guard restartAttempt < restartBackoff.count else {
            transitioning = false
            state = .disconnected
            lastLaunch = nil
            restartAttempt = 0
            notify(L10n.t("{0}；连续重启 {1} 次仍未成功，已停止重试", [reason, String(restartBackoff.count)]))
            return
        }
        notify(reason)
        let delay = restartBackoff[restartAttempt]
        restartAttempt += 1
        let operation = generation
        restartTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            try? await self.driver.waitUntilStopped()
            guard !Task.isCancelled, operation == self.generation, self.owner == launch.lease.owner else { return }
            let lease = self.relaunchLease?(launch.takeover) ?? launch.lease
            guard lease.owner == launch.lease.owner, lease.expiresAt > Date() else { return }
            self.restartTask = nil
            self.transitioning = false
            self.state = .disconnected
            self.relaunching = true
            if launch.takeover { await self.connect(lease) } else { try? await self.prepareStandby(lease) }
            self.relaunching = false
            guard !Task.isCancelled, self.lastLaunch != nil, self.owner == lease.owner else { return }
            if [.disconnected, .disconnecting].contains(self.state), !self.controlPlaneReady {
                self.kernelExited((launch.takeover ? self.message : self.standbyMessage) ?? reason, (lease, launch.takeover))
            } else {
                self.restartAttempt = 0
            }
        }
    }
    public func shutdown() async throws {
        disconnect()
        try await driver.waitUntilStopped()
    }
}
