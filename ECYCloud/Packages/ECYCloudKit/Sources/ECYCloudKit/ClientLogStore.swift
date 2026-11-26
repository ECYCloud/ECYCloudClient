import Foundation

// 本机 Application Support/ECYCloud：图标、流量排行、面板缓存与 macOS 日志都在这里；测试经 TaskLocal 换成临时目录，不碰真实数据
@usableFromInline enum UserDataDirectory {
    @TaskLocal static var override: URL?
    @usableFromInline static var root: URL? {
        #if os(tvOS)
        // tvOS 真机上应用只能写缓存与临时目录，Application Support 不可写（模拟器不限制）
        let directory = FileManager.SearchPathDirectory.cachesDirectory
        #else
        let directory = FileManager.SearchPathDirectory.applicationSupportDirectory
        #endif
        return override ?? FileManager.default.urls(for: directory, in: .userDomainMask).first?.appendingPathComponent("ECYCloud", isDirectory: true)
    }
}

final class ClientLogStore {
    static let levels = ["debug", "info", "warning", "error", "silent"]
    static let filePattern = #"^app-\d{4}-\d{2}-\d{2}\.log$"#
    let directory: URL
    var level: String
    private var day = ""
    private var handle: FileHandle?
    private var bytes = 0
    private let formatter: DateFormatter
    init(directory: URL, level: String) {
        self.directory = directory; self.level = level
        formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"
    }
    deinit { try? handle?.close() }
    func append(time: String, level: String, message: String) {
        guard let threshold = Self.levels.firstIndex(of: self.level), let severity = Self.levels.firstIndex(of: level),
              severity >= threshold, threshold < 4 else { return }
        do {
            let today = formatter.string(from: .now)
            let file = directory.appendingPathComponent("app-\(today).log")
            if day != today || handle == nil {
                try? handle?.close(); handle = nil
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let oldest = formatter.string(from: formatter.calendar.date(byAdding: .day, value: -29, to: .now)!)
                for old in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                    let name = old.lastPathComponent
                    if name.range(of: Self.filePattern, options: .regularExpression) != nil, String(name.dropFirst(4).prefix(10)) < oldest {
                        try FileManager.default.removeItem(at: old)
                    }
                }
                if !FileManager.default.fileExists(atPath: file.path) {
                    FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                guard values.isSymbolicLink != true, values.isRegularFile == true else { return }
                handle = try FileHandle(forUpdating: file); bytes = values.fileSize ?? 0; day = today
                try handle?.seekToEnd()
            }
            let data = Data("\(time) [\(level)] [mihomo] \(message.replacingOccurrences(of: "\n", with: " "))\n".utf8)
            guard data.count <= 10 * 1024 * 1024 else { return }
            if bytes + data.count > 10 * 1024 * 1024, let handle {
                try handle.seek(toOffset: UInt64(max(0, bytes - 8 * 1024 * 1024)))
                let tail = try handle.read(upToCount: 8 * 1024 * 1024) ?? Data()
                try handle.truncate(atOffset: 0); try handle.seek(toOffset: 0); try handle.write(contentsOf: tail)
                bytes = tail.count
            }
            try handle?.write(contentsOf: data); bytes += data.count
        } catch { try? handle?.close(); handle = nil }
    }
    static func directory(owner: String) -> URL? {
        guard owner.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { return nil }
        #if os(macOS)
        return UserDataDirectory.root?.appendingPathComponent("Logs/\(owner)", isDirectory: true)
        #else
        guard let applicationID = Bundle.main.bundleIdentifier else { return nil }
        return try? TunnelFiles.directory(group: "group." + applicationID).appendingPathComponent("Logs/\(owner)", isDirectory: true)
        #endif
    }
}
extension ClientSession {
    public var latestRuntimeLog: URL? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let directory = logDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return nil }
        return files.compactMap { url -> (URL, Date)? in
            guard url.lastPathComponent.range(of: ClientLogStore.filePattern, options: .regularExpression) != nil,
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }.max { $0.1 < $1.1 }?.0
    }
}
