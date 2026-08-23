import Cocoa
import FlutterMacOS
import Security

final class PlatformChannel: NSObject, NSMenuDelegate, NSWindowDelegate {
  private enum MenuTag: Int {
    case connect = 1
    case disconnect
    case systemProxy
    case tun
    case modeRule
    case modeGlobal
    case modeDirect
    case show
    case quit
  }

  private static let menuBarIconSize: CGFloat = 18
  private static let dockIconSize: CGFloat = 256

  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?

  private var statusItem: NSStatusItem?
  private var iconTint = -1
  private var closeToTray = false
  private var connected = false
  private var busy = false
  private var systemProxy = false
  private var tun = false
  private var modeEnabled = false
  private var routeMode = "rule"
  private var labelConnect = "连接"
  private var labelDisconnect = "断开连接"
  private var labelCancel = "取消连接"
  private var labelSystemProxy = "系统代理"
  private var labelTun = "TUN 模式"
  private var labelRule = "规则"
  private var labelGlobal = "全局"
  private var labelDirect = "直连"
  private var labelShow = "显示主界面"
  private var labelQuit = "退出"
  private var statusTip = ""
  // 换色源只能取包里的原图。NSApp.applicationIconImage 会被下面染完色的赋值顶掉，
  // 拿它当源第二次就是在已染色的图上再染一遍
  private lazy var appIcon: NSImage? =
    NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
  private var customCursors: [String: NSCursor] = [:]

