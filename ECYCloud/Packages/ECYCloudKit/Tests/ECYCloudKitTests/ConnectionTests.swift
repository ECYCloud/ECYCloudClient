import Foundation
import Testing
@testable import ECYCloudKit

/// 套件里的会话、图标、流量排行与日志一律落在本套件的临时目录，结束即删，不读写本机 Application Support/ECYCloud
struct IsolatedUserData: SuiteTrait, TestScoping {
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ecycloud-user-data-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await UserDataDirectory.$override.withValue(root, operation: function)
    }
}

extension Trait where Self == IsolatedUserData {
    static var isolatedUserData: Self { Self() }
}

@MainActor final class RecordingTunnelDriver: TunnelDriver {
    var statusChanged: (@MainActor (ConnectionState) -> Void)?
    var failureOccurred: (@MainActor (TunnelError) -> Void)?
    var clearedAccounts: [String] = []
    var systemProxyChanges: [Bool] = []
    func clearCache(account: String) async { clearedAccounts.append(account) }
    func applySystemProxy(enabled: Bool, bypass: [String]) async throws { systemProxyChanges.append(enabled) }
    var starts: [TunnelLease] = []
    var stopCount = 0
    var suspended = false
    var failure: TunnelError?
    var pending: CheckedContinuation<Void, Never>?
    var commands: [TunnelCommand] = []
    var controlFailure: TunnelError?
    var controlResponses: [Data] = []
    var controlDelay: Duration?
    var activeControls = 0
    var maximumActiveControls = 0
    var supportsStandby = false
    var restoredConfiguration: Data?
    var updatesNodes = false
    var nodeUpdates: [TunnelLease] = []
    var nodeUpdateFailure: TunnelError?
    func liveProfileOptions(_ preferences: ClientPreferences) throws -> ProfileOptions? { updatesNodes ? preferences.packetProfile : nil }
    func updateNodes(_ lease: TunnelLease) async throws -> Bool {
        if let nodeUpdateFailure { throw nodeUpdateFailure }
        if updatesNodes { nodeUpdates.append(lease) }
        return updatesNodes
    }
    var standbyStarts: [TunnelLease] = []
    func startStandby(_ lease: TunnelLease) async throws {
        standbyStarts.append(lease)
        if suspended { await withCheckedContinuation { pending = $0 } }
        if let failure { throw failure }
    }
    var reconcileSuspended = false
    var reconcilePending: CheckedContinuation<Void, Never>?
    func reconcile(owner: String?) async {
        if reconcileSuspended { await withCheckedContinuation { reconcilePending = $0 } }
        if owner == nil { stop() }
        else if restoredConfiguration != nil { statusChanged?(.connected) }
    }
    func start(_ lease: TunnelLease) async throws {
        starts.append(lease)
        if suspended { await withCheckedContinuation { pending = $0 } }
        if let failure { throw failure }
    }
    func stop() { stopCount += 1; statusChanged?(.disconnected) }
    var standbyStops = 0
    func stopStandby() { standbyStops += 1; stop() }
    func request(_ command: TunnelCommand) async throws -> Data {
        commands.append(command)
        activeControls += 1
        maximumActiveControls = max(maximumActiveControls, activeControls)
        defer { activeControls -= 1 }
        if let controlDelay { try await Task.sleep(for: controlDelay) }
        if let controlFailure { throw controlFailure }
        if !controlResponses.isEmpty { return controlResponses.removeFirst() }
        return Data(#"{"ok":true}"#.utf8)
    }
}

@Suite("连接生命周期", .timeLimit(.minutes(1))) @MainActor
struct ConnectionTests {
    private func lease(owner: String = "synthetic-owner", expiry: Date = .now.addingTimeInterval(3600)) -> TunnelLease {
        TunnelLease(owner: owner, expiresAt: expiry, configuration: Data("synthetic-config".utf8))
    }
    @Test func sharedConfigurationRejectsAnotherAccountGenerationAndExpiry() throws {
        let value = lease()
        let decoded = try JSONDecoder().decode(TunnelLease.self, from: JSONEncoder().encode(value))
        try decoded.validate(owner: value.owner, id: value.id)
        #expect(throws: TunnelError.expired) { try decoded.validate(owner: "different-owner", id: value.id) }
        #expect(throws: TunnelError.expired) { try decoded.validate(owner: value.owner, id: UUID()) }
        #expect(throws: TunnelError.expired) { try decoded.validate(owner: value.owner, id: value.id, now: value.expiresAt) }
        let empty = TunnelLease(owner: value.owner, expiresAt: value.expiresAt, configuration: Data())
        #expect(throws: TunnelError.configuration) { try empty.validate(owner: empty.owner, id: empty.id) }
    }

