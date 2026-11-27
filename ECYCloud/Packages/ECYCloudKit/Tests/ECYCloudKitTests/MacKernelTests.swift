#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import ECYCloudKit

private actor MacHTTPFixture: HTTPTransport {
    var calls: [URLRequest] = []
    var connections: [[String: Any]] = []
    func setConnections(_ data: Data) throws { connections = try JSONSerialization.jsonObject(with: data) as! [[String: Any]] }
    func send(_ request: URLRequest) async throws -> HTTPResult {
        calls.append(request)
        let value: [String: Any]
        switch request.url!.path {
        case "/connections": value = ["connections": connections, "uploadTotal": 150, "downloadTotal": 200]
        case "/configs": value = ["mode": "rule"]
        case "/proxies": value = ["proxies": ["选择": ["all": ["node-1", "DIRECT", "ecy-speed"], "now": "node-1", "type": "Selector"], "ecy-speed": ["all": ["DIRECT"], "hidden": true]]]
        case "/providers/proxies": value = ["providers": ["ecy-panel-nodes": ["proxies": [["name": "node-1", "history": [["delay": 42]]]]]]]
        default: value = [:]
        }
        return HTTPResult(data: try JSONSerialization.data(withJSONObject: value), status: 200)
    }
}

private actor SelectionFixture: HTTPTransport {
    var calls: [String] = []
    let members: [String]
    let failConnections: Bool
    init(members: [String] = ["node-1"], failConnections: Bool = false) { self.members = members; self.failConnections = failConnections }
    func send(_ request: URLRequest) async throws -> HTTPResult {
        let method = request.httpMethod ?? "GET", path = request.url!.path
        calls.append(method + " " + path)
        let value: [String: Any]
        switch (method, path) {
        case ("GET", "/proxies/选择"): value = ["type": "Selector", "all": members, "now": members[0]]
        case ("GET", "/proxies/自动"): value = ["type": "URLTest", "all": members, "now": members[0]]
        case ("PUT", _): return HTTPResult(data: Data(), status: 204)
        case ("GET", "/connections"):
            if failConnections { return HTTPResult(data: Data(), status: 500) }
            value = ["connections": [], "uploadTotal": 0, "downloadTotal": 0]
        case ("GET", "/proxies"): value = ["proxies": ["选择": ["all": members, "now": members[0], "type": "Selector"]]]
        case ("GET", "/configs"): value = ["mode": "rule"]
        default: value = [:]
        }
        return HTTPResult(data: try JSONSerialization.data(withJSONObject: value), status: 200)
    }
}

private actor ReadinessFixture: HTTPTransport {
    var calls: [String] = []
    var loaded = false
    func load() { loaded = true }
    func send(_ request: URLRequest) async throws -> HTTPResult {
        let method = request.httpMethod ?? "GET", path = request.url!.path
        calls.append(method + " " + path)
        let value: [String: Any] = path.hasPrefix("/providers/proxies/") ? ["proxies": loaded ? [["name": "node-1"]] : []] : [:]
        return HTTPResult(data: try JSONSerialization.data(withJSONObject: value), status: method == "GET" ? 200 : 204)
    }
}

private struct MixedPortFixture: HTTPTransport {
    let reported: Int
    var tun: Bool?
    func send(_ request: URLRequest) async throws -> HTTPResult {
        var body: [String: Any] = ["mode": "rule", "mixed-port": reported]
        if let tun { body["tun"] = ["enable": tun] }
        return HTTPResult(data: try JSONSerialization.data(withJSONObject: body), status: 200)
    }
}

@MainActor private final class MacHelperFixture: MacHelperTransport {
    var commands: [String] = []
    var valid = true
    var suspendBinding = false
    var binding: CheckedContinuation<Void, Never>?
    var executable: URL?
    var directory: URL?
    var process: Process?
    var appliedProxy = false
    var ruleContent = ""
    var startLines: [String] = []
    var failRestore = false
    var failedStops = 0
    var stuckStops = false
    var simulatedRunning = false
    var exitError: String?
    var checkError: String?
    var exitOnStart = false
    var payloads: [String: [String: Any]] = [:]
    var writtenNodeFiles: [String] = []
    var rejection: String?
    private var lines: [String] = [], partial = ""
    func request(_ command: String, payload: [String: Any], timeout: Duration) async throws -> [String: Any] {
        commands.append(command)
        if let rejection { throw TunnelError.failed(rejection) }
        payloads[command] = payload
        switch command {
        case "kernel.bind":
            if suspendBinding { await withCheckedContinuation { binding = $0 } }
        case "kernel.check":
            if let executable, let directory {
                let path = directory.appendingPathComponent("check.json")
                try Data((payload["config"] as! String).utf8).write(to: path)
                let check = Process(); check.executableURL = executable
                check.arguments = ["-t", "-d", directory.path, "-f", path.path]
                check.standardOutput = FileHandle.nullDevice; check.standardError = FileHandle.nullDevice
                try check.run(); check.waitUntilExit()
                return ["valid": check.terminationStatus == 0]
            }
            var result: [String: Any] = ["valid": valid]
            if let checkError { result["error"] = checkError }
            return result
        case "kernel.start":
            guard let executable, let directory else { lines += startLines; simulatedRunning = !exitOnStart; return [:] }
            try writeNodeFiles(payload)
            let path = directory.appendingPathComponent("config.json")
            try Data((payload["config"] as! String).utf8).write(to: path)
            let process = Process(), output = Pipe(); process.executableURL = executable
            process.arguments = ["-d", directory.path, "-f", path.path]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                let text = String(decoding: data, as: UTF8.self)
                Task { @MainActor in self?.receive(text) }
            }
            try process.run(); self.process = process
        case "kernel.write": try writeNodeFiles(payload)
        case "proxy.set": appliedProxy = true
        case "kernel.stop":
            if stuckStops { try await Task.sleep(for: timeout); throw TunnelError.helperTimeout }
            if failedStops > 0 { failedStops -= 1; throw TunnelError.helperUnavailable }
            simulatedRunning = false
            if let process, process.isRunning { process.terminate(); process.waitUntilExit() }
        case "proxy.restore":
            if failRestore { throw TunnelError.helperUnavailable }
            appliedProxy = false
        case "kernel.clear": cleanup()
        case "kernel.status":
            let cursor = min(max(payload["log_cursor"] as? Int ?? 0, 0), lines.count)
            var status: [String: Any] = ["running": process?.isRunning ?? simulatedRunning, "log_cursor": lines.count, "log_lines": Array(lines[cursor...])]
            if let exitError { status["error"] = exitError }
            return status
        case "kernel.read": return ["content": ruleContent]
        default: break
        }
        return [:]
    }
    // 与 helper 的 writePanelProviders 一致：节点文件按 payload 写出，内容没变的不重写
    private func writeNodeFiles(_ payload: [String: Any]) throws {
        guard let directory, let config = try JSONSerialization.jsonObject(with: Data((payload["config"] as! String).utf8)) as? [String: Any] else { return }
        for (name, provider) in config["proxy-providers"] as? [String: [String: Any]] ?? [:] where name.hasPrefix("ecy-panel-") {
            let data = try JSONSerialization.data(withJSONObject: ["proxies": provider["payload"]!], options: [.sortedKeys])
            let file = directory.appendingPathComponent(name + ".json")
            if (try? Data(contentsOf: file)) == data { continue }
            try data.write(to: file, options: .atomic)
            writtenNodeFiles.append(name)
        }
    }
    func cleanup() {
        if let process, process.isRunning { process.terminate(); process.waitUntilExit() }
        process = nil; appliedProxy = false
    }
    private func receive(_ text: String) {
        let parts = (partial + text).components(separatedBy: "\n")
        lines += parts.dropLast(); partial = parts.last ?? ""
    }
}

