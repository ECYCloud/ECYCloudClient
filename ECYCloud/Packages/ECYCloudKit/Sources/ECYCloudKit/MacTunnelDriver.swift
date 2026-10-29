#if os(macOS)
import Foundation
import CryptoKit
import Security

@MainActor public final class MacTunnelDriver: TunnelDriver {
    public var statusChanged: (@MainActor (ConnectionState) -> Void)?
    public var failureOccurred: (@MainActor (TunnelError) -> Void)?
    private let helper: any MacHelperTransport
    private let transport: any HTTPTransport
    private let installed: () -> Bool
    private var epoch = 0
    private var owner: String?
    private var lease: TunnelLease?
    private var runtime: MacClashRuntime?
    private var monitor: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var systemProxy = true
    private var proxyBypass = NetworkSegments.proxyDefaults
    private var ruleContent: (name: String, data: Data, version: String)?
    public var supportsStandby: Bool { true }

    public convenience init() {
        self.init(helper: MacHelperClient(), transport: URLSessionTransport(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            return configuration
        }), installed: {
            Bundle.main.executableURL?.resolvingSymlinksInPath().path == "/Applications/ECYCloud.app/Contents/MacOS/ECYCloud"
        })
    }
    init(helper: any MacHelperTransport, transport: any HTTPTransport, installed: @escaping () -> Bool) {
        self.helper = helper; self.transport = transport; self.installed = installed
    }

    public func profileOptions(_ preferences: ClientPreferences) throws -> ProfileOptions {
        guard installed() else { throw TunnelError.installation }
        guard (1025...65535).contains(preferences.mixedPort),
              preferences.systemProxyBypass.count <= 256,
              preferences.systemProxyBypass.allSatisfy(NetworkSegments.validProxyBypass) else { throw TunnelError.configuration }
        let ports = try MacPorts.allocate(mixed: preferences.mixedPort)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw TunnelError.start }
        var options = ProfileOptions(mixedPort: ports.mixed, controllerPort: ports.controller, secret: Data(bytes).base64EncodedString())
        options.mode = preferences.mode.rawValue
        options.ipv6 = preferences.ipv6
        options.tunEnabled = preferences.tunEnabled
        options.strictRoute = preferences.strictRoute
        options.allowLAN = preferences.allowLAN
        options.excludedRoutes = preferences.excludedRoutes
        options.logLevel = "info"
        options.tunDevice = ""
        systemProxy = preferences.systemProxy
        proxyBypass = NetworkSegments.unique(NetworkSegments.proxyDefaults + preferences.systemProxyBypass)
        return options
    }

    // 移动端的包隧道不开监听端口，只有 macOS 内核提供可回退的本地代理
    public var panelProxyPort: Int? { runtime?.mixedPort }

    public func reconcile(owner: String?) async {
        guard self.owner != owner else { return }
        stop()
        let operation = epoch
        await stopping?.value
        guard operation == epoch else { return }
        self.owner = owner
    }

    public func start(_ lease: TunnelLease) async throws {
        try await start(lease, takeover: true)
    }

    public func startStandby(_ lease: TunnelLease) async throws {
        try await start(lease, takeover: false)
    }

    private func start(_ lease: TunnelLease, takeover: Bool) async throws {
        guard installed() else { throw TunnelError.installation }
        await stopping?.value
        guard self.lease == nil, owner == lease.owner, lease.expiresAt > .now else { throw TunnelError.start }
        try lease.validate(owner: lease.owner, id: lease.id)
        guard let validation = lease.validationConfiguration, validation.count <= URLSessionTransport.maximumResponseBytes,
              let config = try JSONSerialization.jsonObject(with: lease.configuration) as? [String: Any] else { throw TunnelError.configuration }
        if !takeover, (config["tun"] as? [String: Any])?["enable"] as? Bool != false { throw TunnelError.configuration }
        let logStore = ClientLogStore.directory(owner: lease.owner).map { ClientLogStore(directory: $0, level: lease.logLevel ?? "warning") }
        let client = try MacClashRuntime(configuration: config, transport: transport, logStore: logStore)
        epoch += 1
        let operation = epoch
        self.lease = lease
        runtime = client
        func current() throws {
            try Task.checkCancellation()
            guard epoch == operation, self.lease?.id == lease.id, lease.expiresAt > .now else { throw CancellationError() }
        }
        _ = try await helper.request("ping", payload: [:]); try current()
        _ = try await helper.request("kernel.bind", payload: ["cache_key": lease.owner]); try current()
        let check = try await helper.request("kernel.check", payload: ["config": String(decoding: validation, as: UTF8.self)])
        try current()
        guard check["valid"] as? Bool == true else { throw TunnelError.configuration }
        if takeover { statusChanged?(.connecting) }
        _ = try await helper.request("kernel.start", payload: ["config": String(decoding: lease.configuration, as: UTF8.self)])
        try current()
        let deadline = ContinuousClock.now + .seconds(60)
        var ready = false
        while ContinuousClock.now < deadline {
            try current()
            do { try await client.ready(); ready = true; break }
            catch is CancellationError { throw CancellationError() }
            catch { try await Task.sleep(for: .milliseconds(250)) }
        }
        try current()
        guard ready else { throw TunnelError.start }
        if takeover && systemProxy {
            _ = try await helper.request("proxy.set", payload: ["port": client.mixedPort,
                "bypass": proxyBypass])
            try current()
        }
        client.startMemoryProbe()
        client.startTrafficSampling()
        if takeover { statusChanged?(.connected) }
        monitor = Task { [weak self] in
            var failures = 0, cursor = 0
            while let self, self.epoch == operation {
                do {
                    let status = try await self.helper.request("kernel.status", payload: ["log_cursor": cursor])
                    guard self.epoch == operation else { return }
                    cursor = status["log_cursor"] as? Int ?? cursor
                    client.appendLogs(status["log_lines"] as? [String] ?? [])
                    guard status["running"] as? Bool == true else { self.stop(); return }
                    failures = 0
                } catch {
                    guard self.epoch == operation else { return }
                    failures += 1
                    if failures >= 3 { self.failureOccurred?(.helperUnavailable); self.stop(); return }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    public func waitUntilStopped() async throws {
        await stopping?.value
        guard lease == nil else { throw TunnelError.helperUnavailable }
    }

    public func stop() {
        ruleContent = nil
        guard lease != nil else {
            if stopping == nil { statusChanged?(.disconnected) }
            return
        }
        epoch += 1
        monitor?.cancel(); monitor = nil
        let client = runtime
        client?.close()
        runtime = nil
        statusChanged?(.disconnecting)
        let operation = epoch
        let previous = stopping
        stopping = Task { [weak self] in
            await previous?.value
            guard let self, self.epoch == operation else { return }
            // 先撤销 TUN，再由 helper 停止进程、恢复系统代理；运行目录与规则集缓存留到退出或切换会话时由 clearCache 清理。
            try? await client?.disableTUN()
            for attempt in 0..<3 {
                do {
                    _ = try await self.helper.request("kernel.stop", payload: [:])
                    _ = try await self.helper.request("proxy.restore", payload: [:])
                    guard self.epoch == operation else { return }
                    self.lease = nil; self.stopping = nil
                    self.statusChanged?(.disconnected)
                    return
                } catch {
                    guard self.epoch == operation else { return }
                    if attempt < 2 { try? await Task.sleep(for: .seconds(1)) }
                }
            }
            self.stopping = nil
            self.failureOccurred?(.helperUnavailable)
        }
    }

    public func clearCache(owner: String) async {
        guard lease == nil, stopping == nil, installed() else { return }
        epoch += 1
        let operation = epoch
        stopping = Task { [weak self] in
            _ = try? await self?.helper.request("kernel.clear", payload: [:])
            if self?.epoch == operation { self?.stopping = nil }
        }
        await stopping?.value
    }

    public func request(_ command: TunnelCommand) async throws -> Data {
        guard let lease, lease.expiresAt > .now, let runtime else { throw TunnelError.control }
        let operation = epoch
        let result: Data
        if command.action == .rules, command.scope == "content" {
            guard let config = try JSONSerialization.jsonObject(with: lease.configuration) as? [String: Any],
                  let rules = config["rule-providers"] as? [String: [String: Any]],
                  let path = rules[command.group]?["path"] as? String, ProfileAssembler.safeProviderPath(path),
                  (1...256).contains(command.page) else { throw TunnelError.control }
            if command.page == 1 {
                let response = try await helper.request("kernel.read", payload: ["path": path])
                guard epoch == operation, self.lease?.id == lease.id,
                      let text = response["content"] as? String, text.utf8.count <= URLSessionTransport.maximumResponseBytes else { throw TunnelError.control }
                let data = Data(text.utf8)
                ruleContent = (command.group, data, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            }
            guard let content = ruleContent, content.name == command.group,
                  command.page == 1 || command.query == content.version else { throw TunnelError.control }
            let data = content.data, offset = (command.page - 1) * 32768
            guard offset <= data.count else { throw TunnelError.control }
            let done = offset + 32768 >= data.count
            result = try JSONSerialization.data(withJSONObject: ["data": Data(data.dropFirst(offset).prefix(32768)).base64EncodedString(), "done": done, "version": content.version])
            if done { ruleContent = nil }
        } else { result = try await runtime.request(command) }
        try Task.checkCancellation()
        guard epoch == operation, self.lease?.id == lease.id else { throw CancellationError() }
        return result
    }
}
#endif