    @Test func connectionOnlyBecomesConnectedAfterSystemNotification() async {
        let driver = RecordingTunnelDriver(), value = lease()
        let controller = ConnectionController(driver: driver)
        await controller.reconcile(owner: value.owner, expiresAt: value.expiresAt)
        await controller.connect(value)
        #expect(driver.starts.count == 1 && controller.state == .connecting)
        driver.statusChanged?(.connected)
        #expect(controller.state == .connected)
        driver.statusChanged?(.reconnecting)
        #expect(controller.state == .reconnecting)
        controller.disconnect()
        #expect(driver.stopCount == 1 && controller.state == .disconnected)
    }
    @Test func restoredVPNExposesActualConfigurationAndClearsItOnLogout() async {
        let driver = RecordingTunnelDriver(), value = lease()
        driver.restoredConfiguration = value.configuration
        let controller = ConnectionController(driver: driver)
        await controller.reconcile(owner: value.owner, expiresAt: value.expiresAt)
        #expect(controller.state == .connected && controller.runtimeConfiguration == value.configuration)
        controller.disconnect()
        #expect(controller.runtimeConfiguration == nil)
    }
    @Test func cancellationWhileSavingCannotRestoreConnectingState() async {
        let driver = RecordingTunnelDriver(), value = lease()
        driver.suspended = true
        let controller = ConnectionController(driver: driver)
        await controller.reconcile(owner: value.owner, expiresAt: value.expiresAt)
        let work = Task { await controller.connect(value) }
        while driver.pending == nil { await Task.yield() }
        controller.disconnect()
        driver.pending?.resume(); driver.pending = nil
        await work.value
        #expect(controller.state == .disconnected && driver.stopCount == 1)
    }
    @Test func runtimeRestartDiscardsPendingControlResponse() async {
        let driver = RecordingTunnelDriver(), value = lease()
        driver.controlDelay = .milliseconds(30)
        let controller = ConnectionController(driver: driver)
        await controller.reconcile(owner: value.owner, expiresAt: value.expiresAt)
        driver.statusChanged?(.connected)
        let pending = Task { try await controller.request(.init(.snapshot)) }
        while driver.activeControls == 0 { await Task.yield() }
        driver.statusChanged?(.disconnected)
        driver.statusChanged?(.connected)
        await #expect(throws: CancellationError.self) { try await pending.value }
    }
    @Test func standbySharesStartupAndDoesNotClaimVPNConnection() async throws {
        let driver = RecordingTunnelDriver(), value = lease()
        driver.supportsStandby = true; driver.suspended = true
        let controller = ConnectionController(driver: driver)
        await controller.reconcile(owner: value.owner, expiresAt: value.expiresAt)
        let first = Task { try await controller.prepareStandby(value) }
        while driver.pending == nil { await Task.yield() }
        let second = Task { try await controller.prepareStandby(value) }
        await Task.yield()
        #expect(controller.state == .disconnected && controller.preparingStandby && !controller.controlPlaneReady)
        driver.pending?.resume(); driver.pending = nil
        try await first.value; try await second.value
        #expect(driver.standbyStarts.count == 1 && driver.starts.isEmpty)
        #expect(controller.state == .disconnected && controller.controlPlaneReady && !controller.preparingStandby)
        _ = try await controller.request(.init(.snapshot))
        controller.disconnect()
        #expect(!controller.controlPlaneReady)
        await #expect(throws: TunnelError.control) { try await controller.request(.init(.snapshot)) }
    }
    @Test func standbyVPNAndBackInvalidateOldProbeWithoutDroppingOwner() async throws {
        let driver = RecordingTunnelDriver(), value = lease()
        driver.supportsStandby = true
        let controller = ConnectionController(driver: driver)
        await controller.reconcile(owner: value.owner, expiresAt: value.expiresAt)
        try await controller.prepareStandby(value)
        driver.controlDelay = .milliseconds(30)
        let pending = Task { try await controller.request(.init(.snapshot)) }
        while driver.activeControls == 0 { await Task.yield() }
        await controller.connect(value)
        #expect(driver.stopCount == 1 && driver.starts.count == 1 && controller.state == .connecting)
        driver.statusChanged?(.connected)
        await #expect(throws: CancellationError.self) { try await pending.value }
        try await controller.returnToStandby(value)
        #expect(driver.stopCount == 2 && driver.standbyStarts.count == 2)
        #expect(controller.state == .disconnected && controller.controlPlaneReady)
        controller.disconnect()
    }
    @Test func logoutDuringStandbyPreparationCannotRestoreControl() async {
        let driver = RecordingTunnelDriver(), value = lease()
        driver.supportsStandby = true; driver.suspended = true
        let controller = ConnectionController(driver: driver)
        await controller.reconcile(owner: value.owner, expiresAt: value.expiresAt)
        let pending = Task { try await controller.prepareStandby(value) }
        while driver.pending == nil { await Task.yield() }
        controller.disconnect()
        driver.pending?.resume(); driver.pending = nil
        await #expect(throws: CancellationError.self) { try await pending.value }
        driver.statusChanged?(.connected)
        #expect(!controller.controlPlaneReady && !controller.preparingStandby && controller.state == .disconnected)
    }
    @Test func renewedExpiryForSameOwnerKeepsStandbyAvailable() async throws {
        let driver = RecordingTunnelDriver(), value = lease()
        driver.supportsStandby = true
        let controller = ConnectionController(driver: driver)
        await controller.reconcile(owner: value.owner, expiresAt: value.expiresAt)
        try await controller.prepareStandby(value)
        await controller.reconcile(owner: value.owner, expiresAt: value.expiresAt.addingTimeInterval(1))
        #expect(controller.controlPlaneReady && driver.stopCount == 0)
        _ = try await controller.request(.init(.snapshot))
        controller.disconnect()
    }
    @Test func failureAndExpiredOrDifferentAccountNeverReportConnected() async {
        let driver = RecordingTunnelDriver(), value = lease()
        let controller = ConnectionController(driver: driver)
        await controller.reconcile(owner: value.owner, expiresAt: value.expiresAt)
        await controller.connect(lease(owner: "another-owner"))
        await controller.connect(lease(expiry: .distantPast))
        #expect(driver.starts.isEmpty && controller.state == .disconnected)
        driver.failure = .permission
        await controller.connect(value)
        #expect(controller.state == .disconnected && controller.message == TunnelError.permission.localizedDescription)
        #expect(driver.stopCount == 1)
    }
}

extension ConnectionTests {
    @Test func accountPollingCannotInterruptPendingConnectionForSameLeaseOwner() async {
        let driver = RecordingTunnelDriver(), value = lease()
        let controller = ConnectionController(driver: driver)
        await controller.reconcile(owner: value.owner, expiresAt: value.expiresAt)
        driver.suspended = true
        let work = Task { await controller.connect(value) }
        while driver.pending == nil { await Task.yield() }
        await controller.reconcile(owner: value.owner, expiresAt: value.expiresAt)
        driver.pending?.resume(); driver.pending = nil
        await work.value
        #expect(controller.state == .connecting)
        controller.disconnect()
    }
    @Test func unexpectedKernelExitReconnectsWithBackoffAndGivesUp() async throws {
        let driver = RecordingTunnelDriver()
        let controller = ConnectionController(driver: driver), value = lease()
        controller.restartBackoff = [.milliseconds(20), .milliseconds(20)]
        await controller.reconcile(owner: value.owner, expiresAt: value.expiresAt)
        await controller.connect(value)
        driver.statusChanged?(.connected)
        driver.failureOccurred?(.exited("合成内核退出"))
        #expect(controller.state == .reconnecting && controller.message == "合成内核退出" && !controller.controlPlaneReady)
        while driver.starts.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        driver.statusChanged?(.connected)
        #expect(controller.state == .connected)
        driver.failure = .start
        driver.failureOccurred?(.exited("合成内核退出"))
        let deadline = ContinuousClock.now + .seconds(5)
        while controller.message?.contains("2") != true && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(driver.starts.count == 4 && controller.state == .disconnected)
        #expect(controller.message == L10n.t("{0}；连续重启 {1} 次仍未成功，已停止重试", [TunnelError.start.localizedDescription, "2"]))
    }

