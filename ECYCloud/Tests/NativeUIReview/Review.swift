#if os(macOS)
import AppKit
#endif
import CryptoKit
import ImageIO
import SwiftUI
import ECYCloudKit

@MainActor final class ReviewVault: CredentialVault {
    func loadRemembered() throws -> RememberedLogin? { nil }
    func saveRemembered(_ login: RememberedLogin) throws {}
    func clearRemembered() throws {}

    var logoutPending = false
    var endpoints: PanelEndpoints?
    var value: StoredSession?
    func load() throws -> StoredSession? { value }
    func save(_ value: StoredSession) throws { self.value = value }
    func clear() throws { value = nil }
}
struct ReviewTransport: HTTPTransport {
    let fixtures: [String: Data]
    init() throws {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: Bundle.main.url(forResource: "fixtures", withExtension: "json")!)) as! [String: Any]
        fixtures = try object.mapValues { try JSONSerialization.data(withJSONObject: ["ret": 1, "data": $0]) }
    }
    func send(_ request: URLRequest) async throws -> HTTPResult {
        let path = request.url!.path.replacingOccurrences(of: "/api/client/v1", with: "")
        guard let data = fixtures[path] else { print("UNEXPECTED: \(path)"); throw ClientError.invalidResponse }
        return HTTPResult(data: data, status: 200)
    }
}
struct UnreachableTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResult { throw ClientError.networkFailure(URLError.cannotConnectToHost.rawValue) }
}
struct ReviewFailure: Error { let message: String }

@MainActor final class ReviewDriver: TunnelDriver {
    var statusChanged: (@MainActor (ConnectionState) -> Void)?
    var supportsStandby: Bool { true }
    var selections = ["select": "node-12", "streaming": "node-13"]
    var delays = ["node-12": 128, "node-13": 520]
    var mode = "rule"
    func reconcile(owner: String?) async {}
    func start(_ lease: TunnelLease) async throws { print("REVIEW CONNECTED"); statusChanged?(.connected) }
    func startStandby(_ lease: TunnelLease) async throws { print("REVIEW STANDBY") }
    func stop() { statusChanged?(.disconnected) }
    func request(_ command: TunnelCommand) async throws -> Data {
        let result: [String: Any]
        switch command.action {
        case .snapshot:
            result = ["upload": 12000, "download": 480000, "uploadTotal": 120000, "downloadTotal": 4800000,
                      "connections": [], "total": 0, "page": 1, "selections": selections,
                      "groups": [["id": "select", "type": "select", "members": ["node-12", "node-13", "DIRECT"]],
                                 ["id": "streaming", "type": "url-test", "members": ["node-12", "node-13"]]],
                      "delays": delays, "memory": 32000000, "active": 0, "closed": 0, "mode": mode]
        case .select: selections[command.group] = command.node; result = [:]
        case .mode: mode = command.mode; result = [:]
        case .probe, .probes:
            try await Task.sleep(for: .seconds(2))
            if command.scope == "reselect" { selections[command.node] = "node-12" }
            if command.scope == "delay" { delays[command.node] = command.node == "node-13" ? nil : 128 }
            result = ["running": false, "failed": command.node == "node-13", "delay": 128, "speed": 12500000]
        case .logs: result = ["entries": [["id": 1, "time": "12:00:00", "level": "info", "message": "Synthetic offline review"]], "total": 1]
        case .version: result = ["version": "offline-review"]
        case .rules: result = ["providers": []]
        default: result = [:]
        }
        return try JSONSerialization.data(withJSONObject: result)
    }
}

