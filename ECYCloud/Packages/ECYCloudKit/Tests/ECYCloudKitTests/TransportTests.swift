import Foundation
import Testing
@testable import ECYCloudKit

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url!.path
        if path == "/wait" { return }
        if path == "/dns" || path == "/timeout" || path == "/tls" {
            let code: URLError.Code = path == "/dns" ? .cannotFindHost : (path == "/timeout" ? .timedOut : .serverCertificateUntrusted)
            client?.urlProtocol(self, didFailWithError: URLError(code, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://secret.example.test/?token=must-not-appear"]))
            return
        }
        var headers = ["Content-Type": "application/json"]
        if path == "/length" { headers["Content-Length"] = "\(URLSessionTransport.maximumResponseBytes + 1)" }
        if path == "/redirect" {
            let target = URL(string: "https://other.example.test/must-not-receive-credentials")!
            let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if path == "/must-not-receive-credentials" { Issue.record("跨域重定向未被拒绝") }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "/chunks" {
            let chunk = Data(repeating: 32, count: 1024 * 1024)
            for _ in 0..<9 { client?.urlProtocol(self, didLoad: chunk) }
        } else {
            client?.urlProtocol(self, didLoad: Data(#"{"ret":1}"#.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("HTTP 传输边界", .timeLimit(.minutes(1)))
struct TransportTests {
    private func transport() -> URLSessionTransport {
        URLSessionTransport {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubProtocol.self]
            return configuration
        }
    }

    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://transport.example.test\(path)")!)
        request.setValue("Bearer synthetic-token", forHTTPHeaderField: "Authorization")
        return request
    }

    @Test func receivesBoundedBody() async throws {
        let result = try await transport().send(request("/ok"))
        #expect(result.status == 200 && result.data == Data(#"{"ret":1}"#.utf8))
    }

    @Test(arguments: [("/dns", -1003), ("/timeout", -1001), ("/tls", -1202)])
    func preservesNetworkErrorCodeWithoutLeakingURL(path: String, code: Int) async {
        await #expect(throws: ClientError.networkFailure(code)) { try await transport().send(request(path)) }
        let message = ClientError.networkFailure(code).localizedDescription
        #expect(message.contains(String(code)))
        #expect(!message.contains("secret.example.test") && !message.contains("must-not-appear"))
    }

    @Test(arguments: ["/length", "/chunks"])
    func rejectsOversizedResponses(path: String) async {
        await #expect(throws: ClientError.responseTooLarge) { try await transport().send(request(path)) }
    }

    @Test func rejectsCrossOriginRedirectBeforeSendingCredentials() async throws {
        let response = try await transport().send(request("/redirect"))
        #expect(response.status == 307)
    }

    @Test func cancellationTerminatesWaitingRequest() async {
        let transport = transport()
        let request = request("/wait")
        let task = Task { try await transport.send(request) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
