#if os(macOS)
import AppKit

public enum MacMainWindow {
    // SwiftUI 给 WindowGroup(id:) 的窗口标识为 <id>-AppWindow-<序号>；关闭的窗口还会在 NSApp.windows 里留一段时间
    @MainActor public static func existing(_ id: String, in windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.identifier?.rawValue.hasPrefix(id + "-AppWindow-") == true && ($0.isVisible || $0.isMiniaturized) }
    }
}
#endif
