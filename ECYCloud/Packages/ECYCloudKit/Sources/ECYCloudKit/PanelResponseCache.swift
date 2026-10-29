import Foundation

// 对应 panel_response_cache.dart 与 RemoteProfile.usableOffline：已登录时先凭缓存进入界面与本地内核，
// 节点授权仍由面板与节点按服务端到期时间判定
@MainActor public final class PanelResponseCache {
    private struct Entry: Codable {
        let account: String
        var binding = ""
        var issuedAt: Date?
        var validUntil: Date?
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

    public init(directory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("ECYCloud/PanelCache", isDirectory: true)) {
        self.directory = directory
    }

    func saveProfile(_ response: Data, account: String) {
        write(Entry(account: Self.key(account), response: response), to: "profile.json")
    }

    func saveConfig(_ response: Data, account: String, binding: String) {
        let window = (try? PanelAPI.decode(response) as OfflineWindow)?.offlineAuthorization
        write(Entry(account: Self.key(account), binding: binding,
                    issuedAt: window.map { Date(timeIntervalSince1970: TimeInterval($0.issuedAt)) },
                    validUntil: window.map { Date(timeIntervalSince1970: TimeInterval($0.validUntil)) },
                    response: response), to: "config.json")
    }

    func restore(account: String, binding: String, now: Date) -> Restored? {
        let key = Self.key(account)
        guard !key.isEmpty, let profile = read("profile.json"), profile.account == key,
              let value: UserProfile = try? PanelAPI.decode(profile.response), (try? value.validate()) != nil else { return nil }
        guard let config = read("config.json"), config.account == key,
              let catalog: NodeCatalog = try? PanelAPI.decode(config.response) else {
            return Restored(profile: value, catalog: nil, validUntil: nil)
        }
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
