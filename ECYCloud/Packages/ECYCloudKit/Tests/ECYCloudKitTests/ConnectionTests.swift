import Foundation
import Testing
@testable import ECYCloudKit

@MainActor final class RecordingTunnelDriver: TunnelDriver {
    var statusChanged: (@MainActor (ConnectionState) -> Void)?
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
    var standbyStarts: [TunnelLease] = []
    func startStandby(_ lease: TunnelLease) async throws {
        standbyStarts.append(lease)
        if suspended { await withCheckedContinuation { pending = $0 } }
        if let failure { throw failure }
    }
    func reconcile(owner: String?) async {
        if owner == nil { stop() }
        else if restoredConfiguration != nil { statusChanged?(.connected) }
    }
    func start(_ lease: TunnelLease) async throws {
        starts.append(lease)
        if suspended { await withCheckedContinuation { pending = $0 } }
        if let failure { throw failure }
    }
    func stop() { stopCount += 1; statusChanged?(.disconnected) }
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
}