  init(messenger: FlutterBinaryMessenger, window: NSWindow) {
    channel = FlutterMethodChannel(
      name: "ecycloud/platform", binaryMessenger: messenger)
    self.window = window
    super.init()

    window.delegate = self
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(
    _ call: FlutterMethodCall, result: @escaping FlutterResult
  ) {
    switch call.method {
    case "tray.install":
      installTray()
      result(nil)
    case "tray.remove":
      removeTray()
      result(nil)
    case "tray.closeToTray":
      guard let arguments = call.arguments as? [String: Any] else {
        result(FlutterError(code: "argument", message: "缺少参数", details: nil))
        return
      }
      closeToTray = arguments["enabled"] as? Bool ?? false
      result(nil)
    case "tray.state":
      guard let arguments = call.arguments as? [String: Any] else {
        result(FlutterError(code: "argument", message: "缺少参数", details: nil))
        return
      }
      connected = arguments["connected"] as? Bool ?? false
      busy = arguments["busy"] as? Bool ?? false
      systemProxy = arguments["system_proxy"] as? Bool ?? false
      tun = arguments["tun"] as? Bool ?? false
      modeEnabled = arguments["mode_enabled"] as? Bool ?? false
      if let value = arguments["route_mode"] as? String, !value.isEmpty {
        routeMode = value
      }
      if let value = arguments["label_connect"] as? String, !value.isEmpty {
        labelConnect = value
      }
      if let value = arguments["label_disconnect"] as? String, !value.isEmpty {
        labelDisconnect = value
      }
      if let value = arguments["label_cancel"] as? String, !value.isEmpty {
        labelCancel = value
      }
      if let value = arguments["label_system_proxy"] as? String, !value.isEmpty {
        labelSystemProxy = value
      }
      if let value = arguments["label_tun"] as? String, !value.isEmpty {
        labelTun = value
      }
      if let value = arguments["label_rule"] as? String, !value.isEmpty {
        labelRule = value
      }
      if let value = arguments["label_global"] as? String, !value.isEmpty {
        labelGlobal = value
      }
      if let value = arguments["label_direct"] as? String, !value.isEmpty {
        labelDirect = value
      }
      if let value = arguments["label_show"] as? String, !value.isEmpty {
        labelShow = value
      }
      if let value = arguments["label_quit"] as? String, !value.isEmpty {
        labelQuit = value
      }
      statusTip = arguments["status_tip"] as? String ?? ""
      applyStatusIcons()
      result(nil)
    case "secret.protect":
      guard let arguments = call.arguments as? [String: Any],
        let name = arguments["name"] as? String,
        let value = arguments["value"] as? String
      else {
        result(FlutterError(code: "argument", message: "缺少参数", details: nil))
        return
      }
      do {
        try storeSecret(name, value)
        result("")
      } catch {
        result(
          FlutterError(
            code: "secret", message: error.localizedDescription, details: nil))
      }
    case "secret.unprotect":
      guard let arguments = call.arguments as? [String: Any],
        let name = arguments["name"] as? String
      else {
        result(FlutterError(code: "argument", message: "缺少参数", details: nil))
        return
      }
      do {
        result(try readSecret(name))
      } catch {
        result(
          FlutterError(
            code: "secret", message: error.localizedDescription, details: nil))
      }
    case "secret.delete":
      guard let arguments = call.arguments as? [String: Any],
        let name = arguments["name"] as? String
      else {
        result(FlutterError(code: "argument", message: "缺少参数", details: nil))
        return
      }
      deleteSecret(name)
      result(nil)
    case "cursor.create":
      createCursor(call.arguments, result: result)
    case "cursor.set":
      setCursor(call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func createCursor(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let arguments = arguments as? [String: Any],
      let name = arguments["name"] as? String,
      let data = arguments["buffer"] as? FlutterStandardTypedData,
      let width = intArg(arguments["width"]),
      let height = intArg(arguments["height"]),
      width > 0,
      height > 0,
      data.data.count >= width * height * 4
    else {
      result(FlutterError(code: "argument", message: "缺少参数", details: nil))
      return
    }
    let logical = max(intArg(arguments["logicalSize"]) ?? width, 1)
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: width,
      pixelsHigh: height,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: width * 4,
      bitsPerPixel: 32
    ), let planes = rep.bitmapData
    else {
      result(FlutterError(code: "cursor", message: "无法创建指针图像", details: nil))
      return
    }
    data.data.copyBytes(to: planes, count: width * height * 4)
    // size 用逻辑点，否则 Retina 上像素尺寸会被当成点，放大镜大一倍
    let image = NSImage(size: NSSize(width: logical, height: logical))
    image.addRepresentation(rep)
    let scale = CGFloat(width) / CGFloat(logical)
    let hotX = (doubleArg(arguments["hotX"]) ?? (Double(width) * 0.35)) / Double(scale)
    let hotY = (doubleArg(arguments["hotY"]) ?? (Double(height) * 0.35)) / Double(scale)
    customCursors[name] = NSCursor(
      image: image, hotSpot: NSPoint(x: hotX, y: hotY))
    result(nil)
  }

  private func setCursor(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let arguments = arguments as? [String: Any],
      let name = arguments["name"] as? String,
      let cursor = customCursors[name]
    else {
      result(FlutterError(code: "argument", message: "缺少参数", details: nil))
      return
    }
    cursor.set()
    // FlutterView.cursorUpdate 会把指针改回 _lastCursor；不登记的话放大镜会被引擎盖成箭头
    rememberFlutterCursor(cursor)
    result(nil)
  }

  private func rememberFlutterCursor(_ cursor: NSCursor) {
    guard let root = window?.contentView else {
      return
    }
    var pending: [NSView] = [root]
    let sel = NSSelectorFromString("didUpdateMouseCursor:")
    while let view = pending.popLast() {
      if view.responds(to: sel) {
        view.perform(sel, with: cursor)
        return
      }
      pending.append(contentsOf: view.subviews)
    }
  }

  private func intArg(_ value: Any?) -> Int? {
    if let value = value as? Int {
      return value
    }
    if let value = value as? NSNumber {
      return value.intValue
    }
    return nil
  }

  private func doubleArg(_ value: Any?) -> Double? {
    if let value = value as? Double {
      return value
    }
    if let value = value as? Int {
      return Double(value)
    }
    if let value = value as? NSNumber {
      return value.doubleValue
    }
    return nil
  }

  private func installTray() {
    guard statusItem == nil else { return }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.target = self
    item.button?.action = #selector(onStatusItemClick)
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    statusItem = item
    iconTint = -1
    applyStatusIcons()
  }

  private func removeTray() {
    guard let item = statusItem else { return }
    NSStatusBar.system.removeStatusItem(item)
    statusItem = nil
    NSApp.applicationIconImage = nil
  }

  @objc private func onStatusItemClick() {
    guard let button = statusItem?.button else { return }

    if NSApp.currentEvent?.type == .rightMouseUp {
      let menu = buildMenu()
      menu.popUp(
        positioning: nil,
        at: NSPoint(x: 0, y: button.bounds.height + 4),
        in: button)
      return
    }
    restoreMainWindow()
  }

  private func buildMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false

    if busy {
      menu.addItem(makeItem(labelCancel, .disconnect))
    } else if connected {
      menu.addItem(makeItem(labelDisconnect, .disconnect))
    } else {
      menu.addItem(makeItem(labelConnect, .connect))
    }
    menu.addItem(.separator())

    let proxyItem = makeItem(labelSystemProxy, .systemProxy)
    proxyItem.isEnabled = connected
    proxyItem.state = systemProxy ? .on : .off
    menu.addItem(proxyItem)

    let tunItem = makeItem(labelTun, .tun)
    tunItem.isEnabled = connected
    tunItem.state = tun ? .on : .off
    menu.addItem(tunItem)

    menu.addItem(.separator())
    let mode = (routeMode == "global" || routeMode == "direct") ? routeMode : "rule"
    let ruleItem = makeItem(labelRule, .modeRule)
    ruleItem.isEnabled = modeEnabled
    ruleItem.state = mode == "rule" ? .on : .off
    menu.addItem(ruleItem)
    let globalItem = makeItem(labelGlobal, .modeGlobal)
    globalItem.isEnabled = modeEnabled
    globalItem.state = mode == "global" ? .on : .off
    menu.addItem(globalItem)
    let directItem = makeItem(labelDirect, .modeDirect)
    directItem.isEnabled = modeEnabled
    directItem.state = mode == "direct" ? .on : .off
    menu.addItem(directItem)

    menu.addItem(.separator())
    menu.addItem(makeItem(labelShow, .show))
    menu.addItem(.separator())
    menu.addItem(makeItem(labelQuit, .quit))
    return menu
  }

  private func makeItem(_ title: String, _ tag: MenuTag) -> NSMenuItem {
    let item = NSMenuItem(
      title: title, action: #selector(onMenuCommand(_:)), keyEquivalent: "")
    item.target = self
    item.tag = tag.rawValue
    return item
  }

  @objc private func onMenuCommand(_ sender: NSMenuItem) {
    switch MenuTag(rawValue: sender.tag) {
    case .connect:
      emitTrayAction("connect")
    case .disconnect:
      emitTrayAction("disconnect")
    case .systemProxy:
      emitTrayAction("system_proxy")
    case .tun:
      emitTrayAction("tun")
    case .modeRule:
      emitTrayAction("mode_rule")
    case .modeGlobal:
      emitTrayAction("mode_global")
    case .modeDirect:
      emitTrayAction("mode_direct")
    case .show:
      restoreMainWindow()
    case .quit:
      removeTray()
      NSApp.terminate(nil)
    case .none:
      break
    }
  }

  private func emitTrayAction(_ action: String) {
    channel.invokeMethod("tray.action", arguments: action)
  }

  private func applyStatusIcons() {
    statusItem?.button?.toolTip =
      statusTip.isEmpty ? appDisplayName : "\(appDisplayName)\n\(statusTip)"

    let want = tun ? 2 : (systemProxy ? 1 : 0)
    guard want != iconTint else { return }
    iconTint = want

    let hue: CGFloat? = want == 2 ? 145 : (want == 1 ? 28 : nil)
    if let source = NSImage(named: "MenuBarIcon") ?? appIcon,
      let image = statusIcon(source, points: Self.menuBarIconSize, targetHue: hue)
    {
      image.accessibilityDescription = appDisplayName
      statusItem?.button?.image = image
    }
    if let hue = hue, let source = appIcon {
      NSApp.applicationIconImage = statusIcon(
        source, points: Self.dockIconSize, targetHue: hue)
    } else {
      // 还原程序坞图标只能写 nil，赋回自己读出来的那张不还原
      NSApp.applicationIconImage = nil
    }
  }

  private func statusIcon(_ source: NSImage, points: CGFloat, targetHue: CGFloat?)
    -> NSImage?
  {
    let pixels = Int(points * 2)
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: pixels * 4,
        bitsPerPixel: 32
      ), let context = NSGraphicsContext(bitmapImageRep: rep)
    else {
      return nil
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    source.draw(
      in: NSRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)))
    NSGraphicsContext.restoreGraphicsState()
    if let targetHue = targetHue {
      recolor(rep, targetHue: targetHue)
    }
    // rep 是 2 倍像素，尺寸按点写回，否则菜单栏与程序坞会按像素当点画得过大
    rep.size = NSSize(width: points, height: points)
    let image = NSImage(size: NSSize(width: points, height: points))
    image.addRepresentation(rep)
    return image
  }

  /// 与 Windows / Linux 同一套判据：只把蓝色系像素改成目标色相，保留饱和度与明度，
  /// 白底与白色字形不动
  private func recolor(_ rep: NSBitmapImageRep, targetHue: CGFloat) {
    guard let pixels = rep.bitmapData else { return }
    for index in 0..<(rep.pixelsWide * rep.pixelsHigh) {
      let pixel = pixels + index * 4
      if pixel[3] == 0 {
        continue
      }
      let (hue, saturation, lightness) = rgbToHsl(
        CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255)
      if saturation <= 0.12 || hue < 170 || hue > 270 {
        continue
      }
      let (red, green, blue) = hslToRgb(targetHue, saturation, lightness)
      pixel[0] = UInt8((red * 255).rounded())
      pixel[1] = UInt8((green * 255).rounded())
      pixel[2] = UInt8((blue * 255).rounded())
    }
  }

  private func rgbToHsl(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat)
    -> (CGFloat, CGFloat, CGFloat)
  {
    let high = max(red, green, blue)
    let low = min(red, green, blue)
    let lightness = (high + low) / 2
    if high == low {
      return (0, 0, lightness)
    }
    let delta = high - low
    let saturation =
      lightness > 0.5 ? delta / (2 - high - low) : delta / (high + low)
    var hue: CGFloat
    if high == red {
      hue = (green - blue) / delta + (green < blue ? 6 : 0)
    } else if high == green {
      hue = (blue - red) / delta + 2
    } else {
      hue = (red - green) / delta + 4
    }
    return (hue * 60, saturation, lightness)
  }

  private func hslToRgb(_ hue: CGFloat, _ saturation: CGFloat, _ lightness: CGFloat)
    -> (CGFloat, CGFloat, CGFloat)
  {
    if saturation == 0 {
      return (lightness, lightness, lightness)
    }
    let q =
      lightness < 0.5
      ? lightness * (1 + saturation)
      : lightness + saturation - lightness * saturation
    let p = 2 * lightness - q
    let hk = hue / 360
    return (
      hueChannel(p, q, hk + 1.0 / 3.0),
      hueChannel(p, q, hk),
      hueChannel(p, q, hk - 1.0 / 3.0)
    )
  }

  private func hueChannel(_ p: CGFloat, _ q: CGFloat, _ offset: CGFloat) -> CGFloat {
    var t = offset
    if t < 0 {
      t += 1
    }
    if t > 1 {
      t -= 1
    }
    if t < 1.0 / 6.0 {
      return p + (q - p) * 6 * t
    }
    if t < 0.5 {
      return q
    }
    if t < 2.0 / 3.0 {
      return p + (q - p) * (2.0 / 3.0 - t) * 6
    }
    return p
  }

  func restoreMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  /// 托盘不可用时不能只是藏起来，否则窗口再也调不出来，只能连进程一起退
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if closeToTray, statusItem != nil {
      sender.orderOut(nil)
      return false
    }
    removeTray()
    NSApp.terminate(nil)
    return false
  }

  private var appDisplayName: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? "ECY Cloud"
  }

  private static let secretService = "com.ecycloud.client"

  private func storeSecret(_ name: String, _ password: String) throws {
    deleteSecret(name)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.secretService,
      kSecAttrAccount as String: name,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData as String: Data(password.utf8),
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
  }

  private func readSecret(_ name: String) throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.secretService,
      kSecAttrAccount as String: name,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess, let data = item as? Data else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    return String(data: data, encoding: .utf8)
  }

  private func deleteSecret(_ name: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.secretService,
      kSecAttrAccount as String: name,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
