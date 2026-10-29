import Foundation
import CryptoKit

@MainActor public final class RemoteIconStore {
    public nonisolated static let maximumBytes = 1024 * 1024
    private var cache: [URL: Data] = [:]
    private var pending: [URL: Task<Data, Error>] = [:]
    private var generation = 0
    private let baseDirectory: URL?
    private var directory: URL?
    private let configuration: @Sendable () -> URLSessionConfiguration
    public init() {
        configuration = { .ephemeral }
        baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("ECYCloud/icons", isDirectory: true)
    }
    init(directory: URL? = nil, configuration: @escaping @Sendable () -> URLSessionConfiguration) {
        baseDirectory = directory; self.configuration = configuration
    }
    public func configure(owner: String) {
        guard owner.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { return }
        let next = baseDirectory?.appendingPathComponent(owner, isDirectory: true)
        guard directory != next else { return }
        clear(); directory = next
    }
    public nonisolated static func resolve(_ raw: String?, origin: URL) -> URL? {
        let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: text.isEmpty ? "https://rules.ecydy.com/images/Custom.png" : text, relativeTo: origin)?.absoluteURL,
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil,
              url.absoluteString.utf8.count <= 4096 else { return nil }
        return url
    }
    public func clear() {
        generation += 1
        for task in pending.values { task.cancel() }
        pending.removeAll(); cache.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
    public func load(_ url: URL) async throws -> Data {
        if let data = cache[url] { return data }
        let file = directory?.appendingPathComponent(SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".icon")
        if let file, let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
           values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= Self.maximumBytes,
           let data = try? Data(contentsOf: file), Self.isImage(data) {
            if cache.count >= 64 { cache.removeAll() }
            cache[url] = data
            return data
        }
        if let task = pending[url] { return try await task.value }
        let operation = generation
        let configuration = configuration
        let task = Task { try await Self.download(url, configuration: configuration()) }
        pending[url] = task
        defer { if generation == operation { pending[url] = nil } }
        let data = try await task.value
        guard generation == operation else { throw CancellationError() }
        if cache.count >= 64 { cache.removeAll() }
        if let file {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        cache[url] = data
        return data
    }
    private nonisolated static func download(_ url: URL, configuration: URLSessionConfiguration) async throws -> Data {
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let deadline = ContinuousClock.now + .seconds(10)
        var target = url
        for redirect in 0...5 {
            try Task.checkCancellation()
            guard let safe = resolve(target.absoluteString, origin: url), ContinuousClock.now < deadline else { throw ClientError.invalidResponse }
            let remaining = ContinuousClock.now.duration(to: deadline)
            var request = URLRequest(url: safe, timeoutInterval: Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirects())
            guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
            if [301, 302, 303, 307, 308].contains(response.statusCode) {
                guard redirect < 5, let location = response.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: safe)?.absoluteURL else { throw ClientError.invalidResponse }
                target = next
                continue
            }
            guard response.statusCode == 200, response.expectedContentLength <= maximumBytes else { throw ClientError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes, ContinuousClock.now < deadline else { throw ClientError.responseTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard isImage(data) else { throw ClientError.invalidResponse }
            return data
        }
        throw ClientError.invalidResponse
    }
    private nonisolated static func isImage(_ data: Data) -> Bool {
        if data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) || data.starts(with: [255, 216, 255]) { return true }
        if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) { return true }
        if data.count >= 12, data.starts(with: Data("RIFF".utf8)), data[8..<12] == Data("WEBP".utf8) { return true }
        let prefix = String(decoding: data.prefix(256), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return prefix.hasPrefix("<svg") || prefix.hasPrefix("<?xml")
    }
}
