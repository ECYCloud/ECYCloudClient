import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// 关窗口时可能只是缩到托盘，此时不能退出进程
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// 缩到托盘后点程序坞图标要能还原，否则界面再也调不出来
  override func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      mainWindow?.platformChannel?.restoreMainWindow()
    }
    return true
  }

  /// 同一个 .app 被重复拉起时（如从终端直接执行二进制）交还给已在运行的那个实例
  override func applicationWillFinishLaunching(_ notification: Notification) {
    let running = NSRunningApplication.runningApplications(
      withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
    ).filter { $0 != NSRunningApplication.current }

    if let existing = running.first {
      existing.activate(options: [.activateIgnoringOtherApps])
      NSApp.terminate(nil)
    }
  }

  private var mainWindow: MainFlutterWindow? {
    NSApp.windows.compactMap { $0 as? MainFlutterWindow }.first
  }
}
