#if os(macOS)
import Foundation
import Network

enum MacSpeedProbe {
    static func configuration(port: Int, credential: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!))
        proxy.allowFailover = false
        let separator = credential.firstIndex(of: ":")!
        proxy.applyCredential(username: String(credential[..<separator]), password: String(credential[credential.index(after: separator)...]))
        configuration.proxyConfigurations = [proxy]
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 10
        return configuration
    }
    static func measure(port: Int, credential: String) async throws -> Int64 {
        let session = URLSession(configuration: configuration(port: port, credential: credential))
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://speed.cloudflare.com/__down?bytes=100000000")!, timeoutInterval: 10)
        request.setValue("https://speed.cloudflare.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        var total: Int64 = 0, window: Int64 = 0, peak: Int64 = 0
        let started = ContinuousClock.now
        var sampled = started
        var firstByte: ContinuousClock.Instant?
        func takeSample(_ now: ContinuousClock.Instant) {
            let elapsed = sampled.duration(to: now)
            let milliseconds = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000 + 1
            if milliseconds > 1000 {
                peak = max(peak, Int64((Double(window) * 1000 / Double(milliseconds)).rounded()))
                sampled = now; window = 0
            }
        }
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirects())
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
                  response.expectedContentLength <= 100_000_000 else { throw TunnelError.control }
            for try await _ in bytes {
                if firstByte == nil { firstByte = .now; sampled = firstByte! }
                total += 1; window += 1
                if total >= 100_000_000 { break }
                if total % 16384 == 0 {
                    try Task.checkCancellation()
                    let now = ContinuousClock.now
                    takeSample(now)
                    if total >= 100_000_000 || started.duration(to: now) >= .seconds(10) { break }
                }
            }
        } catch is URLError where total >= 32768 {
        }
        try Task.checkCancellation()
        guard total >= 32768, let firstByte else { throw TunnelError.control }
        takeSample(.now)
        if peak == 0 {
            let elapsed = firstByte.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            if seconds > 0 { peak = Int64((Double(total) / seconds).rounded()) }
        }
        guard peak > 0 else { throw TunnelError.control }
        return peak
    }
}
#endif
