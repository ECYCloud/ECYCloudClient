import Foundation
import Observation

@MainActor @Observable
public final class ClientPreferences {
    public enum Mode: String, CaseIterable, Sendable {
        case rule, global, direct
        public var title: String { switch self { case .rule: L10n.t("规则"); case .global: L10n.t("全局"); case .direct: L10n.t("直连") } }
    }
    @ObservationIgnored private let defaults: UserDefaults
    public var mode: Mode { didSet { defaults.set(mode.rawValue, forKey: "apple.proxyMode") } }
    public var ipv6: Bool { didSet { defaults.set(ipv6, forKey: "apple.ipv6") } }
    public var tunEnabled: Bool { didSet { defaults.set(tunEnabled, forKey: "apple.tunEnabled") } }
    public var systemProxy: Bool { didSet { defaults.set(systemProxy, forKey: "apple.systemProxy") } }
    public var strictRoute: Bool { didSet { defaults.set(strictRoute, forKey: "apple.strictRoute") } }
    public var allowLAN: Bool { didSet { defaults.set(allowLAN, forKey: "apple.allowLAN") } }
    public var mixedPort: Int { didSet { defaults.set(mixedPort, forKey: "apple.mixedPort") } }
    public var systemProxyBypass: [String] { didSet { defaults.set(systemProxyBypass, forKey: "apple.systemProxyBypass") } }
    public var excludedRoutes: [String] { didSet { defaults.set(excludedRoutes, forKey: "apple.excludedRoutes") } }
    public var autoConnect: Bool { didSet { defaults.set(autoConnect, forKey: "apple.autoConnect") } }
    public var closeToTray: Bool { didSet { defaults.set(closeToTray, forKey: "apple.closeToTray") } }
    public var logLevel: String { didSet { defaults.set(logLevel, forKey: "apple.logLevel") } }
    var ticketInbox: [String: Any] { didSet { defaults.set(ticketInbox, forKey: "apple.ticketInbox") } }
    public var language: AppLanguage {
        didSet {
            if defaults === UserDefaults.standard { L10n.setLanguage(language) }
            else { defaults.set(language.rawValue, forKey: "apple.language") }
        }
    }
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: "apple.proxyMode").flatMap(Mode.init(rawValue:)) ?? .rule
        ipv6 = defaults.bool(forKey: "apple.ipv6")
        tunEnabled = defaults.bool(forKey: "apple.tunEnabled")
        systemProxy = defaults.object(forKey: "apple.systemProxy") as? Bool ?? true
        strictRoute = defaults.bool(forKey: "apple.strictRoute")
        allowLAN = defaults.bool(forKey: "apple.allowLAN")
        let port = defaults.integer(forKey: "apple.mixedPort")
        mixedPort = (1025...65535).contains(port) ? port : 10203
        systemProxyBypass = defaults.stringArray(forKey: "apple.systemProxyBypass") ?? []
        excludedRoutes = defaults.stringArray(forKey: "apple.excludedRoutes") ?? []
        autoConnect = defaults.bool(forKey: "apple.autoConnect")
        closeToTray = defaults.object(forKey: "apple.closeToTray") as? Bool ?? true
        ticketInbox = defaults.dictionary(forKey: "apple.ticketInbox") ?? [:]
        logLevel = defaults.string(forKey: "apple.logLevel").flatMap { ["debug", "info", "warning", "error", "silent"].contains($0) ? $0 : nil } ?? "warning"
        language = AppLanguage.resolve(defaults.string(forKey: "apple.language"))
    }
    public var packetProfile: ProfileOptions {
        var options = ProfileOptions.packetFlow
        options.mode = mode.rawValue; options.ipv6 = ipv6
        options.excludedRoutes = excludedRoutes
        return options
    }
}

#if os(macOS)
extension ClientPreferences {
    public static func migrateMacDefaults(applicationID: String) throws {
        let legacy = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(applicationID)/Data/Library/Preferences/\(applicationID).plist")
        try migrateMacDefaults(applicationID: applicationID, from: legacy, defaults: .standard)
    }
    static func migrateMacDefaults(applicationID: String, from legacy: URL, defaults: UserDefaults) throws {
        let marker = "apple.migratedSandboxPreferences"
        guard !defaults.bool(forKey: marker) else { return }
        if FileManager.default.fileExists(atPath: legacy.path) {
            do {
                let attributes = try legacy.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard attributes.isRegularFile == true, let size = attributes.fileSize, size <= 1024 * 1024,
                      let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: legacy), format: nil) as? [String: Any] else {
                    throw ClientError.invalidResponse
                }
                for (key, value) in values where key.hasPrefix("apple.") || key.hasPrefix(applicationID + ".apple-native.") {
                    if defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
                }
            } catch { throw ClientError.input(L10n.t("无法读取旧版客户端设置，请关闭旧版后重试。")) }
        }
        defaults.set(true, forKey: marker)
    }
}
#endif