    @Test func successfulRestartsDoNotExhaustBackoff() async throws {
        let driver = RecordingTunnelDriver()
        let controller = ConnectionController(driver: driver), value = lease()
        controller.restartBackoff = [.milliseconds(20), .milliseconds(20)]
        await controller.reconcile(owner: value.owner, expiresAt: value.expiresAt)
        await controller.connect(value)
        driver.statusChanged?(.connected)
        for round in 2...5 {
            driver.failureOccurred?(.exited("合成内核退出"))
            #expect(controller.state == .reconnecting)
            while driver.starts.count < round { try await Task.sleep(for: .milliseconds(10)) }
            driver.statusChanged?(.connected)
            try await Task.sleep(for: .milliseconds(30))
            #expect(controller.state == .connected)
        }
    }

    @Test func restartAssemblesTheCurrentLease() async throws {
        let driver = RecordingTunnelDriver()
        let controller = ConnectionController(driver: driver), value = lease()
        let current = TunnelLease(owner: value.owner, expiresAt: value.expiresAt, configuration: Data("current-config".utf8))
        controller.restartBackoff = [.milliseconds(20)]
        controller.relaunchLease = { takeover in takeover ? current : nil }
        await controller.reconcile(owner: value.owner, expiresAt: value.expiresAt)
        await controller.connect(value)
        driver.statusChanged?(.connected)
        driver.failureOccurred?(.exited("合成内核退出"))
        while driver.starts.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(driver.starts.last?.id == current.id && controller.runtimeConfiguration == current.configuration)
    }

