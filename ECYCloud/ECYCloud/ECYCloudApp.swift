import SwiftUI
import ECYCloudKit

@main
struct ECYCloudApp: App {
    @State private var session: ClientSession?
    private let setupError: String?
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacApplicationDelegate.self) private var appDelegate
    #endif

    init() {
        do {
            let session = try AppSessionFactory.make()
            _session = State(initialValue: session)
            setupError = nil
            #if os(macOS)
            Self.keepSessionRunning(session)
            #endif
        } catch {
            setupError = (error as? ClientError)?.localizedDescription ?? L10n.t("无法读取客户端配置。")
        }
    }

    #if os(macOS)
    // 关闭主窗口只是收进托盘，内核仍在运行：会话启动与面板轮询不随窗口销毁，也不看窗口是否在前台
    private static func keepSessionRunning(_ session: ClientSession) {
        Task {
            await session.start()
            while true {
                await session.refresh(silently: true)
                let state = session.connection?.state
                let deadline = ContinuousClock.now + .seconds(session.refreshInterval)
                while ContinuousClock.now < deadline, session.connection?.state == state { try? await Task.sleep(for: .milliseconds(500)) }
            }
        }
    }
    #endif

    var body: some Scene {
        WindowGroup(id: "main") {
            if let session {
                ContentView(session: session)
                    #if os(macOS)
                    .frame(minWidth: 480, minHeight: 540)
                    .onAppear { appDelegate.session = session }
                    #endif
            } else {
                ContentUnavailableView(L10n.t("无法启动"), systemImage: "exclamationmark.triangle", description: Text(setupError!))
            }
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 720)
        .commands {
            // 与 Flutter 桌面版一样只有一个主窗口：去掉默认的「新建窗口」（⌘N）
            CommandGroup(replacing: .newItem) {
                Button(L10n.t("刷新账户与节点")) { Task { await session?.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(session?.phase != .signedIn || session?.busy == true)
            }
        }
        #endif
        #if os(macOS)
        MenuBarExtra { MacTrayView(session: session) } label: { Image("MenuBarIcon").accessibilityLabel("ECY Cloud") }
        #endif
    }
}
