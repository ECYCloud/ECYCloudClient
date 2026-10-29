#if os(iOS) || os(tvOS) || os(visionOS)
import Foundation
@preconcurrency import NetworkExtension

public enum TunnelFiles {
    public static func directory(group: String) throws -> URL {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { throw TunnelError.unavailable }
        let path = base.appendingPathComponent("VPN", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: protection)
        var result = path
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try result.setResourceValues(values)
        seedGeoData(path)
        return path
    }
    public static func runDirectory(group: String, lease: TunnelLease) throws -> URL {
        let base = try directory(group: group)
        for item in (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [] where UUID(uuidString: item) != nil {
            try? FileManager.default.removeItem(at: base.appendingPathComponent(item, isDirectory: true))
        }
        let path = base.appendingPathComponent(lease.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: protection)
        for name in kernelData where FileManager.default.fileExists(atPath: base.appendingPathComponent(name).path) {
            try FileManager.default.createSymbolicLink(atPath: path.appendingPathComponent(name).path, withDestinationPath: "../" + name)
        }
        let cache = try ruleCache(base, owner: lease.owner)
        let rules = cache.deletingLastPathComponent()
        for item in (try? FileManager.default.contentsOfDirectory(atPath: rules.path)) ?? [] where item != lease.owner {
            try? FileManager.default.removeItem(at: rules.appendingPathComponent(item))
        }
        for file in ruleFiles(lease.configuration) where FileManager.default.fileExists(atPath: cache.appendingPathComponent(file).path) {
            let target = path.appendingPathComponent(file)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: protection)
            try? FileManager.default.copyItem(at: cache.appendingPathComponent(file), to: target)
        }
        return path
    }
    // Go 桥接以运行目录为根读取规则文件，不能用指向目录外的链接，所以把规则集克隆回本会话缓存供下次启动复用。
    // 只在内核成功启动后调用：此时自行下载的地理数据与规则集都是完整文件。启动成功后立即保存一次，
    // 因为应用被强制结束（如重新安装）时不会走到停止流程；正常停止时再保存运行期间的规则刷新。
    public static func keepCache(group: String, lease: TunnelLease, from run: URL) {
        guard let base = try? directory(group: group), let cache = try? ruleCache(base, owner: lease.owner) else { return }
        for name in kernelData where !FileManager.default.fileExists(atPath: base.appendingPathComponent(name).path) {
            let source = run.appendingPathComponent(name)
            guard (try? source.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            try? FileManager.default.copyItem(at: source, to: base.appendingPathComponent(name))
        }
        for file in ruleFiles(lease.configuration) {
            let source = run.appendingPathComponent(file)
            guard (try? source.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let target = cache.appendingPathComponent(file)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: protection)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: source, to: target)
        }
    }
    public static func clearRules(group: String, owner: String) {
        guard let base = try? directory(group: group), let cache = try? ruleCache(base, owner: owner) else { return }
        try? FileManager.default.removeItem(at: cache)
    }
    private static var protection: [FileAttributeKey: Any] { [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication] }
    private static func ruleCache(_ base: URL, owner: String) throws -> URL {
        guard owner.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw TunnelError.configuration }
        let cache = base.appendingPathComponent("Rules/\(owner)", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: protection)
        return cache
    }
    private static func ruleFiles(_ configuration: Data) -> [String] {
        let providers = ((try? JSONSerialization.jsonObject(with: configuration)) as? [String: Any])?["rule-providers"] as? [String: [String: Any]] ?? [:]
        return providers.values.compactMap { $0["path"] as? String }.filter(ProfileAssembler.safeProviderPath)
            .map { $0.components(separatedBy: "/").filter { $0 != "." }.joined(separator: "/") }
    }
    // 内核解析 GEOIP / GEOSITE / IP-ASN 时只读运行目录里这些文件名（mihomo constant/path.go），缺失即按 geox-url 同步下载，每个 90 秒超时；
    // 前两个随包播种，ASN 不随包，首次下载成功后由 keepCache 保存为共享副本
    private static let geoData = ["geoip.metadb", "GeoSite.dat"]
    private static let kernelData = geoData + ["ASN.mmdb"]
    private static func seedGeoData(_ directory: URL) {
        for name in geoData {
            let target = directory.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: target.path), let source = Bundle.main.url(forResource: name, withExtension: nil) else { continue }
            let staging = directory.appendingPathComponent(".\(name).\(UUID().uuidString)")
            do {
                try FileManager.default.copyItem(at: source, to: staging)
                try FileManager.default.moveItem(at: staging, to: target)
            } catch { try? FileManager.default.removeItem(at: staging) }
        }
    }
    public static func save(_ lease: TunnelLease, group: String) throws {
        guard lease.configuration.count <= URLSessionTransport.maximumResponseBytes, lease.expiresAt > Date() else { throw TunnelError.configuration }
        let file = try directory(group: group).appendingPathComponent(lease.id.uuidString + ".json")
        try JSONEncoder().encode(lease).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public static func load(group: String, owner: String, id: UUID) throws -> TunnelLease {
        let file = try directory(group: group).appendingPathComponent(id.uuidString + ".json")
        let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true, let size = attributes.fileSize, size <= 12 * 1024 * 1024 else { throw TunnelError.configuration }
        let lease = try JSONDecoder().decode(TunnelLease.self, from: Data(contentsOf: file))
        try lease.validate(owner: owner, id: id)
        return lease
    }
    public static func clear(group: String, id: UUID?) {
        guard let id else { return }
        guard let directory = try? directory(group: group) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".json"))
    }
}

