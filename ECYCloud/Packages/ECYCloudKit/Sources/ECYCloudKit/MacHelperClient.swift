#if os(macOS)
import Foundation
import Darwin

@MainActor protocol MacHelperTransport {
    func request(_ command: String, payload: [String: Any]) async throws -> [String: Any]
}

@MainActor final class MacHelperClient: MacHelperTransport {
    private let queue = DispatchQueue(label: "com.ecycloud.client.helper")
    func request(_ command: String, payload: [String: Any] = [:]) async throws -> [String: Any] {
        var value = payload
        value["command"] = command
        let data = try JSONSerialization.data(withJSONObject: value) + Data([10])
        guard data.count <= 4 * 1024 * 1024 else { throw TunnelError.configuration }
        let response: Data = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try Self.transact(data)) }
                catch { continuation.resume(throwing: error) }
            }
        }
        guard let result = try JSONSerialization.jsonObject(with: response) as? [String: Any], result["ok"] as? Bool == true else {
            throw TunnelError.control
        }
        return result["data"] as? [String: Any] ?? [:]
    }

    nonisolated private static func transact(_ data: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TunnelError.helperUnavailable }
        defer { Darwin.close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array("/var/run/ecycloud/helper.sock".utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw TunnelError.helperUnavailable }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else { throw TunnelError.helperUnavailable }
        return try MacSocket.exchange(fd: fd, data: data, maximum: 8 * 1024 * 1024, timeout: .seconds(40))
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
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0 else { throw TunnelError.helperUnavailable }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw TunnelError.helperUnavailable }
        let deadline = ContinuousClock.now + timeout
        func ready(_ event: Int16) throws {
            while true {
                try Task.checkCancellation()
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { throw TunnelError.helperUnavailable }
                let milliseconds = min(40_000, max(1, Int(remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000)))
                var descriptor = pollfd(fd: fd, events: event, revents: 0)
                let result = poll(&descriptor, 1, Int32(milliseconds))
                if result > 0 { return }
                if result < 0 && errno == EINTR { continue }
                throw TunnelError.helperUnavailable
            }
        }
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
