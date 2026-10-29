#if os(macOS)
import SwiftUI
import ServiceManagement
import ECYCloudKit

@MainActor @Observable final class MacApplicationSettings {
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var requiresApproval = SMAppService.mainApp.status == .requiresApproval
    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
        refresh()
    }
    func refresh() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        requiresApproval = SMAppService.mainApp.status == .requiresApproval
    }
}

@MainActor final class MacApplicationDelegate: NSObject, NSApplicationDelegate {
    var session: ClientSession?
    private var terminating = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(session?.preferences.closeToTray ?? true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            do {
                try await session?.connection?.shutdown()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                terminating = false
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}

struct MacTrayView: View {
    let session: ClientSession?
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(L10n.t("打开客户端")) { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        if let session, session.phase == .signedIn {
            Button(session.connection?.state == .connected ? L10n.t("断开连接") : L10n.connectAction) {
                Task {
                    if session.connection?.state == .connected { await session.disconnectToStandby() }
                    else { await session.connect() }
                }
            }
        }
        Divider()
        Button(L10n.t("退出")) { NSApp.terminate(nil) }
    }
}
#endif
