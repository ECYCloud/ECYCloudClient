import Foundation
import CryptoKit
import Network

public struct HTTPResult: Sendable {
    public let data: Data
    public let status: Int
    public let retryAfter: Int?

    public init(data: Data, status: Int, retryAfter: Int? = nil) {
        self.data = data
        self.status = status
        self.retryAfter = retryAfter
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResult
}

public struct URLSessionTransport: HTTPTransport {
    public static let maximumResponseBytes = 8 * 1024 * 1024
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration

    public init() { makeConfiguration = { .ephemeral } }

    init(configuration: @escaping @Sendable () -> URLSessionConfiguration) {
        makeConfiguration = configuration
    }

    public func send(_ request: URLRequest) async throws -> HTTPResult {
        let configuration = makeConfiguration()
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = min(max(request.timeoutInterval, 1), 120)
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirects())
            guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
            guard response.expectedContentLength <= Self.maximumResponseBytes else {
                throw ClientError.responseTooLarge
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.maximumResponseBytes else { throw ClientError.responseTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            return HTTPResult(
                data: data, status: http.statusCode,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ClientError {
            throw error
        } catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            throw ClientError.networkFailure(error.code.rawValue)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ClientError.network
        }
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// 对应 panel_api_client.dart 的 fallbackProxyPort：接管连接时由连接控制器给出状态与本地混合端口（仅 macOS 有）
@MainActor public final class PanelRoute {
    var connected: () -> Bool = { false }
    var proxyPort: () -> Int? = { nil }
    nonisolated init() {}
    func takeover() -> (connected: Bool, port: Int?) { (connected(), proxyPort()) }
}

public struct PanelAPI: Sendable {
    let transport: any HTTPTransport
    private let direct: any HTTPTransport
    private let proxyTransport: @Sendable (Int) -> any HTTPTransport
    private let device: DeviceInfo
    let route = PanelRoute()

    // 连接建立前即失败，服务端必然未收到，非幂等请求也可换走代理重发
    private static let connectFailures: Set<URLError.Code> = [
        .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed
    ]

    // 默认传输不读系统代理，避免接管系统代理后面板请求先绕进本机内核；接管期间改用绑定物理网卡的直连
    public init(device: DeviceInfo, transport: (any HTTPTransport)? = nil) {
        self.init(device: device, transport: transport ?? URLSessionTransport(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            return configuration
        }), direct: transport ?? PhysicalInterfaceTransport()) { port in
            URLSessionTransport(configuration: {
                let configuration = URLSessionConfiguration.ephemeral
                var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!))
                proxy.allowFailover = false
                configuration.proxyConfigurations = [proxy]
                return configuration
            })
        }
    }

    init(device: DeviceInfo, transport: any HTTPTransport, direct: (any HTTPTransport)? = nil,
         proxyTransport: @escaping @Sendable (Int) -> any HTTPTransport) {
        self.device = device
        self.transport = transport
        self.direct = direct ?? transport
        self.proxyTransport = proxyTransport
    }

    // 对应 panel_api_client.dart 的 cacheBinding：离线缓存只给同一站点、设备与登录令牌使用
    func cacheBinding(_ endpoints: PanelEndpoints, token: String) -> String {
        let value = try! JSONEncoder().encode([endpoints.site.absoluteString, endpoints.config.absoluteString, device.id, token])
        return SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }

