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
            _session = State(initialValue: try AppSessionFactory.make())
            setupError = nil
        } catch {
            setupError = (error as? ClientError)?.localizedDescription ?? L10n.t("无法读取客户端配置。")
        }
    }

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
            CommandGroup(after: .newItem) {
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