@MainActor enum ReviewData {
    static func session(defaults: UserDefaults, vault: ReviewVault = ReviewVault(), cache: PanelResponseCache? = nil, transport: (any HTTPTransport)? = nil) throws -> ClientSession {
        let endpoints = try PanelEndpoints(site: "https://site.example.test", config: "https://config.example.test")
        let api = PanelAPI(device: .init(id: "offline-only", name: "Offline", model: "Review", os: "Review", platform: "macOS", version: "0.1.1"), transport: try transport ?? ReviewTransport())
        let connection = ConnectionController(driver: ReviewDriver())
        return ClientSession(endpoints: endpoints, api: api, vault: vault, connection: connection,
                             preferences: ClientPreferences(defaults: defaults), announcementState: AnnouncementState(defaults: defaults), nodeProbes: NodeProbeState(defaults: defaults), cache: cache)
    }
    // 先在线登录写入面板缓存，再以全部连不上的传输启动：已登录用户须直接进入主界面并显示缓存的资料与节点
    static func offlineStartup(defaults: UserDefaults, cache: PanelResponseCache) async throws -> ClientSession {
        let vault = ReviewVault()
        let online = try session(defaults: defaults, vault: vault, cache: cache)
        await online.restore()
        await online.login(email: "member@example.test", password: "synthetic-offline-password")
        await online.refresh()
        online.connection?.disconnect()
        let offline = try session(defaults: defaults, vault: vault, cache: cache, transport: UnreachableTransport())
        await offline.start()
        guard offline.phase == .signedIn, offline.profile != nil, offline.catalog?.selectionGroups.isEmpty == false else {
            throw ReviewFailure(message: "面板不可达时未凭缓存进入主界面：\(offline.phase) \(offline.message ?? "")")
        }
        await offline.connect()
        guard offline.message == L10n.t("本地配置授权已到期，请连接面板更新后重试"), offline.connection?.state == .disconnected else {
            throw ReviewFailure(message: "授权窗口外的缓存配置不得拉起内核：\(offline.message ?? "")")
        }
        print("OFFLINE STARTUP VERIFIED")
        return offline
    }
    static func signIn(_ session: ClientSession) async throws {
        await session.restore()
        await session.login(email: "member@example.test", password: "synthetic-offline-password")
        guard session.phase == .signedIn else { throw ClientError.invalidResponse }
        // 固定账户的本地图标夹具，避免界面验收访问外部图片服务。
        let owner = SHA256.hash(data: Data("synthetic-offline-token".utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ECYCloud/icons/" + owner)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let animated = NSMutableData()
        let destination = CGImageDestinationCreateWithData(animated, "com.compuserve.gif" as CFString, 2, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for color in [(1.0, 0.0, 0.0), (0.0, 0.0, 1.0)] {
            let context = CGContext(data: nil, width: 24, height: 24, bitsPerComponent: 8, bytesPerRow: 96, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
            CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.4]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw ClientError.invalidResponse }
        let svg = Data(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" fill="#00a060"/><path d="M6 12 L10 16 L18 8" stroke="white" fill="none" stroke-width="2"/></svg>"##.utf8)
        for (address, data) in [("https://site.example.test/review.gif", animated as Data), ("https://site.example.test/review.svg", svg), ("https://rules.ecydy.com/images/Custom.png", svg)] {
            let key = SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
            try data.write(to: directory.appendingPathComponent(key + ".icon"))
        }
        try await session.ensureControlPlane()
    }
}

#if os(macOS)
@main @MainActor struct Review {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task {
            do { try await render() }
            catch { print("RENDER ERROR: \(error)"); exit(1) }
            NSApplication.shared.terminate(nil)
        }
        NSApplication.shared.run()
    }
    static func render() async throws {
        // 脚本已隔离 CFFIXED_USER_HOME，沿用生产环境的标准偏好存储以验证语言即时更新。
        let defaults = UserDefaults.standard
        let domain = "com.ecycloud.native.offline-review"
        guard Bundle.main.bundleIdentifier == domain else { throw ClientError.configuration }
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        guard CommandLine.arguments.count == 2 else { throw ClientError.configuration }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let session = try ReviewData.session(defaults: defaults)
        let signedOut = try ReviewData.session(defaults: defaults)
        await signedOut.start()
        let cacheDirectory = output.appendingPathComponent(".panel-cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let offline = try await ReviewData.offlineStartup(defaults: defaults, cache: PanelResponseCache(directory: cacheDirectory))
        try await ReviewData.signIn(session)
        defer { session.icons.clear(); session.connection?.disconnect() }
        if ProcessInfo.processInfo.environment["ECY_UI_INTERACTIVE"] == "1" {
            NSApplication.shared.setActivationPolicy(.regular)
            let view = NSHostingView(rootView: ReviewRoot(session: session).environment(\.scenePhase, .active))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "ECYCloud 离线界面验收"; window.isReleasedWhenClosed = false; window.contentView = view
            window.center(); window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
            while window.isVisible { try await Task.sleep(for: .milliseconds(200)) }
            return
        }
        if let flow = ProcessInfo.processInfo.environment["ECY_UI_FLOW"] {
            try await interact(session: session, defaults: defaults, output: output, flow: flow)
            return
        }
        let cases: [(String, AnyView, CGFloat, CGFloat, ColorScheme)] = [
            ("icons-dark", AnyView(HStack {
                ProductGroupIcon(session: session, url: "https://site.example.test/review.gif", size: 60)
                ProductGroupIcon(session: session, url: "https://site.example.test/review.svg", size: 60)
                ProductGroupIcon(session: session, url: "http://invalid.example.test/icon.png", size: 60)
            }), 300, 100, .dark),
            ("settings-wide-light", AnyView(ClientSettingsView(session: session)), 1000, 1800, .light),
            ("settings-narrow-dark", AnyView(ClientSettingsView(session: session)), 390, 2400, .dark),
            ("en-settings-narrow-light", AnyView(ClientSettingsView(session: session)), 390, 2400, .light),
            ("tw-settings-narrow-dark", AnyView(ClientSettingsView(session: session)), 390, 2400, .dark),
            ("login-wide-light", AnyView(LoginView(session: signedOut)), 1000, 720, .light),
            ("login-narrow-dark", AnyView(LoginView(session: signedOut)), 390, 844, .dark),
            ("home-dark", AnyView(ClientHomeView(session: session).environment(AccountMenu(session: session))), 1000, 720, .dark),
            ("home-narrow-light", AnyView(ClientHomeView(session: session).environment(AccountMenu(session: session))), 480, 760, .light),
            ("shop-light", AnyView(ShopView(session: session, category: .constant(.plan))), 1000, 720, .light),
            ("shop-narrow-dark", AnyView(ShopView(session: session, category: .constant(.plan))), 390, 844, .dark),
            ("tickets-dark", AnyView(TicketsView(session: session)), 1000, 720, .dark),
            ("ticket-reply-light", AnyView(TicketConversationView(session: session, id: 12)), 700, 800, .light),
            ("security-dark", AnyView(AccountSecurityView(session: session, message: .constant(nil), working: .constant(false))), 700, 1500, .dark),
            ("strategy-groups-light", AnyView(SubscriptionStrategyView(session: session)), 700, 900, .light),
            ("strategy-light", AnyView(SubscriptionStrategyView(session: session, initialTab: 1)), 700, 900, .light),
            ("traffic-wide-light", AnyView(TrafficHistoryView(session: session)), 1000, 720, .light),
            ("traffic-narrow-dark", AnyView(TrafficHistoryView(session: session)), 390, 844, .dark),
            ("account-edit-dark", AnyView(AccountEditView(session: session)), 700, 900, .dark),
            ("account-delete-light", AnyView(DeleteAccountView(session: session)), 700, 800, .light),
            ("announcements-light", AnyView(AnnouncementsView(session: session)), 700, 720, .light),
            ("offline-start-wide-light", AnyView(ContentView(session: offline)), 1000, 720, .light),
            ("offline-start-narrow-dark", AnyView(ContentView(session: offline)), 390, 844, .dark)
        ]
        for (name, content, width, height, scheme) in cases {
            session.preferences.language = name.hasPrefix("en-") ? .enUS : name.hasPrefix("tw-") ? .zhTW : .zhCN
            defaults.set(scheme == .dark ? "dark" : "light", forKey: "apple.appearance")
            let root = content.font(.system(size: 13)).foregroundStyle(ProductPalette(scheme: scheme).text).background(ProductPalette(scheme: scheme).background).environment(\.colorScheme, scheme).environment(\.scenePhase, .active).frame(width: width, height: height)
            let view = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .seconds(2))
            for _ in 0..<5 {
                view.rootView = root
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            if name == "strategy-light" {
                var editorTexts: [String] = []
                func inspect(_ node: NSView) {
                    if let field = node as? NSTextView { editorTexts.append(field.string) }
                    for child in node.subviews { inspect(child) }
                }
                inspect(view)
                guard editorTexts.contains("example.test: 192.0.2.1") && editorTexts.contains("DOMAIN,example.test,DIRECT") else { throw ReviewFailure(message: "编辑器必须显示从接口读取的草稿") }
                print("EDITOR VALUES VERIFIED")
            }
            let rect = NSRect(x: 0, y: 0, width: width, height: height)
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else { throw ClientError.invalidResponse }
            view.cacheDisplay(in: rect, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name).png"))
            window.close()
            print("RENDERED: \(name)")
        }
    }

    // 交互验收：ECY_UI_FLOW="宽x高 light|dark|click x y|wait 秒|shot 名称"，坐标为视图左上角起的点。
    // 只向离屏窗口投递鼠标事件，不操作系统界面；调用方须避开「连接」与模式切换。
    static func interact(session: ClientSession, defaults: UserDefaults, output: URL, flow: String) async throws {
        var steps = flow.split(separator: "|").map { $0.split(separator: " ").map(String.init) }
        guard let size = steps.first, size.count == 2, let dimensions = Optional(size[0].split(separator: "x").compactMap { Double($0) }),
              dimensions.count == 2 else { throw ReviewFailure(message: "ECY_UI_FLOW 首段须为「宽x高 light|dark」") }
        steps.removeFirst()
        let width = CGFloat(dimensions[0]), height = CGFloat(dimensions[1]), scheme: ColorScheme = size[1] == "dark" ? .dark : .light
        defaults.set(scheme == .dark ? "dark" : "light", forKey: "apple.appearance")
        let root = NavigationStack { ClientHomeView(session: session).toolbar(.hidden) }.environment(AccountMenu(session: session)).font(.system(size: 13)).foregroundStyle(ProductPalette(scheme: scheme).text)
            .background(ProductPalette(scheme: scheme).background).environment(\.colorScheme, scheme).environment(\.scenePhase, .active).frame(width: width, height: height)
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { NSApplication.shared.windows.forEach { $0.close() } }
        try await Task.sleep(for: .seconds(2))
        for step in steps {
            switch (step.first, step.count) {
            case ("click", 3):
                guard let x = Double(step[1]), let y = Double(step[2]) else { throw ReviewFailure(message: "无效坐标 \(step)") }
                let point = NSPoint(x: x, y: Double(height) - y)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                    window.sendEvent(event)
                }
            case ("wait", 2):
                try await Task.sleep(for: .milliseconds(Int((Double(step[1]) ?? 0) * 1000)))
            case ("shot", 2):
                view.layoutSubtreeIfNeeded()
                for (index, target) in NSApplication.shared.windows.enumerated() where target.isVisible {
                    guard let content = target.contentView, let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
                    content.cacheDisplay(in: content.bounds, to: image)
                    let suffix = target === window ? "" : "-popup\(index)"
                    try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("flow-\(step[1])\(suffix).png"))
                }
                print("RENDERED: flow-\(step[1])")
            default: throw ReviewFailure(message: "无效步骤 \(step)")
            }
        }
    }
}
#else
@main struct Review: App {
    @State private var session: ClientSession?
    @State private var failure: String?
    var body: some Scene {
        WindowGroup {
            Group {
                if let session { ReviewRoot(session: session) }
                else if let failure { Text(verbatim: failure) }
                else { ProgressView().task {
                    do {
                        let value = try ReviewData.session(defaults: .standard)
                        try await ReviewData.signIn(value)
                        session = value
                    } catch { failure = String(describing: error) }
                } }
            }
        }
    }
}
#endif

struct ReviewRoot: View {
    let session: ClientSession
    @AppStorage("apple.appearance") private var appearance = "system"
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Group {
            if UserDefaults.standard.string(forKey: "review.page") == "settings" {
                ClientSettingsView(session: session).font(.system(size: 13))
                    .foregroundStyle(ProductPalette(scheme: scheme).text)
                    .background(ProductPalette(scheme: scheme).background)
            } else { ContentView(session: session) }
        }.preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }
}