    // 对应 panel_api_client.dart 的 _viaDirectThenProxy：连接未建立时短暂等待后整轮重来，最多 3 轮；
    // 账户状态不重试，启动恢复要尽快退回离线缓存
    private func send(_ request: URLRequest, retryUnreachable: Bool) async throws -> HTTPResult {
        var attempt = 1
        while true {
            do { return try await sendOnce(request) }
            catch ClientError.networkFailure(let code) where retryUnreachable && Self.connectFailures.contains(URLError.Code(rawValue: code)) {
                guard attempt < 3 else { throw ClientError.unreachable(code) }
                attempt += 1
                try await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    // 对应 panel_api_client.dart 的 _sendOnce：先直连；连不上且已接管连接时经内核重发，非幂等请求只在连接未建立时重发。
    // macOS 经本地混合端口；移动端没有监听端口，改用普通请求进入 VPN 隧道，由内核按规则转发
    private func sendOnce(_ request: URLRequest) async throws -> HTTPResult {
        let takeover = await route.takeover()
        do {
            return try await (takeover.connected ? direct : transport).send(request)
        } catch let error as ClientError {
            let repeatable = ["GET", "HEAD"].contains(request.httpMethod ?? "GET")
            let unreachable: Bool
            switch error {
            case .network: unreachable = repeatable
            case .networkFailure(let code): unreachable = repeatable || Self.connectFailures.contains(URLError.Code(rawValue: code))
            default: unreachable = false
            }
            guard unreachable, takeover.connected else { throw error }
            guard let port = takeover.port else { return try await transport.send(request) }
            guard (1...65535).contains(port) else { throw error }
            return try await proxyTransport(port).send(request)
        }
    }

    func options(_ endpoints: PanelEndpoints) async throws -> AuthOptions {
        do {
            return try await request("/auth/options", origin: endpoints.site)
        } catch ClientError.networkFailure(let code) where URLError.Code(rawValue: code) == .networkConnectionLost {
            try await Task.sleep(for: .seconds(1))
            return try await request("/auth/options", origin: endpoints.site)
        }
    }

    func login(
        _ endpoints: PanelEndpoints, email: String, password: String, code: String, emailCode: Bool
    ) async throws -> LoginResult {
        var body = deviceBody
        body["email"] = email
        if emailCode {
            body["code"] = code
        } else {
            body["passwd"] = password
            if !code.isEmpty { body["code"] = code }
        }
        return try await authenticate(emailCode ? "/auth/login-with-verify-code" : "/auth/login", endpoints: endpoints, body: body)
    }

    private var deviceBody: [String: String] {
        ["device_id": device.id, "device_name": device.name, "device_model": device.model,
         "os_version": device.os, "app_version": device.version]
    }

    func register(_ endpoints: PanelEndpoints, name: String, email: String, password: String,
                  confirmation: String, invite: String, emailCode: String) async throws -> LoginResult {
        var body = deviceBody
        body.merge(["name": name, "email": email, "passwd": password, "repasswd": confirmation,
                    "code": invite, "emailcode": emailCode]) { _, value in value }
        return try await authenticate("/auth/register", endpoints: endpoints, body: body)
    }

    func resetPassword(_ endpoints: PanelEndpoints, token: String, password: String, confirmation: String) async throws -> LoginResult {
        var body = deviceBody
        body.merge(["token": token, "password": password, "repasswd": confirmation]) { _, value in value }
        return try await authenticate("/auth/password-reset/confirm", endpoints: endpoints, body: body)
    }

    func requestEmail(_ endpoints: PanelEndpoints, purpose: EmailPurpose, email: String) async throws -> String {
        try await perform(purpose.path, origin: endpoints.site, body: ["email": email]).message
    }

    func document(_ endpoints: PanelEndpoints, kind: LegalDocumentKind) async throws -> RichDocument {
        struct Content: Decodable { let content: String }
        let value: Content = try await request(kind.path, origin: endpoints.site)
        return try RichDocument(html: value.content, origin: endpoints.site)
    }

    private func authenticate(_ path: String, endpoints: PanelEndpoints, body: [String: String]) async throws -> LoginResult {
        let response = try await perform(path, origin: endpoints.site, body: body)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard var result = try? decoder.decode(Envelope<LoginResult>.self, from: response.data).data,
              !result.token.isEmpty, result.token.utf8.count <= 4096,
              result.token.utf8.allSatisfy({ (33...126).contains($0) }),
              result.user != nil || result.accountStatus?.isNormal == false else {
            throw ClientError.invalidResponse
        }
        try result.user?.validate()
        result.message = response.message
        return result
    }

    func history(_ endpoints: PanelEndpoints, token: String, kind: AccountHistoryKind, page: Int, search: String) async throws -> AccountHistory {
        let query = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "length", value: "10"),
                     URLQueryItem(name: "search", value: search)]
        switch kind {
        case .purchases, .balance, .unlock:
            let result: BusinessHistoryPage = try await request(kind.path, origin: endpoints.site, token: token, query: query)
            return try result.history(kind: kind)
        case .devices:
            let result: HistoryPage<DeviceRecord> = try await request(kind.path, origin: endpoints.site, token: token, query: query)
            return try result.history { $0.row(currentID: device.id) }
        case .loginLogs:
            let result: HistoryPage<LoginRecord> = try await request(kind.path, origin: endpoints.site, token: token, query: query)
            return try result.history { $0.row }
        case .operationLogs:
            let result: HistoryPage<OperationRecord> = try await request(kind.path, origin: endpoints.site, token: token, query: query)
            return try result.history { $0.row }
        }
    }

    func updateUsername(_ endpoints: PanelEndpoints, token: String, name: String) async throws -> String {
        try await perform("/user/username", origin: endpoints.site, token: token, body: ["newusername": name]).message
    }

    func updatePassword(_ endpoints: PanelEndpoints, token: String, old: String, password: String, confirmation: String) async throws -> String {
        try await perform("/user/password", origin: endpoints.site, token: token, body: ["oldpwd": old, "pwd": password, "repwd": confirmation]).message
    }

    func kickDevice(_ endpoints: PanelEndpoints, token: String, deviceID: String) async throws -> String {
        try await perform("/user/kick-device", origin: endpoints.site, token: token, body: ["device_id": deviceID]).message
    }

    func profile(_ endpoints: PanelEndpoints, token: String, connected: Bool = false) async throws -> UserProfile {
        try await profileResponse(endpoints, token: token, connected: connected).value
    }

    func profileResponse(_ endpoints: PanelEndpoints, token: String, connected: Bool = false) async throws -> (value: UserProfile, data: Data) {
        let data = try await perform("/user/profile", origin: endpoints.site, token: token, connected: connected).data
        let result: UserProfile = try Self.decode(data)
        try result.validate()
        return (result, data)
    }

    func accountStatus(_ endpoints: PanelEndpoints, token: String) async throws -> AccountStatus {
        try await request("/user/account-status", origin: endpoints.site, token: token)
    }

    func nodes(_ endpoints: PanelEndpoints, token: String) async throws -> (value: NodeCatalog, data: Data) {
        let data = try await perform("/config/clash", origin: endpoints.config, token: token, nodeProviders: true).data
        return (try Self.decode(data), data)
    }

    func logout(_ endpoints: PanelEndpoints, token: String) async throws {
        _ = try await perform("/auth/logout", origin: endpoints.site, token: token, body: [:])
    }

    private struct EnvelopeHeader: Decodable {
        let ret: Int
        let msg: String?
    }

    private struct Envelope<Value: Decodable>: Decodable { let data: Value }

    func request<Value: Decodable>(
        _ path: String, origin: URL, token: String? = nil,
        body: [String: String]? = nil, nodeProviders: Bool = false, query: [URLQueryItem] = [], method: String? = nil, jsonBody: Data? = nil, contentType: String = "application/json; charset=utf-8", timeout: TimeInterval = 20, connected: Bool = false
    ) async throws -> Value {
        let result = try await perform(path, origin: origin, token: token, body: body, nodeProviders: nodeProviders, query: query, method: method, jsonBody: jsonBody, contentType: contentType, timeout: timeout, connected: connected)
        return try Self.decode(result.data)
    }

    static func decode<Value: Decodable>(_ data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Envelope<Value>.self, from: data).data
        } catch {
            throw ClientError.invalidResponse
        }
    }

