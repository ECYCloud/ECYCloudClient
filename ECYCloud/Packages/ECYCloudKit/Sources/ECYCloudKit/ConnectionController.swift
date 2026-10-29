import Foundation
import Observation

public struct TunnelLease: Codable, Sendable {
    public let id: UUID
    public let owner: String
    public let expiresAt: Date
    public let configuration: Data
    public let validationConfiguration: Data?
    public let logLevel: String?
    public init(owner: String, expiresAt: Date, configuration: Data, validationConfiguration: Data? = nil, logLevel: String? = nil) {
        id = UUID(); self.owner = owner; self.expiresAt = expiresAt; self.configuration = configuration
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
}

public protocol StandbyRuntime: Actor {
    func start(_ lease: TunnelLease) async throws
    func stop() async
    func request(_ command: TunnelCommand) async throws -> Data
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
    func stop()
    func waitUntilStopped() async throws
    func request(_ command: TunnelCommand) async throws -> Data
    func clearCache(owner: String) async
    var panelProxyPort: Int? { get }
}

public extension TunnelDriver {
    var failureOccurred: (@MainActor (TunnelError) -> Void)? { get { nil } set {} }
    func clearCache(owner: String) async {}
    func profileOptions(_ preferences: ClientPreferences) throws -> ProfileOptions { preferences.packetProfile }
    var supportsStandby: Bool { false }
    var restoredConfiguration: Data? { nil }
    func startStandby(_ lease: TunnelLease) async throws { throw TunnelError.unavailable }
    func waitUntilStopped() async throws {}
    func request(_ command: TunnelCommand) async throws -> Data { throw TunnelError.unavailable }
    var panelProxyPort: Int? { nil }
}

public enum TunnelError: Error, LocalizedError, Equatable {
    case configuration, permission, unavailable, start, expired, control, helperUnavailable, installation
    public var errorDescription: String? {
        switch self {
        case .configuration: L10n.t("VPN 配置无效，请刷新节点后重试。")
        case .permission: L10n.t("无法保存系统 VPN 配置，请检查是否允许添加 VPN，以及扩展的签名和权限。")
        case .unavailable: L10n.t("此构建未包含可用的 VPN 扩展。")
        case .start: L10n.t("VPN 未能启动，请重新连接。")
        case .control: L10n.t("无法读取或修改内核运行状态，请刷新后重试。")
        case .expired: L10n.t("登录已过期，请重新登录。")
        case .helperUnavailable: L10n.t("后台服务未安装或不可用，请重新运行完整的 macOS 安装包。")
        case .installation: L10n.t("请运行完整的 macOS 安装包，然后从“应用程序”打开 ECYCloud。")
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
    public private(set) var runtimeConfiguration: Data?
    public var supportsStandby: Bool { driver.supportsStandby }
    var panelProxyPort: Int? { state == .connected ? driver.panelProxyPort : nil }
    @ObservationIgnored private let driver: any TunnelDriver
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var owner: String?
    @ObservationIgnored private var expirationDate: Date?
    @ObservationIgnored private var expiration: Task<Void, Never>?
    @ObservationIgnored private var standbyTask: Task<Void, Error>?
    @ObservationIgnored private var transitioning = false
    @ObservationIgnored var runtimeDidReset: ((_ keepingResults: Bool) -> Void)?
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
        driver.failureOccurred = { [weak self] error in self?.message = error.localizedDescription }
    }
    public func reconcile(owner: String?, expiresAt: Date?) async {
        if let expiresAt, expiresAt <= Date() { disconnect(); return }
        if let owner, owner == self.owner, expiresAt == expirationDate { return }
        let ownerChanged = owner != self.owner
        if ownerChanged {
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
                self?.disconnect()
                self?.message = TunnelError.expired.localizedDescription
            }
        }
        if ownerChanged || owner == nil {
            let operation = generation
            await driver.reconcile(owner: owner)
            if generation == operation, controlPlaneReady { runtimeConfiguration = driver.restoredConfiguration }
        }
    }
    public func connect(_ lease: TunnelLease) async {
        guard state == .disconnected, owner == lease.owner else { return }
        guard lease.expiresAt > Date() else { message = TunnelError.expired.localizedDescription; return }
        generation += 1
        let operation = generation
        let pending = standbyTask
        pending?.cancel()
        let mustStop = controlPlaneReady || preparingStandby
        controlPlaneReady = false
        runtimeDidReset?(true)
        transitioning = true
        state = .preparing; message = nil
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
            runtimeConfiguration = lease.configuration
            if state == .preparing { state = .connecting }
        } catch {
            guard operation == generation else { return }
            transitioning = false
            standbyTask = nil; preparingStandby = false
            driver.stop()
            if state != .disconnecting { state = .disconnected }
            if !(error is CancellationError) { message = (error as? TunnelError)?.localizedDescription ?? TunnelError.start.localizedDescription }
        }
    }
    public func prepareStandby(_ lease: TunnelLease) async throws {
        guard owner == lease.owner, lease.expiresAt > Date() else { throw TunnelError.expired }
        if controlPlaneReady { return }
        if let standbyTask { return try await standbyTask.value }
        guard supportsStandby, state == .disconnected, !transitioning else { throw TunnelError.control }
        generation += 1
        let operation = generation
        preparingStandby = true
        let task = Task {
            defer {
                if operation == generation { standbyTask = nil; preparingStandby = false }
            }
            do {
                try await driver.startStandby(lease)
                try Task.checkCancellation()
                guard operation == generation, owner == lease.owner else { throw CancellationError() }
                controlPlaneReady = true
                runtimeConfiguration = lease.configuration
                message = nil
            } catch {
                if operation == generation {
                    standbyTask = nil; preparingStandby = false
                    driver.stop()
                    if !(error is CancellationError) { message = error.localizedDescription }
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
        generation += 1
        let operation = generation
        transitioning = true
        controlPlaneReady = false
        runtimeDidReset?(true)
        state = .disconnecting
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
        if takeover { await connect(lease) }
        else { try await prepareStandby(lease) }
    }
    public func profileOptions(_ preferences: ClientPreferences) throws -> ProfileOptions { try driver.profileOptions(preferences) }
    public func request(_ command: TunnelCommand) async throws -> Data {
        guard controlPlaneReady, owner != nil else { throw TunnelError.control }
        let operation = generation
        let data = try await driver.request(command)
        try Task.checkCancellation()
        guard operation == generation, controlPlaneReady, owner != nil else { throw CancellationError() }
        guard !data.isEmpty, data.count <= 65536 else { throw TunnelError.control }
        return data
    }
    public func disconnect(clearLogsFor previousOwner: String? = nil) {
        let logs = previousOwner.flatMap(ClientLogStore.directory)
        generation += 1
        transitioning = false
        controlPlaneReady = false
        runtimeConfiguration = nil
        standbyTask?.cancel(); standbyTask = nil; preparingStandby = false
        runtimeDidReset?(false)
        message = nil
        expiration?.cancel(); expiration = nil
        owner = nil; expirationDate = nil
        driver.stop()
        if state != .disconnected { state = .disconnecting }
        if let previousOwner {
            Task {
                do {
                    try await driver.waitUntilStopped()
                    guard owner != previousOwner else { return }
                    await driver.clearCache(owner: previousOwner)
                    if let logs { try FileManager.default.removeItem(at: logs) }
                } catch {}
            }
        }
    }
    public func shutdown() async throws {
        disconnect()
        try await driver.waitUntilStopped()
    }
}
