import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private(set) var platformChannel: PlatformChannel?

  // 必须与 Dart AppPaths.userData 一致：~/Library/Application Support/ECYCloud
  private static let defaultSize = NSSize(width: 1000, height: 720)

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
      as? String ?? ""
    self.title = "ECY Cloud \(version)"

    self.setContentSize(Self.restoredSize())
    self.center()
    if Self.restoredMaximized() {
      self.setFrame(self.screen?.visibleFrame ?? self.frame, display: true)
    }

    NotificationCenter.default.addObserver(
      forName: NSWindow.didResizeNotification,
      object: self,
      queue: nil
    ) { [weak self] _ in
      self?.persistContentSize()
    }

    platformChannel = PlatformChannel(
      messenger: flutterViewController.engine.binaryMessenger, window: self)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  func persistContentSize() {
    guard let size = contentView?.frame.size,
          size.width >= 400, size.height >= 300,
          let url = Self.sizeFileURL() else {
      return
    }
    let zoomed = isZoomed || styleMask.contains(.fullScreen) ? 1 : 0
    let line = "\(Int(size.width.rounded())) \(Int(size.height.rounded())) \(zoomed)\n"
    try? line.write(to: url, atomically: true, encoding: .utf8)
  }

  private static func restoredSize() -> NSSize {
    guard let url = sizeFileURL(),
          let text = try? String(contentsOf: url, encoding: .utf8) else {
      return defaultSize
    }
    let parts = text.split { $0.isWhitespace || $0.isNewline }
    guard parts.count >= 2,
          let width = Double(parts[0]), let height = Double(parts[1]),
          width >= 400, height >= 300 else {
      return defaultSize
    }
    return NSSize(width: width, height: height)
  }

  private static func restoredMaximized() -> Bool {
    guard let url = sizeFileURL(),
          let text = try? String(contentsOf: url, encoding: .utf8) else {
      return false
    }
    let parts = text.split { $0.isWhitespace || $0.isNewline }
    return parts.count >= 3 && parts[2] == "1"
  }

  private static func sizeFileURL() -> URL? {
    guard let base = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first else {
      return nil
    }
    let dir = base.appendingPathComponent("ECYCloud", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true
    )
    return dir.appendingPathComponent("window-size")
  }
}