    func perform(
        _ path: String, origin: URL, token: String? = nil,
        body: [String: String]? = nil, nodeProviders: Bool = false, query: [URLQueryItem] = [], method: String? = nil, jsonBody: Data? = nil, contentType: String = "application/json; charset=utf-8", timeout: TimeInterval = 20, connected: Bool = false
    ) async throws -> (data: Data, message: String) {
        var url = URLComponents(url: origin.appendingPathComponent("api/client/v1\(path)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { url.queryItems = query }
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = min(max(timeout, 1), 120)
        request.httpMethod = method ?? (body == nil && jsonBody == nil ? "GET" : "POST")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(L10n.language.rawValue, forHTTPHeaderField: "Accept-Language")
        let version = device.version.replacingOccurrences(of: "Pre ", with: "Pre")
        request.setValue("ECYCloud/\(version) (\(device.platform))", forHTTPHeaderField: "User-Agent")
        let componentCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()")
        for (key, value) in [
            "X-Device-Name": device.name, "X-Device-Model": device.model,
            "X-Device-OS": device.os, "X-App-Version": device.version
        ] {
            request.setValue(value.addingPercentEncoding(withAllowedCharacters: componentCharacters), forHTTPHeaderField: key)
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if connected && token != nil {
            request.setValue("1", forHTTPHeaderField: "X-ECY-Connected")
            request.setValue("1", forHTTPHeaderField: "X-ECY-Node-Used")
        }
        if nodeProviders { request.setValue("1", forHTTPHeaderField: "X-ECY-Node-Providers") }
        if body != nil || jsonBody != nil {
            request.httpBody = try jsonBody ?? JSONEncoder().encode(body!)
            guard request.httpBody!.count <= (path == "/tickets/upload" && contentType.hasPrefix("multipart/form-data;") ? TicketUpload.maximumBytes + 4096 : 1_048_576) else { throw ClientError.responseTooLarge }
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let response = try await send(request, retryUnreachable: path != "/user/account-status")
        guard response.data.count <= URLSessionTransport.maximumResponseBytes else { throw ClientError.responseTooLarge }
        let header = try? JSONDecoder().decode(EnvelopeHeader.self, from: response.data)
        if (200..<300).contains(response.status), header == nil { throw ClientError.invalidResponse }
        var message = header?.msg ?? L10n.t("请求失败（HTTP {0}）", [String(describing: response.status)])
        let sensitiveKeys = ["passwd", "password", "repasswd", "code", "emailcode", "email_code", "token", "oldpasswd", "newpasswd", "oldpwd", "pwd", "repwd", "old_emailcode", "new_emailcode", "ga_token", "bind_token"]
        for secret in ([token] + sensitiveKeys.map { body?[$0] }).compactMap({ $0 }) where !secret.isEmpty {
            message = message.replacingOccurrences(of: secret, with: L10n.t("[已隐藏]"))
        }
        message = String(message.prefix(512))
        message = L10n.message(message)
        guard (200..<300).contains(response.status), header?.ret == 1 else {
            throw ClientError.server(
                status: response.status, code: header?.ret ?? 0, message: message,
                retryAfter: response.status == 429 ? response.retryAfter.flatMap { $0 > 0 ? $0 : nil } : nil
            )
        }
        return (response.data, header?.msg == nil ? "" : message)
    }
}