@MainActor public final class AppleTunnelDriver: TunnelDriver {
    public var statusChanged: (@MainActor (ConnectionState) -> Void)?
    private let bundleID: String
    private let group: String
    private var manager: NETunnelProviderManager?
    private var epoch = 0
    private var notification: NSObjectProtocol?
    private let standby: (any StandbyRuntime)?
    private var standbyActive = false
    private var stopping: Task<Void, Never>?
    public var supportsStandby: Bool { standby != nil }
    public var restoredConfiguration: Data? {
        guard manager?.connection.status == .connected,
              let values = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
              let owner = values["owner"] as? String, let raw = values["leaseID"] as? String, let id = UUID(uuidString: raw) else { return nil }
        return try? TunnelFiles.load(group: group, owner: owner, id: id).configuration
    }
    public init(applicationID: String, standby: (any StandbyRuntime)? = nil) {
        bundleID = applicationID + ".tunnel"
        group = "group." + applicationID
        self.standby = standby
    }
    public func reconcile(owner: String?) async {
        epoch += 1
        let operation = epoch
        do {
            let existing = try await managers()
            guard operation == epoch else { return }
            manager = existing.first
            observe()
            if owner == nil || (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["owner"] as? String != owner { stop() }
            else { updateStatus() }
        } catch { if operation == epoch { statusChanged?(.disconnected) } }
    }
    public func clearCache(owner: String) async { TunnelFiles.clearRules(group: group, owner: owner) }
    public func start(_ lease: TunnelLease) async throws {
        epoch += 1
        let operation = epoch
        let existing = try await managers()
        guard operation == epoch, lease.expiresAt > Date() else { throw CancellationError() }
        let selected = existing.first ?? NETunnelProviderManager()
        if selected.connection.status != .disconnected && selected.connection.status != .invalid { throw TunnelError.start }
        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = bundleID
        configuration.serverAddress = "ECY Cloud"
        configuration.disconnectOnSleep = false
        configuration.providerConfiguration = ["owner": lease.owner, "leaseID": lease.id.uuidString]
        selected.protocolConfiguration = configuration
        selected.localizedDescription = "ECY Cloud"
        selected.isEnabled = true
        selected.isOnDemandEnabled = false
        do { try await selected.saveToPreferences(); try await selected.loadFromPreferences() }
        catch { throw TunnelError.permission }
        guard operation == epoch, lease.expiresAt > Date() else { throw CancellationError() }
        try TunnelFiles.save(lease, group: group)
        manager = selected; observe()
        do { try selected.connection.startVPNTunnel() }
        catch { TunnelFiles.clear(group: group, id: lease.id); throw TunnelError.start }
        updateStatus()
    }
    public func startStandby(_ lease: TunnelLease) async throws {
        guard let standby else { throw TunnelError.unavailable }
        try await waitUntilStopped()
        epoch += 1
        let operation = epoch
        try await standby.start(lease)
        guard operation == epoch else { throw CancellationError() }
        standbyActive = true
    }
    public func stop() {
        epoch += 1
        let operation = epoch
        standbyActive = false
        let previous = stopping
        stopping = Task {
            await previous?.value
            await standby?.stop()
            if manager == nil {
                let existing = try? await managers()
                guard epoch == operation else { return }
                manager = existing?.first
                observe()
                for item in existing ?? [] { clearLease(item); item.connection.stopVPNTunnel() }
                updateStatus()
            }
        }
        clearLease(manager)
        if let manager { manager.connection.stopVPNTunnel(); updateStatus() }
    }
    public func waitUntilStopped() async throws {
        await stopping?.value
        let deadline = ContinuousClock.now + .seconds(10)
        while let status = manager?.connection.status, status != .invalid && status != .disconnected {
            guard ContinuousClock.now < deadline else { throw TunnelError.control }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    public func request(_ command: TunnelCommand) async throws -> Data {
        if standbyActive, let standby { return try await standby.request(command) }
        guard let manager, manager.connection.status == .connected,
              let provider = manager.connection as? NETunnelProviderSession,
              let rawID = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["leaseID"] as? String,
              let id = UUID(uuidString: rawID) else { throw TunnelError.control }
        let operation = epoch
        let data = try JSONEncoder().encode(TunnelCommandEnvelope(leaseID: id, command: command))
        guard data.count <= 4096 else { throw TunnelError.control }
        let reply = ProviderReply()
        let result: Data = try await withCheckedThrowingContinuation { continuation in
            reply.continuation = continuation
            reply.timeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                reply.finish(nil)
            }
            do {
                try provider.sendProviderMessage(data) { data in Task { @MainActor in reply.finish(data) } }
            } catch { reply.finish(nil) }
        }
        guard epoch == operation else { throw CancellationError() }
        try Task.checkCancellation()
        return result
    }
    private func clearLease(_ manager: NETunnelProviderManager?) {
        let id = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["leaseID"] as? String
        TunnelFiles.clear(group: group, id: id.flatMap(UUID.init(uuidString:)))
    }
    private func managers() async throws -> [NETunnelProviderManager] {
        try await NETunnelProviderManager.loadAllFromPreferences().filter {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == bundleID
        }
    }
    private func observe() {
        if let notification { NotificationCenter.default.removeObserver(notification) }
        guard let manager else { return }
        notification = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: manager.connection, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateStatus() }
        }
    }
    private func updateStatus() {
        let state: ConnectionState
        switch manager?.connection.status {
        case .connecting: state = .connecting
        case .connected: state = .connected
        case .reasserting: state = .reconnecting
        case .disconnecting: state = .disconnecting
        default: state = .disconnected
        }
        if standbyActive && state == .disconnected { return }
        statusChanged?(state)
    }
}
@MainActor private final class ProviderReply {
    var continuation: CheckedContinuation<Data, any Error>?
    var timeout: Task<Void, Never>?
    func finish(_ data: Data?) {
        guard let continuation else { return }
        self.continuation = nil; timeout?.cancel(); timeout = nil
        if let data, !data.isEmpty, data.count <= 65536 { continuation.resume(returning: data) }
        else { continuation.resume(throwing: TunnelError.control) }
    }
}
#endif
