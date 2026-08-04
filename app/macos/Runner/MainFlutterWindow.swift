import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // AppDelegate 要靠它在点击程序坞图标时还原窗口
  private(set) var platformChannel: PlatformChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // 与 Windows 同源：标题带上安装包版本号，不另存一份
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
      as? String ?? ""
    self.title = "ECY Cloud \(version)"

    // 界面按窄窗排版：节点卡最小 210 逻辑像素，这个宽度正好排四列，再宽只会留白
    self.setContentSize(NSSize(width: 1000, height: 720))
    self.center()

    platformChannel = PlatformChannel(
      messenger: flutterViewController.engine.binaryMessenger, window: self)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