@Suite("Mac 内核与控制通道", .timeLimit(.minutes(2)), .isolatedUserData) @MainActor
struct MacKernelTests {
    private let remote = Data(#"{"proxies":[{"name":"node-1","type":"socks5","server":"127.0.0.1","port":9,"password":"synthetic-node-password"}],"proxy-groups":[{"name":"选择","type":"select","proxies":["DIRECT","node-1"]}],"rules":["MATCH,DIRECT"]}"#.utf8)
    private let owner = String(repeating: "a", count: 64)
    private func preferences() -> (ClientPreferences, String) {
        let name = "ecycloud-mac-tests-" + UUID().uuidString
        return (ClientPreferences(defaults: UserDefaults(suiteName: name)!), name)
    }
    private func configuration() -> [String: Any] { ["external-controller": "127.0.0.1:19867", "mixed-port": 19865, "secret": String(repeating: "s", count: 48)] }
    private func lease(_ driver: MacTunnelDriver, _ preferences: ClientPreferences) throws -> TunnelLease {
        let assembled = try ProfileAssembler.assemble(remote, options: driver.profileOptions(preferences))
        return TunnelLease(owner: owner, expiresAt: .now.addingTimeInterval(3600), configuration: assembled.data, validationConfiguration: assembled.validationData)
    }

    @Test func desktopConfigurationHasOnlyLoopbackControlAndDistinctPorts() throws {
        let (preferences, name) = preferences(); defer { UserDefaults().removePersistentDomain(forName: name) }
        let driver = MacTunnelDriver(helper: MacHelperFixture(), transport: MacHTTPFixture(), installed: { true })
        let first = try driver.profileOptions(preferences), next = try driver.profileOptions(preferences)
        #expect(first.input == .proxy && first.secret.count >= 32 && first.secret != next.secret)
        #expect(first.controllerPort != first.mixedPort && first.controllerPort != first.mixedPort + 1)
        #expect(!first.tunEnabled && !first.strictRoute && first.tunDevice.isEmpty && preferences.systemProxy)
        let assembled = try ProfileAssembler.assemble(remote, options: first)
        let value = try JSONSerialization.jsonObject(with: assembled.data) as! [String: Any]
        #expect(value["external-controller"] as? String == "127.0.0.1:\(first.controllerPort)")
        #expect((value["listeners"] as? [[String: Any]])?.first?["port"] as? Int == first.mixedPort + 1)
        #expect((value["tun"] as? [String: Any])?["enable"] as? Bool == false)
    }

    // 混合端口被其它程序抢先占用时内核照常运行但不回报该端口，系统代理不能指过去
    @Test func systemProxyRequiresKernelOwnedMixedPort() async throws {
        for (reported, owned) in [(0, false), (30_001, false), (30_000, true)] {
            let runtime = try MacClashRuntime(configuration: ["external-controller": "127.0.0.1:30002", "mixed-port": 30_000,
                                                              "secret": String(repeating: "s", count: 32)],
                                              transport: MixedPortFixture(reported: reported))
            #expect(try await runtime.listensOnMixedPort() == owned)
        }
        #expect(TunnelError.mixedPortInUse(30_000).errorDescription?.contains("30000") == true)
    }

    // 开 TUN 失败时内核照常运行、只把运行态的 tun.enable 抹成 false：不读回就会显示已连接而流量没被接管
    @Test func tunTakeoverIsReadBackFromKernel() async throws {
        for (reported, enabled) in [(true, true), (false, false), (nil, false)] as [(Bool?, Bool)] {
            let runtime = try MacClashRuntime(configuration: ["external-controller": "127.0.0.1:30002", "mixed-port": 30_000,
                                                              "secret": String(repeating: "s", count: 32)],
                                              transport: MixedPortFixture(reported: 30_000, tun: reported))
            #expect(try await runtime.tunEnabled() == enabled)
        }
    }

    // 节点文件加载前 TUN 劫持的 DNS 等也会读 url-test，内核把空组回落的 REJECT 缓存 10 秒：加载完先清掉，且只清 url-test
    @Test func readinessResetsUrlTestGroupsOnlyAfterNodeFilesLoad() async throws {
        let transport = ReadinessFixture()
        let runtime = try MacClashRuntime(configuration: ["external-controller": "127.0.0.1:30002", "mixed-port": 30_000,
                                                          "secret": String(repeating: "s", count: 32),
                                                          "proxy-providers": ["ecy-panel-nodes": ["type": "file"]],
                                                          "proxy-groups": [["name": "选择", "type": "select"], ["name": "自动选择", "type": "url-test"]]],
                                          transport: transport)
        await #expect(throws: TunnelError.start) { try await runtime.ready() }
        #expect(await !transport.calls.contains { $0.hasPrefix("DELETE ") })
        await transport.load()
        let before = await transport.calls.count
        await #expect(throws: TunnelError.start) { try await runtime.ready() }
        #expect(Array(await transport.calls.dropFirst(before)) == ["GET /version", "GET /providers/proxies/ecy-panel-nodes",
                                                                   "DELETE /proxies/自动选择", "PUT /proxies/ecy-speed"])
    }

    // 控制端口被本机其它进程抢先占住时内核照常运行，只有 helper 转交的内核输出能说明控制面没起来
    @Test func controllerReadinessComesOnlyFromKernelListeningLine() throws {
        let runtime = try MacClashRuntime(configuration: ["external-controller": "127.0.0.1:30002", "mixed-port": 30_000,
                                                          "secret": String(repeating: "s", count: 32)],
                                          transport: MixedPortFixture(reported: 30_000))
        #expect(try runtime.controllerBound([#"time="2026-10-30T12:00:00Z" level=info msg="RESTful API listening at: 127.0.0.1:30002""#]))
        #expect(try !runtime.controllerBound([#"time="2026-10-30T12:00:00Z" level=info msg="RESTful API listening at: 127.0.0.1:300020""#,
                                              #"time="2026-10-30T12:00:00Z" level=info msg="[TCP] 127.0.0.1:5 --> RESTful API listening at: 127.0.0.1:30002 match Match using DIRECT""#]))
        #expect(throws: TunnelError.controllerPortInUse(30002)) {
            try runtime.controllerBound([#"time="2026-10-30T12:00:00Z" level=error msg="External controller listen error: listen tcp 127.0.0.1:30002: bind: address already in use""#])
        }
        #expect(TunnelError.controllerPortInUse(30002).errorDescription?.contains("30002") == true)
    }

    @Test func controllerPortTakenByAnotherProcessNeverReceivesSecret() async throws {
        let (preferences, name) = preferences(); defer { UserDefaults().removePersistentDomain(forName: name) }
        let helper = MacHelperFixture(), transport = MacHTTPFixture()
        let driver = MacTunnelDriver(helper: helper, transport: transport, installed: { true })
        let value = try lease(driver, preferences)
        let endpoint = (try JSONSerialization.jsonObject(with: value.configuration) as! [String: Any])["external-controller"] as! String
        helper.startLines = ["time=\"2026-10-30T12:00:00Z\" level=info msg=\"RESTful API listening at: 127.0.0.1:1\"",
                             "time=\"2026-10-30T12:00:00Z\" level=error msg=\"External controller listen error: listen tcp \(endpoint): bind: address already in use\""]
        await driver.reconcile(owner: owner)
        await #expect(throws: TunnelError.controllerPortInUse(Int(endpoint.split(separator: ":").last!)!)) { try await driver.start(value) }
        #expect(await transport.calls.isEmpty)
        #expect(helper.commands.contains("kernel.start") && !helper.appliedProxy)
    }

    // 测速入站（混合端口 + 1）被占时内核只记一行日志：立即给出带端口号的原因，不等满 60 秒再报内核启动失败
    @Test func speedListenerPortTakenFailsFastWithItsPort() async throws {
        let (preferences, name) = preferences(); defer { UserDefaults().removePersistentDomain(forName: name) }
        let helper = MacHelperFixture(), transport = MacHTTPFixture()
        let driver = MacTunnelDriver(helper: helper, transport: transport, installed: { true })
        let value = try lease(driver, preferences)
        let config = try JSONSerialization.jsonObject(with: value.configuration) as! [String: Any]
        let endpoint = config["external-controller"] as! String, probe = (config["mixed-port"] as! Int) + 1
        helper.startLines = ["time=\"2026-10-30T12:00:00Z\" level=info msg=\"RESTful API listening at: \(endpoint)\"",
                             "time=\"2026-10-30T12:00:00Z\" level=error msg=\"Listener ecy-speed listen err: listen tcp 127.0.0.1:\(probe): bind: address already in use\""]
        await driver.reconcile(owner: owner)
        let started = ContinuousClock.now
        await #expect(throws: TunnelError.speedPortInUse(probe)) { try await driver.start(value) }
        #expect(ContinuousClock.now - started < .seconds(5) && !helper.appliedProxy)
        #expect(TunnelError.speedPortInUse(probe).errorDescription?.contains(String(probe)) == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ECYCLOUD_TEST_MIHOMO"] != nil))
    func officialKernelReportsTakenSpeedListenerPort() async throws {
        let (preferences, name) = preferences(); defer { UserDefaults().removePersistentDomain(forName: name) }
        preferences.mixedPort = try MacPorts.allocate().mixed
        let blocker = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(blocker) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(preferences.mixedPort + 1).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(blocker, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        #expect(bound == 0 && listen(blocker, 1) == 0)
        let helper = MacHelperFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mac-speed-port-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        helper.executable = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECYCLOUD_TEST_MIHOMO"]!)
        helper.directory = directory
        defer { helper.cleanup(); try? FileManager.default.removeItem(at: directory) }
        let driver = MacTunnelDriver(helper: helper, transport: URLSessionTransport(configuration: {
            let value = URLSessionConfiguration.ephemeral; value.connectionProxyDictionary = [:]; return value
        }), installed: { true })
        let value = try lease(driver, preferences)
        await driver.reconcile(owner: owner)
        let started = ContinuousClock.now
        await #expect(throws: TunnelError.speedPortInUse(preferences.mixedPort + 1)) { try await driver.start(value) }
        #expect(ContinuousClock.now - started < .seconds(15))
        driver.stop()
        try? await driver.waitUntilStopped()
    }

    @Test func unpackedApplicationCannotContactPrivilegedHelper() throws {
        let (preferences, name) = preferences(); defer { UserDefaults().removePersistentDomain(forName: name) }
        let helper = MacHelperFixture()
        let driver = MacTunnelDriver(helper: helper, transport: MacHTTPFixture(), installed: { false })
        #expect(throws: TunnelError.installation) { try driver.profileOptions(preferences) }
        #expect(helper.commands.isEmpty)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ECYCLOUD_TEST_MIHOMO"] != nil))
    func standbyStartsExistingCoreWithoutProxyOrTUNAndStopsOnLogout() async throws {
        let (preferences, name) = preferences(); defer { UserDefaults().removePersistentDomain(forName: name) }
        preferences.tunEnabled = true
        preferences.mixedPort = try MacPorts.allocate().mixed
        let helper = MacHelperFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mac-standby-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        helper.executable = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECYCLOUD_TEST_MIHOMO"]!)
        helper.directory = directory
        defer { helper.cleanup(); try? FileManager.default.removeItem(at: directory) }
        let driver = MacTunnelDriver(helper: helper, transport: URLSessionTransport(configuration: {
            let value = URLSessionConfiguration.ephemeral; value.connectionProxyDictionary = [:]; return value
        }), installed: { true })
        let controller = ConnectionController(driver: driver)
        var options = try driver.profileOptions(preferences)
        options.tunEnabled = false
        var config = try JSONSerialization.jsonObject(with: remote) as! [String: Any]
        config["rule-providers"] = ["synthetic-rules": ["type": "inline", "behavior": "domain", "payload": ["example.test"], "path": "ECYCloud-Rules/synthetic.yaml"]]
        let profile = try ProfileAssembler.assemble(JSONSerialization.data(withJSONObject: config), options: options)
        let value = TunnelLease(owner: owner, expiresAt: .now.addingTimeInterval(3600), configuration: profile.data, validationConfiguration: profile.validationData)
        await controller.reconcile(owner: owner, expiresAt: value.expiresAt)
        try await controller.prepareStandby(value)
        #expect(controller.controlPlaneReady && controller.state == .disconnected)
        #expect(helper.commands.contains("kernel.start") && !helper.commands.contains("proxy.set"))
        _ = try await controller.request(.init(.snapshot))
        helper.ruleContent = String(repeating: "a", count: 40000)
        let first = try JSONSerialization.jsonObject(with: await controller.request(.init(.rules, group: "synthetic-rules", scope: "content"))) as! [String: Any]
        helper.ruleContent = String(repeating: "b", count: 40000)
        let second = try JSONSerialization.jsonObject(with: await controller.request(.init(.rules, page: 2, group: "synthetic-rules", scope: "content", query: first["version"] as! String))) as! [String: Any]
        #expect(Data(base64Encoded: second["data"] as! String) == Data(repeating: 97, count: 40000 - 32768))
        #expect(second["done"] as? Bool == true && helper.commands.filter { $0 == "kernel.read" }.count == 1)
        await #expect(throws: TunnelError.control) { try await controller.request(.init(.rules, page: 2, group: "synthetic-rules", scope: "content", query: first["version"] as! String)) }
        controller.disconnect()
        try await driver.waitUntilStopped()
        // 断开只发 kernel.stop：进程停掉即可，替身只有 kernel.clear 才清空 process
        #expect(helper.process?.isRunning != true && !controller.controlPlaneReady)
    }

    @Test func sandboxMigrationPreservesDeviceAndLogoutGuardWithoutImportingFlutterState() throws {
        let name = "ecycloud-migration-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".plist")
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: file) }
        let values: [String: Any] = ["com.ecycloud.client.apple-native.device-id": "fixture-device",
                                    "com.ecycloud.client.apple-native.logout-pending": true,
                                    "apple.proxyMode": "global", "apple.ipv6": true, "flutter.settings": "excluded"]
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: file)
        defaults.set("direct", forKey: "apple.proxyMode")
        ClientPreferences.migrateMacDefaults(applicationID: "com.ecycloud.client", from: file, defaults: defaults)
        #expect(defaults.string(forKey: "com.ecycloud.client.apple-native.device-id") == "fixture-device")
        #expect(defaults.bool(forKey: "com.ecycloud.client.apple-native.logout-pending"))
        #expect(defaults.string(forKey: "apple.proxyMode") == "direct" && defaults.bool(forKey: "apple.ipv6"))
        #expect(defaults.object(forKey: "flutter.settings") == nil)
        defaults.set(false, forKey: "com.ecycloud.client.apple-native.logout-pending")
        ClientPreferences.migrateMacDefaults(applicationID: "com.ecycloud.client", from: file, defaults: defaults)
        #expect(!defaults.bool(forKey: "com.ecycloud.client.apple-native.logout-pending"))
    }

    @Test func unreadableLegacySettingsDoNotBlockLaunchAndAreNotRetried() throws {
        let name = "ecycloud-migration-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".plist")
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: file) }
        try Data("not a property list".utf8).write(to: file)
        defaults.set("direct", forKey: "apple.proxyMode")
        ClientPreferences.migrateMacDefaults(applicationID: "com.ecycloud.client", from: file, defaults: defaults)
        #expect(defaults.bool(forKey: "apple.migratedSandboxPreferences") && defaults.string(forKey: "apple.proxyMode") == "direct")
        #expect(defaults.bool(forKey: "com.ecycloud.client.apple-native.logout-pending"))
        #expect(KeychainVault(service: "com.ecycloud.client.apple-native", defaults: defaults).logoutPending)
        try PropertyListSerialization.data(fromPropertyList: ["apple.ipv6": true], format: .binary, options: 0).write(to: file)
        ClientPreferences.migrateMacDefaults(applicationID: "com.ecycloud.client", from: file, defaults: defaults)
        #expect(defaults.object(forKey: "apple.ipv6") == nil)
    }

    @Test func failedProxyRestoreReleasesKernelAndReportsItsOwnCause() async throws {
        let (preferences, name) = preferences(); defer { UserDefaults().removePersistentDomain(forName: name) }
        let helper = MacHelperFixture(); helper.valid = false; helper.failRestore = true
        let driver = MacTunnelDriver(helper: helper, transport: MacHTTPFixture(), installed: { true })
        let controller = ConnectionController(driver: driver), lease = try lease(driver, preferences)
        await controller.reconcile(owner: owner, expiresAt: lease.expiresAt)
        await controller.connect(lease)
        try await driver.waitUntilStopped()
        #expect(controller.state == .disconnected && controller.message == TunnelError.proxyRestore.localizedDescription)
        await controller.connect(lease)
        try await driver.waitUntilStopped()
        #expect(helper.commands.filter { $0 == "kernel.check" }.count == 2)
        #expect(helper.commands.filter { $0 == "proxy.restore" }.count == 6)
    }

    @Test func helperValidationErrorAndAccountKeyReachTheUser() async throws {
        let (preferences, name) = preferences(); defer { UserDefaults().removePersistentDomain(forName: name) }
        let helper = MacHelperFixture(); helper.valid = false; helper.checkError = "合成校验错误"
        let driver = MacTunnelDriver(helper: helper, transport: MacHTTPFixture(), installed: { true })
        let controller = ConnectionController(driver: driver)
        let assembled = try ProfileAssembler.assemble(remote, options: driver.profileOptions(preferences))
        let account = String(repeating: "b", count: 64)
        let value = TunnelLease(owner: owner, cacheKey: account, expiresAt: .now.addingTimeInterval(3600), configuration: assembled.data, validationConfiguration: assembled.validationData)
        await controller.reconcile(owner: owner, expiresAt: value.expiresAt)
        await controller.connect(value)
        #expect(controller.message == L10n.t("配置校验未通过：{0}", ["合成校验错误"]))
        #expect(helper.payloads["kernel.bind"]?["cache_key"] as? String == account)
        try await driver.waitUntilStopped()
        controller.disconnect(clearLogsFor: owner, account: account)
        let deadline = ContinuousClock.now + .seconds(5)
        while helper.payloads["kernel.clear"] == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(helper.payloads["kernel.clear"]?["cache_key"] as? String == account)
    }

    @Test func kernelThatExitsDuringStartupFailsFastWithHelperReason() async throws {
        let (preferences, name) = preferences(); defer { UserDefaults().removePersistentDomain(forName: name) }
        let helper = MacHelperFixture(); helper.exitOnStart = true; helper.exitError = "合成内核退出原因"
        let driver = MacTunnelDriver(helper: helper, transport: MacHTTPFixture(), installed: { true })
        let controller = ConnectionController(driver: driver), lease = try lease(driver, preferences)
        await controller.reconcile(owner: owner, expiresAt: lease.expiresAt)
        let started = ContinuousClock.now
        await controller.connect(lease)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(controller.message == "合成内核退出原因")
        try await driver.waitUntilStopped()
    }

    @Test func systemProxyPreferenceWithoutTakeoverTouchesNothing() async throws {
        let helper = MacHelperFixture()
        let driver = MacTunnelDriver(helper: helper, transport: MacHTTPFixture(), installed: { true })
        try await driver.applySystemProxy(enabled: false, bypass: ["example.test"])
        #expect(helper.commands.isEmpty)
        await #expect(throws: TunnelError.configuration) { try await driver.applySystemProxy(enabled: true, bypass: ["bad value with spaces"]) }
    }

    @Test func failedKernelStopIsRetriedBeforeNextStart() async throws {
        let (preferences, name) = preferences(); defer { UserDefaults().removePersistentDomain(forName: name) }
        let helper = MacHelperFixture(); helper.valid = false; helper.failedStops = 3
        let driver = MacTunnelDriver(helper: helper, transport: MacHTTPFixture(), installed: { true })
        let controller = ConnectionController(driver: driver), lease = try lease(driver, preferences)
        await controller.reconcile(owner: owner, expiresAt: lease.expiresAt)
        await controller.connect(lease)
        let failure = TunnelError.failed(L10n.t("停止内核失败：{0}", [TunnelError.helperUnavailable.localizedDescription]))
        await #expect(throws: failure) { try await driver.waitUntilStopped() }
        #expect(helper.commands.filter { $0 == "kernel.stop" }.count == 3 && !helper.commands.contains("proxy.restore"))
        #expect(controller.state == .disconnecting && controller.message == failure.localizedDescription)
        try await driver.waitUntilStopped()
        #expect(helper.commands.filter { $0 == "kernel.stop" }.count == 4 && helper.commands.filter { $0 == "proxy.restore" }.count == 1)
        await controller.connect(lease)
        try await driver.waitUntilStopped()
        #expect(helper.commands.filter { $0 == "kernel.check" }.count == 2)
    }

    // helper 卡住时停止请求按预算超时：保持「正在断开」并给出原因，不再自动重放第二轮；helper 恢复后点重试断开即收敛
    @Test func stuckHelperStopFailsWithinBudgetAndRetryConverges() async throws {
        let (preferences, name) = preferences(); defer { UserDefaults().removePersistentDomain(forName: name) }
        let helper = MacHelperFixture(); helper.valid = false; helper.stuckStops = true
        let driver = MacTunnelDriver(helper: helper, transport: MacHTTPFixture(), installed: { true }, stopBudget: .milliseconds(600))
        let controller = ConnectionController(driver: driver), lease = try lease(driver, preferences)
        await controller.reconcile(owner: owner, expiresAt: lease.expiresAt)
        let started = ContinuousClock.now
        await controller.connect(lease)
        let failure = TunnelError.failed(L10n.t("停止内核失败：{0}", [L10n.t("后台服务响应超时")]))
        await #expect(throws: failure) { try await driver.waitUntilStopped() }
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(helper.commands.filter { $0 == "kernel.stop" }.count == 1 && !helper.commands.contains("proxy.restore"))
        #expect(controller.state == .disconnecting && controller.message == failure.localizedDescription)
        helper.stuckStops = false
        controller.disconnect()
        try await driver.waitUntilStopped()
        #expect(controller.state == .disconnected && controller.message == nil)
        #expect(helper.commands.filter { $0 == "kernel.stop" }.count == 2 && helper.commands.filter { $0 == "proxy.restore" }.count == 1)
    }

    @Test func selectionSucceedsWhenClosingOldConnectionsFailsAndOnlyTargetsSelectors() async throws {
        let transport = SelectionFixture(failConnections: true)
        let runtime = try MacClashRuntime(configuration: configuration(), transport: transport)
        _ = try await runtime.request(.init(.select, group: "选择", node: "node-1"))
        #expect(await transport.calls == ["GET /proxies/选择", "PUT /proxies/选择", "GET /connections"])
        await #expect(throws: TunnelError.control) { try await runtime.request(.init(.select, group: "自动", node: "node-1")) }
        #expect(await !transport.calls.contains("PUT /proxies/自动"))
    }

    @Test func largeSnapshotFitsDesktopControlChannel() async throws {
        let runtime = try MacClashRuntime(configuration: configuration(), transport: SelectionFixture(members: (1...8000).map { "node-\($0)" }))
        let data = try await runtime.request(.init(.snapshot))
        #expect(data.count > 65536)
        #expect(try JSONDecoder().decode(TunnelSnapshot.self, from: data).groups.first?.members.count == 8000)
    }

    @Test func cancelledBindingCannotStartKernelOrEnableProxy() async throws {
        let (preferences, name) = preferences(); defer { UserDefaults().removePersistentDomain(forName: name) }
        let helper = MacHelperFixture(); helper.suspendBinding = true
        let driver = MacTunnelDriver(helper: helper, transport: MacHTTPFixture(), installed: { true })
        let controller = ConnectionController(driver: driver), lease = try lease(driver, preferences)
        await controller.reconcile(owner: owner, expiresAt: lease.expiresAt)
        let task = Task { await controller.connect(lease) }
        while helper.binding == nil { await Task.yield() }
        controller.disconnect()
        helper.binding?.resume(); helper.binding = nil
        await task.value
        await driver.reconcile(owner: nil)
        #expect(!helper.commands.contains("kernel.start") && !helper.commands.contains("proxy.set"))
        #expect(helper.commands.contains("kernel.stop") && !helper.commands.contains("kernel.clear") && controller.state == .disconnected)
    }

    @Test func failedValidationPreventsStartAndCleansSession() async throws {
        let (preferences, name) = preferences(); defer { UserDefaults().removePersistentDomain(forName: name) }
        let helper = MacHelperFixture(); helper.valid = false
        let driver = MacTunnelDriver(helper: helper, transport: MacHTTPFixture(), installed: { true })
        let controller = ConnectionController(driver: driver), lease = try lease(driver, preferences)
        await controller.reconcile(owner: owner, expiresAt: lease.expiresAt)
        await controller.connect(lease)
        await driver.reconcile(owner: nil)
        #expect(controller.message == TunnelError.configuration.localizedDescription)
        #expect(!helper.commands.contains("kernel.start") && !helper.appliedProxy)
        #expect(helper.commands.contains("kernel.stop") && !helper.commands.contains("kernel.clear"))
    }

    @Test func runtimeCacheIsClearedOnlyWhenSessionEnds() async throws {
        let (preferences, name) = preferences(); defer { UserDefaults().removePersistentDomain(forName: name) }
        let helper = MacHelperFixture(); helper.valid = false
        let driver = MacTunnelDriver(helper: helper, transport: MacHTTPFixture(), installed: { true })
        let controller = ConnectionController(driver: driver), lease = try lease(driver, preferences)
        await controller.reconcile(owner: owner, expiresAt: lease.expiresAt)
        await controller.connect(lease)
        try await driver.waitUntilStopped()
        #expect(helper.commands.contains("kernel.stop") && helper.commands.contains("proxy.restore") && !helper.commands.contains("kernel.clear"))
        controller.disconnect(clearLogsFor: owner, account: owner)
        let deadline = ContinuousClock.now + .seconds(5)
        while !helper.commands.contains("kernel.clear") && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(helper.commands.filter { $0 == "kernel.clear" }.count == 1)
    }

    @Test func controllerRejectsNonLoopbackAndMalformedSecrets() {
        for endpoint in ["0.0.0.0:19867", "localhost:19867", "127.0.0.1:80", "example.test:19867"] {
            var value = configuration(); value["external-controller"] = endpoint
            #expect(throws: TunnelError.configuration) { try MacClashRuntime(configuration: value, transport: MacHTTPFixture()) }
        }
        var value = configuration(); value["secret"] = "bad\ncredential"
        #expect(throws: TunnelError.configuration) { try MacClashRuntime(configuration: value, transport: MacHTTPFixture()) }
    }

    @Test func realConnectionShapeHistoryAndGroupsMatchSharedUI() async throws {
        let transport = MacHTTPFixture(), runtime = try MacClashRuntime(configuration: configuration(), transport: transport)
        try await transport.setConnections(Data(#"[{"id":"connection-one","metadata":{"network":"tcp","host":"fixture.test","sourceIP":"127.0.0.1","sourcePort":"23456","destinationIP":"::1","destinationPort":"80","remoteDestination":"192.0.2.9","process":"fixture","processPath":"/fixture/bin/fixture","type":"Mixed"},"upload":22,"download":33,"start":"2026-10-20T00:00:00Z","chains":["DIRECT","选择"],"rule":"Match","rulePayload":""}]"#.utf8))
        let first = try JSONDecoder().decode(TunnelSnapshot.self, from: await runtime.request(.init(.snapshot, scope: "all")))
        let firstConnection = try #require(first.connections.first)
        #expect(first.active == 1 && firstConnection.destination == "fixture.test:80" && firstConnection.rule == "Match")
        #expect(first.groups.count == 1 && first.groups[0].members == ["node-1", "DIRECT"])
        #expect(first.delays == ["node-1": 42])
        #expect(firstConnection.source == "127.0.0.1:23456" && firstConnection.ip == "::1" && firstConnection.port == "80" && firstConnection.remoteDestination == "192.0.2.9")
        #expect(firstConnection.processPath == "/fixture/bin/fixture" && firstConnection.rulePayload.isEmpty && firstConnection.inbound == "Mixed")
        runtime.appendLogs(["level=info msg=\"[TCP] 127.0.0.1:23456(fixture) --> fixture.test:80 match Match using DIRECT\"", "level=info msg=\"[TCP] 127.0.0.1:1(other) --> other.test:80 using DIRECT\""])
        let logs = try JSONDecoder().decode(TunnelLogs.self, from: await runtime.request(.init(.logs)))
        #expect(logs.entries.map(\.inbound) == [nil, "Mixed"])
        try await transport.setConnections(Data("[]".utf8))
        let next = try JSONDecoder().decode(TunnelSnapshot.self, from: await runtime.request(.init(.snapshot, scope: "closed")))
        #expect(next.active == 0 && next.closed == 1 && next.connections.first?.closedAt != nil)
        let closedLogs = try JSONDecoder().decode(TunnelLogs.self, from: await runtime.request(.init(.logs)))
        #expect(closedLogs.entries.last?.inbound == "Mixed")
        let calls = await transport.calls
        #expect(calls.allSatisfy { $0.url?.host == "127.0.0.1" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "s", count: 48) })
    }

    // 内核拨号失败只写策略组名：按报错里的节点地址或手动选择组的选中项补出节点，自动测速组停在组名，分不出就不补
    @Test func dialFailureLogNamesTheNode() {
        let selectors = ["Google服务": "主节点", "主节点": "node-1", "流媒体": "自动选择"]
        let endpoints = ["chtcht.ecydns.com:10002": ["node-1"], "shared.example.test:443": ["node-1", "node-2"]]
        func annotate(_ message: String) -> String { MacClashRuntime.dialNode(message, selectors: selectors, endpoints: endpoints) }
        #expect(annotate("[UDP] dial Google服务 (match RuleSet/google) 172.19.0.1:56589 --> a.test:443 error: CHTCHT.ecydns.com:10002 connect error: context deadline exceeded")
            == "[UDP] dial Google服务 → node-1 (match RuleSet/google) 172.19.0.1:56589 --> a.test:443 error: CHTCHT.ecydns.com:10002 connect error: context deadline exceeded")
        #expect(annotate("[TCP] dial 主节点 1.1.1.1:1 --> a.test:443 error: shared.example.test:443 connect error: EOF")
            == "[TCP] dial 主节点 → node-1 1.1.1.1:1 --> a.test:443 error: shared.example.test:443 connect error: EOF")
        #expect(annotate("[TCP] dial Google服务 (match Match/) 1.1.1.1:1 --> a.test:443 error: context deadline exceeded")
            .hasPrefix("[TCP] dial Google服务 → node-1 (match"))
        #expect(annotate("[TCP] dial 流媒体 (match Match/) 1.1.1.1:1 --> a.test:443 error: EOF").hasPrefix("[TCP] dial 流媒体 → 自动选择 (match"))
        for raw in ["[TCP] dial 流媒体 (match Match/) 1.1.1.1:1 --> a.test:443 error: shared.example.test:443 connect error: EOF",
                    "[TCP] dial DIRECT (match GeoIP/cn) 1.1.1.1:1 --> a.test:443 error: dial tcp 1.2.3.4:443: i/o timeout",
                    "[TCP] 1.1.1.1:1 --> a.test:443 match Match using 主节点[node-1]"] {
            #expect(annotate(raw) == raw)
        }
    }

    // 内核的出站表随节点数增长：每秒采样只读连接表，出站表只在界面取快照或链路上出现没见过的出站时才取
    @Test func backgroundSamplingReadsTheProxyTableOnlyWhenNeeded() async throws {
        let transport = MacHTTPFixture(), runtime = try MacClashRuntime(configuration: configuration(), transport: transport)
        func counts() async -> (connections: Int, proxies: Int, providers: Int) {
            let paths = await transport.calls.map { $0.url!.path }
            return (paths.count { $0 == "/connections" }, paths.count { $0 == "/proxies" }, paths.count { $0 == "/providers/proxies" })
        }
        // 采样每秒一轮：等到连接表又被读过两轮再看出站表读了几次，不按固定时长等
        func afterTwoSamples() async throws -> (connections: Int, proxies: Int, providers: Int) {
            let start = await counts().connections
            var seen = await counts(), waited = 0
            while seen.connections < start + 2, waited < 200 {
                try await Task.sleep(for: .milliseconds(50))
                seen = await counts(); waited += 1
            }
            return seen
        }
        runtime.startTrafficSampling()
        defer { runtime.close() }
        var seen = try await afterTwoSamples()
        #expect(seen.connections >= 2 && seen.proxies == 1 && seen.providers == 1)
        try await transport.setConnections(Data(#"[{"id":"c1","metadata":{"network":"tcp","host":"fixture.test"},"upload":1,"download":2,"start":"2026-01-01T00:00:00Z","chains":["node-9","选择"],"rule":"Match"}]"#.utf8))
        seen = try await afterTwoSamples()
        #expect(seen.proxies == 2 && seen.providers == 2)
        let before = seen
        _ = try await runtime.request(.init(.snapshot))
        seen = await counts()
        #expect(seen.proxies == before.proxies + 1 && seen.providers == before.providers + 1)
    }

    @Test func logsRedactCredentialsAndKeepBoundedHistory() async throws {
        var config = configuration(); config["password"] = "fixture-password"
        let runtime = try MacClashRuntime(configuration: config, transport: MacHTTPFixture())
        runtime.appendLogs((0..<2005).map { "level=warning msg=\"row \($0) fixture-password https://user:pass@fixture.test/path?token=secret#fragment\"" })
        let logs = try JSONDecoder().decode(TunnelLogs.self, from: await runtime.request(.init(.logs)))
        #expect(logs.total == 2000 && logs.entries.count == 20)
        let entry = try #require(logs.entries.first)
        #expect(!entry.message.contains("fixture-password"))
        #expect(!entry.message.contains("user:pass") && !entry.message.contains("?token="))
        runtime.close()
        await #expect(throws: TunnelError.control) { try await runtime.request(.init(.snapshot)) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ECYCLOUD_TEST_MIHOMO"] != nil))
    func officialKernelValidatesStartsForwardsAndStopsWithoutChangingSystemNetwork() async throws {
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECYCLOUD_TEST_MIHOMO"]!)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mac-kernel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = MacHelperFixture(); helper.executable = executable; helper.directory = directory
        defer { helper.cleanup(); try? FileManager.default.removeItem(at: directory) }
        let (preferences, name) = preferences(); defer { UserDefaults().removePersistentDomain(forName: name) }
        preferences.mixedPort = try MacPorts.allocate().mixed
        let driver = MacTunnelDriver(helper: helper, transport: URLSessionTransport(configuration: {
            let value = URLSessionConfiguration.ephemeral; value.connectionProxyDictionary = [:]; return value
        }), installed: { true })
        let controller = ConnectionController(driver: driver), lease = try lease(driver, preferences)
        await controller.reconcile(owner: owner, expiresAt: lease.expiresAt)
        await controller.connect(lease)
        #expect(controller.state == .connected && helper.process?.isRunning == true && helper.appliedProxy)
        let snapshot = try JSONDecoder().decode(TunnelSnapshot.self, from: await controller.request(.init(.snapshot, scope: "all")))
        // 合计只计经代理节点的流量（MacClashRuntime.accumulate）；规则全走 DIRECT，连上后没有代理流量
        #expect(snapshot.uploadTotal == 0 && snapshot.downloadTotal == 0)
        let config = try JSONSerialization.jsonObject(with: lease.configuration) as! [String: Any]
        let mixedPort = config["mixed-port"] as! Int
        let controllerPort = Int((config["external-controller"] as! String).split(separator: ":").last!)!
        let rejected = try await MacSocket.forwardProbe(port: mixedPort < 65535 ? mixedPort + 1 : mixedPort - 1,
                                                       controller: controllerPort, credential: "ecy-speed:wrong-password")
        #expect(rejected == 403)
        #expect(snapshot.groups.contains { $0.id == "选择" })
        _ = try await controller.request(.init(.mode, mode: "direct"))
        let changed = try JSONDecoder().decode(TunnelSnapshot.self, from: await controller.request(.init(.snapshot)))
        #expect(changed.mode == "direct")
        controller.disconnect()
        await driver.reconcile(owner: nil)
        #expect(controller.state == .disconnected && helper.process?.isRunning != true && !helper.appliedProxy)
        #expect(helper.commands.firstIndex(of: "kernel.check")! < helper.commands.firstIndex(of: "kernel.start")!)
        #expect(helper.commands.firstIndex(of: "kernel.start")! < helper.commands.firstIndex(of: "proxy.set")!)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ECYCLOUD_TEST_MIHOMO"] != nil))
    func exitedKernelIsReportedAndRestartedAndProxyToggleKeepsKernel() async throws {
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECYCLOUD_TEST_MIHOMO"]!)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mac-restart-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = MacHelperFixture(); helper.executable = executable; helper.directory = directory
        defer { helper.cleanup(); try? FileManager.default.removeItem(at: directory) }
        let (preferences, name) = preferences(); defer { UserDefaults().removePersistentDomain(forName: name) }
        preferences.mixedPort = try MacPorts.allocate().mixed
        let driver = MacTunnelDriver(helper: helper, transport: URLSessionTransport(configuration: {
            let value = URLSessionConfiguration.ephemeral; value.connectionProxyDictionary = [:]; return value
        }), installed: { true })
        let controller = ConnectionController(driver: driver), lease = try lease(driver, preferences)
        await controller.reconcile(owner: owner, expiresAt: lease.expiresAt)
        await controller.connect(lease)
        #expect(controller.state == .connected && helper.appliedProxy)
        try await controller.applySystemProxy(preferences.with(systemProxy: false))
        #expect(!helper.appliedProxy && helper.process?.isRunning == true && helper.commands.filter { $0 == "kernel.start" }.count == 1)
        try await controller.applySystemProxy(preferences.with(systemProxy: true))
        #expect(helper.appliedProxy && helper.commands.filter { $0 == "kernel.start" }.count == 1)
        helper.process?.terminate(); helper.process?.waitUntilExit()
        let deadline = ContinuousClock.now + .seconds(15)
        while (helper.commands.filter { $0 == "kernel.start" }.count < 2 || controller.state != .connected) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(helper.commands.filter { $0 == "kernel.start" }.count == 2 && controller.state == .connected && helper.appliedProxy)
        controller.disconnect()
        await driver.reconcile(owner: nil)
        #expect(helper.process?.isRunning != true && !helper.appliedProxy)
    }

    // 覆盖安装后 helper 以代码签名校验失败拒绝仍在运行的旧进程：轮询与停止都失败时要照实显示 helper 的原因
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ECYCLOUD_TEST_MIHOMO"] != nil))
    func helperRejectionWhileConnectedReportsHelperReason() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mac-reject-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = MacHelperFixture()
        helper.executable = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECYCLOUD_TEST_MIHOMO"]!); helper.directory = directory
        defer { helper.cleanup(); try? FileManager.default.removeItem(at: directory) }
        let (preferences, name) = preferences(); defer { UserDefaults().removePersistentDomain(forName: name) }
        preferences.mixedPort = try MacPorts.allocate().mixed
        let driver = MacTunnelDriver(helper: helper, transport: URLSessionTransport(configuration: {
            let value = URLSessionConfiguration.ephemeral; value.connectionProxyDictionary = [:]; return value
        }), installed: { true })
        let controller = ConnectionController(driver: driver), lease = try lease(driver, preferences)
        await controller.reconcile(owner: owner, expiresAt: lease.expiresAt)
        await controller.connect(lease)
        #expect(controller.state == .connected)
        let reason = "调用方代码签名校验失败: OSStatus -67034"
        helper.rejection = reason
        let deadline = ContinuousClock.now + .seconds(15)
        while !(helper.commands.suffix(3) == ["kernel.stop", "kernel.stop", "kernel.stop"] && controller.message == reason) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(controller.message == reason && controller.state == .disconnecting)
        helper.rejection = nil
        try await driver.waitUntilStopped()
        await driver.reconcile(owner: nil)
    }

    // 节点副本超过装载上限时内核只装一部分；之后装入别的节点、把待测节点放进探测节点文件，都只重读节点文件，内核进程不换
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ECYCLOUD_TEST_MIHOMO"] != nil))
    func officialKernelLoadsNodesOnDemandWithoutRestart() async throws {
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECYCLOUD_TEST_MIHOMO"]!)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mac-nodes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = MacHelperFixture(); helper.executable = executable; helper.directory = directory
        defer { helper.cleanup(); try? FileManager.default.removeItem(at: directory) }
        let (preferences, name) = preferences(); defer { UserDefaults().removePersistentDomain(forName: name) }
        preferences.mixedPort = try MacPorts.allocate().mixed
        let transport = URLSessionTransport(configuration: {
            let value = URLSessionConfiguration.ephemeral; value.connectionProxyDictionary = [:]; return value
        })
        let driver = MacTunnelDriver(helper: helper, transport: transport, installed: { true })
        let controller = ConnectionController(driver: driver)
        let count = NodeWorkingSet.copyBudget + 200, pinned = "node-\(count)", probed = "node-\(count - 1)"
        let catalog = try JSONSerialization.data(withJSONObject: [
            "proxies": [Any](),
            "proxy-providers": ["ecy-panel-nodes": ["type": "file", "path": "ecy-panel-nodes.json",
                                                    "payload": (1...count).map { ["name": "node-\($0)", "type": "socks5", "server": "127.0.0.1", "port": 9] }]],
            "proxy-groups": [["name": "选择", "type": "select", "proxies": ["DIRECT"], "use": ["ecy-panel-nodes"]]],
            "rules": ["MATCH,DIRECT"]
        ])
        func lease(_ base: ProfileOptions, pinned: [String] = [], probe: [String] = []) throws -> TunnelLease {
            var options = base; options.tunEnabled = false
            let assembled = try ProfileAssembler.assemble(catalog, options: options, pinned: pinned, probe: probe)
            return TunnelLease(owner: owner, expiresAt: .now.addingTimeInterval(3600), configuration: assembled.data, validationConfiguration: assembled.validationData)
        }
        func snapshot() async throws -> TunnelSnapshot { try JSONDecoder().decode(TunnelSnapshot.self, from: await controller.request(.init(.snapshot))) }
        func members() async throws -> [String] { try #require(try await snapshot().groups.first { $0.id == "选择" }).members }
        await controller.reconcile(owner: owner, expiresAt: nil)
        try await controller.prepareStandby(lease(driver.profileOptions(preferences)))
        let process = try #require(helper.process?.processIdentifier)
        helper.writtenNodeFiles = []
        var loaded = try await members()
        #expect(loaded.count == NodeWorkingSet.copyBudget + 1 && !loaded.contains(pinned) && !loaded.contains(probed))
        let live = try #require(try controller.liveProfileOptions(preferences))
        #expect(try await controller.updateNodes(lease(live, pinned: [pinned])))
        _ = try await controller.request(.init(.select, group: "选择", node: pinned))
        loaded = try await members()
        #expect(loaded.count == NodeWorkingSet.copyBudget + 1 && loaded.contains(pinned) && !loaded.contains(probed))
        #expect(try await snapshot().selections["选择"] == pinned && helper.writtenNodeFiles == ["ecy-panel-nodes"])
        helper.writtenNodeFiles = []
        #expect(try await controller.updateNodes(lease(live, pinned: [pinned], probe: [probed])))
        #expect(helper.writtenNodeFiles == [NodeWorkingSet.probeProvider])
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(live.controllerPort)/providers/proxies/\(NodeWorkingSet.probeProvider)")!)
        request.setValue("Bearer " + live.secret, forHTTPHeaderField: "Authorization")
        let provider = try JSONSerialization.jsonObject(with: await transport.send(request).data) as! [String: Any]
        #expect((provider["proxies"] as? [[String: Any]])?.map { $0["name"] as? String } == [probed])
        // 探测节点文件里的节点连不上，内核照常受理并回报测试失败；它不进任何分组，已选中的节点不变
        await #expect(throws: TunnelError.control) { try await controller.request(.init(.probe, node: probed, scope: "delay")) }
        #expect(try await members() == loaded)
        #expect(try await snapshot().selections["选择"] == pinned)
        #expect(helper.process?.processIdentifier == process && helper.process?.isRunning == true)
        #expect(helper.commands.filter { $0 == "kernel.start" }.count == 1 && controller.controlPlaneReady && controller.state == .disconnected)
        controller.disconnect()
        await driver.reconcile(owner: nil)
        #expect(helper.process?.isRunning != true)
    }

    @Test func logRedactionMatchesBridgeKeys() {
        let redactor = MacLogRedactor(configuration: ["proxies": [["name": "n", "obfs-password": "obfs-value", "auth-token": "token-value", "uuid": "uuid-value"]]])
        let text = redactor.redact("dial obfs-value token-value uuid-value https://user:pass@example.test/private/path?q=1")
        #expect(!text.contains("obfs-value") && !text.contains("token-value") && !text.contains("uuid-value"))
        #expect(!text.contains("private/path") && !text.contains("user:pass") && text.contains("example.test"))
    }
}
#endif

#if os(macOS)
@MainActor private extension ClientPreferences {
    func with(systemProxy: Bool) -> ClientPreferences { self.systemProxy = systemProxy; return self }
}
@Suite("macOS 主窗口") @MainActor
struct MacMainWindowTests {
    private final class Window: NSWindow {
        var shown = false, iconified = false
        override var isVisible: Bool { shown }
        override var isMiniaturized: Bool { iconified }
    }
    private func window(_ id: String?, visible: Bool = false, minimized: Bool = false) -> Window {
        let value = Window(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        value.isReleasedWhenClosed = false
        value.identifier = id.map { NSUserInterfaceItemIdentifier($0) }
        value.shown = visible; value.iconified = minimized
        return value
    }

    // 托盘「打开客户端」只复用可见或最小化的主窗口：已关闭但还留在窗口表里的、状态栏与其它场景的窗口都不算
    @Test func trayReusesOnlyVisibleOrMinimizedMainWindow() {
        let status = window(nil, visible: true), closed = window("main-AppWindow-1"), other = window("settings-AppWindow-1", visible: true)
        let minimized = window("main-AppWindow-2", minimized: true), visible = window("main-AppWindow-3", visible: true)
        #expect(MacMainWindow.existing("main", in: [status, closed, other]) == nil)
        #expect(MacMainWindow.existing("main", in: [status, closed, minimized]) === minimized)
        #expect(MacMainWindow.existing("main", in: [closed, other, visible]) === visible)
    }
}
#endif
