import Cocoa
import CoreImage
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

  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?

  private var statusItem: NSStatusItem?
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
  private var defaultDockIcon: NSImage?

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
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func installTray() {
    guard statusItem == nil else { return }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(
      systemSymbolName: "network", accessibilityDescription: appDisplayName)
    // 状态栏图标必须是模板图，否则深色菜单栏下会糊成一团
    item.button?.image?.isTemplate = true
    item.button?.target = self
    item.button?.action = #selector(onStatusItemClick)
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    statusItem = item
    applyStatusIcons()
  }

  private func removeTray() {
    guard let item = statusItem else { return }
    NSStatusBar.system.removeStatusItem(item)
    statusItem = nil
    NSApp.applicationIconImage = defaultDockIcon
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
    if defaultDockIcon == nil {
      defaultDockIcon = NSApp.applicationIconImage
    }
    let tint: NSColor?
    let hue: CGFloat?
    if tun {
      tint = NSColor(srgbRed: 0.18, green: 0.75, blue: 0.44, alpha: 1)
      hue = 145
    } else if systemProxy {
      tint = NSColor(srgbRed: 0.88, green: 0.45, blue: 0.08, alpha: 1)
      hue = 28
    } else {
      tint = nil
      hue = nil
    }
    statusItem?.button?.contentTintColor = tint
    statusItem?.button?.toolTip =
      statusTip.isEmpty ? appDisplayName : "\(appDisplayName)\n\(statusTip)"
    if let hue = hue, let source = defaultDockIcon {
      NSApp.applicationIconImage = hueShiftedDockIcon(source, targetHue: hue)
    } else {
      NSApp.applicationIconImage = defaultDockIcon
    }
  }

  private func hueShiftedDockIcon(_ source: NSImage, targetHue: CGFloat) -> NSImage {
    guard let tiff = source.tiffRepresentation,
      let input = CIImage(data: tiff),
      let filter = CIFilter(name: "CIHueAdjust")
    else {
      return source
    }
    filter.setValue(input, forKey: kCIInputImageKey)
    filter.setValue((targetHue - 210) * .pi / 180, forKey: kCIInputAngleKey)
    guard let output = filter.outputImage else { return source }
    let context = CIContext()
    guard let cg = context.createCGImage(output, from: output.extent) else {
      return source
    }
    return NSImage(cgImage: cg, size: source.size)
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
