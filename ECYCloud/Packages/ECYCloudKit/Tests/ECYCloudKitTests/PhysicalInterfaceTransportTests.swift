import Foundation
import Network
import Testing
@testable import ECYCloudKit

// 本机回环服务器按顺序回放合成响应，并记录收到的请求原文
private final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var replies: [Data]
    private(set) var requests: [String] = []

    init(_ replies: [String]) throws {
        self.replies = replies.map { Data($0.utf8) }
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: .global())
            receive(connection, Data())
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, _, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard error == nil, let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if error == nil { receive(connection, buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let length = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            guard buffer.count - end.upperBound >= length else { receive(connection, buffer); return }
            lock.lock()
            requests.append(String(decoding: buffer, as: UTF8.self))
            let reply = replies.isEmpty ? Data() : replies.removeFirst()
            lock.unlock()
            connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@Suite("绑定物理网卡的面板直连", .timeLimit(.minutes(1)))
struct PhysicalInterfaceTransportTests {
    @Test func parsesLengthChunkedAndInformationalResponses() async throws {
        let server = try LoopbackServer([
            "HTTP/1.1 200 OK\r\nContent-Length: 11\r\nRetry-After: 9\r\n\r\n{\"ret\":1}  ",
            "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 429 Too Many Requests\r\nTransfer-Encoding: chunked\r\n\r\n4;x=y\r\n{\"re\r\n5\r\nt\":0}\r\n0\r\n\r\n",
            "HTTP/1.1 204 No Content\r\n\r\n",
            "HTTP/1.1 200 OK\r\n\r\nuntil-close"
        ])
        defer { server.stop() }
        let port = try await server.start()
        let transport = PhysicalInterfaceTransport { NWPathMonitor(requiredInterfaceType: .loopback) }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/client/v1/tickets?page=2&q=a%20b")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{\"a\":1}".utf8)
        request.setValue("Bearer synthetic", forHTTPHeaderField: "Authorization")
        let first = try await transport.send(request)
        #expect(first.status == 200 && first.data == Data("{\"ret\":1}  ".utf8) && first.retryAfter == 9)
        let second = try await transport.send(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/x")!))
        #expect(second.status == 429 && second.data == Data("{\"ret\":0}".utf8))
        let third = try await transport.send(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
        #expect(third.status == 204 && third.data.isEmpty)
        let fourth = try await transport.send(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
        #expect(fourth.data == Data("until-close".utf8))
        let sent = try #require(server.requests.first)
        #expect(sent.hasPrefix("POST /api/client/v1/tickets?page=2&q=a%20b HTTP/1.1\r\n"))
        #expect(sent.contains("\r\nHost: 127.0.0.1:\(port)\r\n") && sent.contains("\r\nContent-Length: 7\r\n"))
        #expect(sent.contains("\r\nAuthorization: Bearer synthetic\r\n") && sent.hasSuffix("\r\n\r\n{\"a\":1}"))
    }

    @Test func rejectsOversizedAndRefusedConnections() async throws {
        let server = try LoopbackServer(["HTTP/1.1 200 OK\r\nContent-Length: \(URLSessionTransport.maximumResponseBytes + 1)\r\n\r\n"])
        let port = try await server.start()
        let transport = PhysicalInterfaceTransport { NWPathMonitor(requiredInterfaceType: .loopback) }
        await #expect(throws: ClientError.responseTooLarge) {
            _ = try await transport.send(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
        }
        server.stop()
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: ClientError.networkFailure(URLError.cannotConnectToHost.rawValue)) {
            _ = try await transport.send(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
        }
        var injected = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        injected.setValue("1", forHTTPHeaderField: "X-Test\r\nX-Injected")
        await #expect(throws: ClientError.invalidResponse) { _ = try await transport.send(injected) }
    }
}