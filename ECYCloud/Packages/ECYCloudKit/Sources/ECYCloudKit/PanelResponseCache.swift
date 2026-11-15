import CryptoKit
import Foundation

// 对应 panel_response_cache.dart 与 RemoteProfile.usableOffline：已登录时先凭缓存进入界面与本地内核，
// 节点授权仍由面板与节点按服务端到期时间判定
@MainActor public final class PanelResponseCache {
    private struct Entry: Codable {
        let account: String
        var binding = ""
        var issuedAt: Date?
        var validUntil: Date?
        var updateIntervalHours: Int?
        let response: Data
    }

    private struct OfflineWindow: Decodable {
        struct Authorization: Decodable {
            let issuedAt: Int
            let validUntil: Int
        }
        let offlineAuthorization: Authorization?
    }

    // 资料与节点配置随时可读供界面展示；validUntil 只在离线授权窗口内且仍绑定本次登录时给出，没有它不得拉起内核
    struct Restored {
        let profile: UserProfile
        let catalog: NodeCatalog?
        let validUntil: Date?
    }

    // 配置响应上限 8 MiB，Data 按 base64 编码后约增大三分之一
    private static let maximumFileBytes = 12 * 1024 * 1024
    private let directory: URL?

    public init(directory: URL? = UserDataDirectory.root?.appendingPathComponent("PanelCache", isDirectory: true)) {
        self.directory = directory
    }

    func saveProfile(_ response: Data, account: String) {
        write(Entry(account: Self.key(account), response: response), to: "profile.json")
    }

    // 配置含本设备的节点凭据，只以令牌派生的密钥加密落盘
    func saveConfig(_ response: Data, account: String, binding: String, sealKey: SymmetricKey, updateIntervalHours: Int?) {
        let key = Self.key(account)
        let window = (try? PanelAPI.decode(response) as OfflineWindow)?.offlineAuthorization
        guard let sealed = try? AES.GCM.seal(response, using: sealKey, authenticating: Data(key.utf8)).combined else { return }
        write(Entry(account: key, binding: binding,
                    issuedAt: window.map { Date(timeIntervalSince1970: TimeInterval($0.issuedAt)) },
                    validUntil: window.map { Date(timeIntervalSince1970: TimeInterval($0.validUntil)) },
                    updateIntervalHours: updateIntervalHours, response: sealed), to: "config.json")
    }

    func restore(account: String, binding: String, sealKey: SymmetricKey, now: Date) -> Restored? {
        let key = Self.key(account)
        guard !key.isEmpty, let profile = read("profile.json"), profile.account == key,
              let value: UserProfile = try? PanelAPI.decode(profile.response), (try? value.validate()) != nil else { return nil }
        guard let config = read("config.json"), config.account == key else {
            return Restored(profile: value, catalog: nil, validUntil: nil)
        }
        // 解不开的是旧版本明文缓存或已失效登录的缓存，前者含节点凭据，一律删除
        guard let box = try? AES.GCM.SealedBox(combined: config.response),
              let response = try? AES.GCM.open(box, using: sealKey, authenticating: Data(key.utf8)) else {
            remove("config.json")
            return Restored(profile: value, catalog: nil, validUntil: nil)
        }
        guard var catalog: NodeCatalog = try? PanelAPI.decode(response) else {
            return Restored(profile: value, catalog: nil, validUntil: nil)
        }
        catalog.updateIntervalHours = NodeCatalog.updateIntervalHours(config.updateIntervalHours.map(String.init))
        guard !binding.isEmpty, value.deviceKickReason != "remove", config.binding == binding,
              let issued = config.issuedAt, let until = config.validUntil, issued <= now, now < until else {
            return Restored(profile: value, catalog: catalog, validUntil: nil)
        }
        return Restored(profile: value, catalog: catalog, validUntil: until)
    }

    func clear() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func key(_ account: String) -> String {
        account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func read(_ name: String) -> Entry? {
        guard let file = directory?.appendingPathComponent(name),
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maximumFileBytes,
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    private func remove(_ name: String) {
        guard let file = directory?.appendingPathComponent(name) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    private func write(_ entry: Entry, to name: String) {
        guard var directory, !entry.account.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
            try JSONEncoder().encode(entry).write(to: directory.appendingPathComponent(name),
                                                  options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {}
    }
}
