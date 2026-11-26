#if os(macOS)
import Foundation
import Darwin

@MainActor protocol MacHelperTransport {
    func request(_ command: String, payload: [String: Any], timeout: Duration) async throws -> [String: Any]
}

extension MacHelperTransport {
    func request(_ command: String, payload: [String: Any]) async throws -> [String: Any] {
        try await request(command, payload: payload, timeout: .seconds(40))
    }
}

@MainActor final class MacHelperClient: MacHelperTransport {
    private let queue = DispatchQueue(label: "com.ecycloud.client.helper", attributes: .concurrent)
    private let socketPath: String
    private let restartWindow: Duration
    init(socketPath: String = "/var/run/ecycloud/helper.sock", restartWindow: Duration = .seconds(3)) {
        self.socketPath = socketPath; self.restartWindow = restartWindow
    }
    private struct Unreachable: Error {}
    func request(_ command: String, payload: [String: Any] = [:], timeout: Duration = .seconds(40)) async throws -> [String: Any] {
        var value = payload
        value["command"] = command
        let data = try JSONSerialization.data(withJSONObject: value)
        let path = socketPath
        func send() async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do { continuation.resume(returning: try Self.transact(data, path: path, timeout: timeout)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }
        // 与 helper_client.dart 一致：helper 被 launchd 重新拉起的几秒内连不上，等一会儿再试一次
        let response: Data
        do { response = try await send() }
        catch is Unreachable {
            try await Task.sleep(for: restartWindow)
            do { response = try await send() } catch is Unreachable { throw TunnelError.helperUnavailable }
        }
        guard let result = try JSONSerialization.jsonObject(with: response) as? [String: Any] else { throw TunnelError.control }
        guard result["ok"] as? Bool == true else {
            throw TunnelError.failed(L10n.message((result["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "后台服务处理失败"))
        }
        return result["data"] as? [String: Any] ?? [:]
    }

    nonisolated private static func transact(_ data: Data, path socketPath: String, timeout: Duration) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TunnelError.helperUnavailable }
        defer { Darwin.close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw Unreachable() }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else { throw TunnelError.helperUnavailable }
        return try converse(fd: fd, payload: data, greetingTimeout: min(.seconds(5), timeout), timeout: timeout)
    }

    // helper 只受理握手之后由同一进程写出、带本次随机数的请求，不能在读到握手前预写。
    // 握手时限须短于 helper 读请求的 10 秒：旧版 helper 不发握手，只会干等请求。
    nonisolated static func converse(fd: Int32, payload: Data, greetingTimeout: Duration, timeout: Duration = .seconds(40)) throws -> Data {
        let deadline = ContinuousClock.now + timeout
        let greeting = try MacSocket.readLine(fd: fd, maximum: 64 * 1024, timeout: greetingTimeout)
        guard let challenge = try? JSONSerialization.jsonObject(with: greeting) as? [String: Any] else { throw TunnelError.helperUnavailable }
        guard let nonce = (challenge["data"] as? [String: Any])?["nonce"] as? String,
              var request = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            // helper 在应答前已拒绝本进程（身份或签名校验未通过），握手行里只有原因：照实提示，不当作没装
            if let error = challenge["error"] as? String, !error.isEmpty { throw TunnelError.failed(L10n.message(error)) }
            throw TunnelError.helperUnavailable
        }
        request["nonce"] = nonce
        let data = try JSONSerialization.data(withJSONObject: request) + Data([10])
        guard data.count <= 4 * 1024 * 1024 else { throw TunnelError.configuration }
        return try MacSocket.exchange(fd: fd, data: data, maximum: 8 * 1024 * 1024, timeout: ContinuousClock.now.duration(to: deadline))
    }
}

enum MacSocket {
    static func forwardProbe(port: Int, controller: Int, credential: String) async throws -> Int {
        let task = Task.detached {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw TunnelError.start }
            defer { Darwin.close(fd) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard connected == 0 else { throw TunnelError.start }
            let authorization = Data(credential.utf8).base64EncodedString()
            let message = "GET http://127.0.0.1:\(controller)/version HTTP/1.1\r\nHost: 127.0.0.1:\(controller)\r\nProxy-Authorization: Basic \(authorization)\r\nConnection: close\r\n\r\n"
            let response = try exchange(fd: fd, data: Data(message.utf8), maximum: 4096, timeout: .seconds(2))
            guard let first = String(data: response, encoding: .utf8)?.components(separatedBy: "\r\n").first,
                  let status = first.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { throw TunnelError.start }
            return status
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    static func exchange(fd: Int32, data: Data, maximum: Int, timeout: Duration) throws -> Data {
        try configure(fd)
        let deadline = ContinuousClock.now + timeout
        func ready(_ event: Int16) throws { try wait(fd: fd, event: event, deadline: deadline) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try ready(Int16(POLLOUT))
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
                guard count > 0 else { throw TunnelError.helperUnavailable }
                offset += count
            }
        }
        var output = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            try ready(Int16(POLLIN))
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count == 0 { break }
            if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard count > 0, output.count + count <= maximum else { throw TunnelError.control }
            output.append(contentsOf: buffer.prefix(count))
        }
        guard !output.isEmpty else { throw TunnelError.control }
        return output
    }

    static func readLine(fd: Int32, maximum: Int, timeout: Duration) throws -> Data {
        try configure(fd)
        let deadline = ContinuousClock.now + timeout
        var line = Data(), byte: UInt8 = 0
        while true {
            try wait(fd: fd, event: Int16(POLLIN), deadline: deadline)
            let count = Darwin.recv(fd, &byte, 1, 0)
            if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard count == 1 else { throw TunnelError.helperUnavailable }
            if byte == 10 { return line }
            guard line.count < maximum else { throw TunnelError.control }
            line.append(byte)
        }
    }

    private static func configure(_ fd: Int32) throws {
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0 else { throw TunnelError.helperUnavailable }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw TunnelError.helperUnavailable }
    }

    private static func wait(fd: Int32, event: Int16, deadline: ContinuousClock.Instant) throws {
        while true {
            try Task.checkCancellation()
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw TunnelError.helperTimeout }
            let milliseconds = min(40_000, max(1, Int(remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000)))
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let result = poll(&descriptor, 1, Int32(milliseconds))
            if result > 0 { return }
            if result < 0 && errno == EINTR { continue }
            throw result == 0 ? TunnelError.helperTimeout : TunnelError.helperUnavailable
        }
    }
}

enum MacPorts {
    static func allocate(mixed preferred: Int? = nil) throws -> (mixed: Int, controller: Int) {
        func bindPort(_ port: Int = 0) throws -> (Int32, Int) {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw TunnelError.start }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            guard bound == 0, named == 0 else { Darwin.close(fd); throw TunnelError.start }
            return (fd, Int(UInt16(bigEndian: address.sin_port)))
        }
        if let preferred {
            for _ in 0..<20 {
                let (fd, controller) = try bindPort()
                Darwin.close(fd)
                if controller != preferred, controller != (preferred < 65535 ? preferred + 1 : preferred - 1) {
                    return (preferred, controller)
                }
            }
            throw TunnelError.start
        }
        for _ in 0..<20 {
            let (mixedFD, mixed) = try bindPort()
            defer { Darwin.close(mixedFD) }
            guard let (probeFD, _) = try? bindPort(mixed < 65535 ? mixed + 1 : mixed - 1) else { continue }
            defer { Darwin.close(probeFD) }
            let (controllerFD, controller) = try bindPort()
            Darwin.close(controllerFD)
            return (mixed, controller)
        }
        throw TunnelError.start
    }
}
#endif
