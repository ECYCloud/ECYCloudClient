import Foundation
import Network

// 对应 panel_api_client.dart 的 _directHttpClient：接管连接期间面板直连必须绕开本机 TUN / VPN 隧道。
// URLSession 无法指定出口网卡，这里用 Network 框架绑定当前物理网卡并不走系统代理；只禁用 utun 时系统会退回本机代理口。
// 未设置 enforceRoutes / includeAllNetworks 时，绑定物理网卡的连接不进隧道。只发 HTTP/1.1 且每次请求后关闭连接
struct PhysicalInterfaceTransport: HTTPTransport {
    private static let queue = DispatchQueue(label: "com.ecycloud.panel.direct")
    private static let crlf = Data("\r\n".utf8)
    private let monitor: @Sendable () -> NWPathMonitor

    init(monitor: @escaping @Sendable () -> NWPathMonitor = { NWPathMonitor(prohibitedInterfaceTypes: [.other, .loopback]) }) {
        self.monitor = monitor
    }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        guard let url = request.url, let host = url.host, !host.isEmpty, let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme), let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? (scheme == "https" ? 443 : 80))),
              let head = Self.head(request, url: url, host: host) else { throw ClientError.invalidResponse }
        guard let interface = await physicalInterface() else { throw ClientError.networkFailure(URLError.notConnectedToInternet.rawValue) }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 20
        var tls: NWProtocolTLS.Options?
        if scheme == "https" {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, "http/1.1")
            tls = options
        }
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.requiredInterface = interface
        parameters.preferNoProxies = true
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        let exchange = Exchange(connection)
        let timeout = Task {
            try await Task.sleep(for: .seconds(min(max(request.timeoutInterval, 1), 120)))
            exchange.expire()
        }
        defer { timeout.cancel(); connection.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try await exchange.ready()
                try await exchange.write(head + (request.httpBody ?? Data()))
                return try await Self.response(exchange, method: request.httpMethod ?? "GET")
            } onCancel: { connection.cancel() }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func physicalInterface() async -> NWInterface? {
        let monitor = monitor()
        defer { monitor.cancel() }
        let paths = AsyncStream<NWPath>.makeStream(bufferingPolicy: .bufferingNewest(1))
        monitor.pathUpdateHandler = { paths.continuation.yield($0) }
        monitor.start(queue: Self.queue)
        for await path in paths.stream { return path.status == .satisfied ? path.availableInterfaces.first : nil }
        return nil
    }

    private static func head(_ request: URLRequest, url: URL, host: String) -> Data? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let target = path + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        let authority = (host.contains(":") ? "[\(host)]" : host) + (url.port.map { ":\($0)" } ?? "")
        let method = request.httpMethod ?? "GET"
        var lines = ["\(method) \(target) HTTP/1.1", "Host: \(authority)", "Connection: close", "Accept-Encoding: identity"]
        let reserved: Set<String> = ["host", "connection", "content-length", "accept-encoding", "transfer-encoding"]
        for (name, value) in request.allHTTPHeaderFields ?? [:] where !reserved.contains(name.lowercased()) {
            lines.append("\(name): \(value)")
        }
        if let body = request.httpBody { lines.append("Content-Length: \(body.count)") }
        else if ["POST", "PUT", "PATCH"].contains(method) { lines.append("Content-Length: 0") }
        let text = lines.joined(separator: "\r\n") + "\r\n\r\n"
        guard !lines.dropFirst().contains(where: { $0.unicodeScalars.contains { $0 == "\r" || $0 == "\n" } }) else { return nil }
        return Data(text.utf8)
    }

    private static func response(_ exchange: Exchange, method: String) async throws -> HTTPResult {
        var buffer = Data()
        while true {
            var end = buffer.range(of: Data("\r\n\r\n".utf8))
            while end == nil {
                guard buffer.count <= 65536, let chunk = try await exchange.read() else { throw ClientError.invalidResponse }
                buffer.append(chunk)
                end = buffer.range(of: Data("\r\n\r\n".utf8))
            }
            let lines = String(decoding: buffer[..<end!.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let status = lines.first?.split(separator: " ", maxSplits: 2).dropFirst().first.flatMap { Int($0) }
            guard let status, lines.first?.hasPrefix("HTTP/1.") == true, (100...599).contains(status) else { throw ClientError.invalidResponse }
            buffer = Data(buffer[end!.upperBound...])
            if (100...199).contains(status) { continue }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard (headers["content-encoding"] ?? "identity").lowercased() == "identity" else { throw ClientError.invalidResponse }
            let retryAfter = headers["retry-after"].flatMap(Int.init)
            if method == "HEAD" || status == 204 || status == 304 { return HTTPResult(data: Data(), status: status, retryAfter: retryAfter) }
            let maximum = URLSessionTransport.maximumResponseBytes
            let chunked = headers["transfer-encoding"]?.lowercased().contains("chunked") == true
            let length = chunked ? nil : headers["content-length"].flatMap(Int.init)
            if let length, length > maximum { throw ClientError.responseTooLarge }
            while length.map({ buffer.count < $0 }) ?? true, let chunk = try await exchange.read() {
                buffer.append(chunk)
                guard buffer.count <= maximum + (chunked ? 65536 : 0) else { throw ClientError.responseTooLarge }
            }
            if let length {
                guard buffer.count >= length else { throw ClientError.networkFailure(URLError.networkConnectionLost.rawValue) }
                return HTTPResult(data: Data(buffer.prefix(length)), status: status, retryAfter: retryAfter)
            }
            return HTTPResult(data: chunked ? try dechunk(buffer) : buffer, status: status, retryAfter: retryAfter)
        }
    }

    private static func dechunk(_ data: Data) throws -> Data {
        var output = Data()
        var index = data.startIndex
        while true {
            guard let line = data[index...].range(of: crlf),
                  let size = Int(String(decoding: data[index..<line.lowerBound], as: UTF8.self)
                    .split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? "", radix: 16), size >= 0 else {
                throw ClientError.networkFailure(URLError.networkConnectionLost.rawValue)
            }
            index = line.upperBound
            if size == 0 { return output }
            guard data.distance(from: index, to: data.endIndex) >= size + 2 else {
                throw ClientError.networkFailure(URLError.networkConnectionLost.rawValue)
            }
            output.append(data[index..<data.index(index, offsetBy: size)])
            guard output.count <= URLSessionTransport.maximumResponseBytes else { throw ClientError.responseTooLarge }
            index = data.index(index, offsetBy: size + 2)
        }
    }

    // 连接建立前的失败映射为 URLSession 对应的连不上错误码，供 PanelAPI 判断能否重试或改走代理
    private final class Exchange: @unchecked Sendable {
        private let connection: NWConnection
        private let lock = NSLock()
        private var expired = false
        private var established = false
        private var started = false

        init(_ connection: NWConnection) { self.connection = connection }

        func expire() {
            lock.lock(); expired = true; lock.unlock()
            connection.cancel()
        }

        func ready() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.stateUpdateHandler = { [self] state in
                    let result: Result<Void, any Error>
                    switch state {
                    case .ready: result = .success(())
                    case .waiting(let error), .failed(let error): result = .failure(Self.connectError(error))
                    case .cancelled: result = .failure(failure())
                    default: return
                    }
                    lock.lock()
                    let first = !started
                    started = true
                    if first, case .success = result { established = true }
                    lock.unlock()
                    guard first else { return }
                    continuation.resume(with: result)
                    if case .failure = result { connection.cancel() }
                }
                connection.start(queue: PhysicalInterfaceTransport.queue)
            }
        }

        func write(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: data, completion: .contentProcessed { [self] error in
                    if error != nil { continuation.resume(throwing: failure()) } else { continuation.resume() }
                })
            }
        }

        func read() async throws -> Data? {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
                    if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if complete { continuation.resume(returning: nil) }
                    else if error != nil { continuation.resume(throwing: failure()) }
                    else { continuation.resume(returning: nil) }
                }
            }
        }

        private func failure() -> any Error {
            lock.lock(); defer { lock.unlock() }
            return ClientError.networkFailure((expired && established ? URLError.timedOut
                : established ? URLError.networkConnectionLost : URLError.cannotConnectToHost).rawValue)
        }

        private static func connectError(_ error: NWError) -> ClientError {
            switch error {
            case .dns: .networkFailure(URLError.cannotFindHost.rawValue)
            case .tls: .networkFailure(URLError.secureConnectionFailed.rawValue)
            case .posix(let code) where code == .ENETDOWN || code == .ENETUNREACH: .networkFailure(URLError.notConnectedToInternet.rawValue)
            default: .networkFailure(URLError.cannotConnectToHost.rawValue)
            }
        }
    }
}