    @Test func standbyExitRestartsStandbyAndUserDisconnectCancelsRestart() async throws {
        let driver = RecordingTunnelDriver(); driver.supportsStandby = true
        let controller = ConnectionController(driver: driver), value = lease()
        controller.restartBackoff = [.milliseconds(20), .milliseconds(300)]
        await controller.reconcile(owner: value.owner, expiresAt: value.expiresAt)
        try await controller.prepareStandby(value)
        driver.failureOccurred?(.exited("合成内核退出"))
        #expect(controller.state == .disconnected && !controller.controlPlaneReady)
        while !controller.controlPlaneReady { try await Task.sleep(for: .milliseconds(10)) }
        #expect(driver.standbyStarts.count == 2 && driver.starts.isEmpty)
        driver.failureOccurred?(.exited("合成内核退出"))
        controller.disconnect()
        try await Task.sleep(for: .milliseconds(500))
        #expect(driver.standbyStarts.count == 2 && !controller.controlPlaneReady)
    }

    @Test func offlineAuthorizationExpiryExplainsItself() async throws {
        let driver = RecordingTunnelDriver()
        let controller = ConnectionController(driver: driver)
        let value = lease(expiry: .now.addingTimeInterval(0.2))
        await controller.reconcile(owner: value.owner, expiresAt: value.expiresAt, authorizationExpiry: true)
        await controller.connect(value)
        var deadline = ContinuousClock.now + .seconds(5)
        while controller.message == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(controller.state != .connected && AppLanguage.allCases.map { L10n.t("本地配置授权已到期，请连接面板更新后重试", language: $0) }.contains(controller.message ?? ""))
        let other = lease(owner: "another-owner", expiry: .now.addingTimeInterval(0.2))
        controller.disconnect()
        #expect(controller.message == nil)
        await controller.reconcile(owner: other.owner, expiresAt: other.expiresAt)
        deadline = ContinuousClock.now + .seconds(5)
        while controller.message == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(AppLanguage.allCases.map { L10n.t("登录已过期，请重新登录。", language: $0) }.contains(controller.message ?? ""))
    }

    // 冷启动时系统 VPN 仍在运行：待机不得抢在驱动核对完系统状态之前启动，也不得停掉这条 VPN
    @Test func standbyWaitsForReconcileOfRunningVPN() async throws {
        let driver = RecordingTunnelDriver(), value = lease()
        driver.supportsStandby = true
        driver.restoredConfiguration = value.configuration
        driver.reconcileSuspended = true
        let controller = ConnectionController(driver: driver)
        let reconcile = Task { await controller.reconcile(owner: value.owner, expiresAt: value.expiresAt) }
        while driver.reconcilePending == nil { await Task.yield() }
        let standby = Task { try await controller.prepareStandby(value) }
        try await Task.sleep(for: .milliseconds(50))
        driver.reconcilePending?.resume(); driver.reconcilePending = nil
        await reconcile.value
        _ = try? await standby.value
        #expect(driver.standbyStarts.isEmpty && driver.stopCount == 0)
        #expect(controller.state == .connected && controller.controlPlaneReady && controller.runtimeConfiguration == value.configuration)
    }

    @Test func connectWaitsForReconcileOfRunningVPN() async throws {
        let driver = RecordingTunnelDriver(), value = lease()
        driver.restoredConfiguration = value.configuration
        driver.reconcileSuspended = true
        let controller = ConnectionController(driver: driver)
        let reconcile = Task { await controller.reconcile(owner: value.owner, expiresAt: value.expiresAt) }
        while driver.reconcilePending == nil { await Task.yield() }
        let connect = Task { await controller.connect(value) }
        try await Task.sleep(for: .milliseconds(50))
        driver.reconcilePending?.resume(); driver.reconcilePending = nil
        await reconcile.value
        await connect.value
        #expect(driver.starts.isEmpty && driver.stopCount == 0 && controller.state == .connected)
    }

    @Test func standbyFailureOnlyReleasesStandby() async {
        let driver = RecordingTunnelDriver(), value = lease()
        driver.supportsStandby = true; driver.failure = .control
        let controller = ConnectionController(driver: driver)
        await controller.reconcile(owner: value.owner, expiresAt: value.expiresAt)
        await #expect(throws: TunnelError.control) { try await controller.prepareStandby(value) }
        #expect(driver.standbyStops == 1 && controller.standbyMessage == TunnelError.control.localizedDescription && controller.message == nil)
    }

    @Test func standbyAfterFailedConnectionKeepsTheFailureReason() async throws {
        let driver = RecordingTunnelDriver(), value = lease()
        driver.supportsStandby = true; driver.failure = .start
        let controller = ConnectionController(driver: driver)
        await controller.reconcile(owner: value.owner, expiresAt: value.expiresAt)
        await controller.connect(value)
        #expect(controller.state == .disconnected && controller.message == TunnelError.start.localizedDescription)
        driver.failure = nil
        try await controller.prepareStandby(value)
        #expect(controller.controlPlaneReady && controller.message == TunnelError.start.localizedDescription && controller.standbyMessage == nil)
    }

    // 按需连接开着且租约有效时，系统报告断开只是在重连途中：不能当作未连接去拉起待机或在切后台时断开
    @Test func onDemandDisconnectIsReportedAsReconnecting() {
        #expect(ConnectionState.tunnelDisconnected(starting: false, progressed: false, leaseValid: true) == .reconnecting)
        #expect(ConnectionState.tunnelDisconnected(starting: false, progressed: false, leaseValid: false) == .disconnected)
    }

    // 应用发起的启动进入连接后又断开是启动失败：不能报成重连，否则错误提示出不来，系统还会反复拉起扩展
    @Test func failedTunnelStartIsNotReportedAsReconnecting() {
        #expect(ConnectionState.tunnelDisconnected(starting: true, progressed: false, leaseValid: true) == .connecting)
        #expect(ConnectionState.tunnelDisconnected(starting: true, progressed: true, leaseValid: true) == .disconnected)
        #expect(ConnectionState.tunnelDisconnected(starting: true, progressed: false, leaseValid: false) == .disconnected)
    }

    @Test func standbyRequestDuringConnectionIsNotReportedAsKernelError() async throws {
        let driver = RecordingTunnelDriver(); driver.supportsStandby = true; driver.suspended = true
        let controller = ConnectionController(driver: driver), value = lease()
        await controller.reconcile(owner: value.owner, expiresAt: value.expiresAt)
        let work = Task { await controller.connect(value) }
        while driver.pending == nil { await Task.yield() }
        await #expect(throws: CancellationError.self) { try await controller.prepareStandby(value) }
        driver.pending?.resume(); driver.pending = nil
        await work.value
        controller.disconnect()
    }
}
