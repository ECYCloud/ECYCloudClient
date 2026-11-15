#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import ECYCloudKit

@Suite("macOS helper 握手")
struct MacHelperHandshakeTests {
    private static func pair() throws -> (client: Int32, helper: Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw TunnelError.helperUnavailable }
        return (fds[0], fds[1])
    }

    private static func pending(_ fd: Int32, milliseconds: Int32) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, milliseconds) > 0
    }

    private static func readLine(_ fd: Int32) -> Data {
        var line = Data(), byte: UInt8 = 0
        while Darwin.read(fd, &byte, 1) == 1, byte != 10 { line.append(byte) }
        return line
    }

    private static func write(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    // helper 读完请求要复核对端并核对随机数：客户端必须等到握手后才写，且请求里带回本次随机数
    @Test func requestIsWrittenOnlyAfterGreetingAndCarriesNonce() async throws {
        let (client, helper) = try Self.pair()
        defer { Darwin.close(helper) }
        let payload = try JSONSerialization.data(withJSONObject: ["command": "kernel.start", "config": "x"])
        let conversation = Task.detached { () throws -> Data in
            defer { Darwin.close(client) }
            return try MacHelperClient.converse(fd: client, payload: payload, greetingTimeout: .seconds(5))
        }
        #expect(!Self.pending(helper, milliseconds: 300), "握手前预写了请求")
        Self.write(helper, #"{"ok":false,"error":"后台服务已更新，请重新打开客户端","data":{"nonce":"nonce-42"}}"# + "\n")
        let request = try #require(try JSONSerialization.jsonObject(with: Self.readLine(helper)) as? [String: Any])
        #expect(request["nonce"] as? String == "nonce-42")
        #expect(request["command"] as? String == "kernel.start")
        #expect(request["config"] as? String == "x")
        Self.write(helper, #"{"ok":true,"data":{"version":"1"}}"# + "\n")
        Darwin.shutdown(helper, SHUT_WR)
        let response = try #require(try JSONSerialization.jsonObject(with: try await conversation.value) as? [String: Any])
        #expect(response["ok"] as? Bool == true)
    }

    // 旧版 helper 不发握手而是等请求：客户端不能干等到它超时，也不能先把请求写过去
    @Test func helperWithoutGreetingIsReportedAsOutdated() async throws {
        let (client, helper) = try Self.pair()
        defer { Darwin.close(helper) }
        let payload = try JSONSerialization.data(withJSONObject: ["command": "ping"])
        await #expect(throws: TunnelError.helperUnavailable) {
            try await Task.detached {
                defer { Darwin.close(client) }
                return try MacHelperClient.converse(fd: client, payload: payload, greetingTimeout: .milliseconds(300))
            }.value
        }
        #expect(!Self.pending(helper, milliseconds: 0) || Self.readLine(helper).isEmpty, "未收到握手却写出了请求")
    }

    @Test func greetingWithoutNonceIsRejectedBeforeWriting() async throws {
        let (client, helper) = try Self.pair()
        defer { Darwin.close(helper) }
        let payload = try JSONSerialization.data(withJSONObject: ["command": "ping"])
        Self.write(helper, #"{"ok":false,"error":"拒绝"}"# + "\n")
        await #expect(throws: TunnelError.helperUnavailable) {
            try await Task.detached {
                defer { Darwin.close(client) }
                return try MacHelperClient.converse(fd: client, payload: payload, greetingTimeout: .seconds(2))
            }.value
        }
        #expect(Self.readLine(helper).isEmpty, "握手不含随机数仍写出了请求")
    }
}
#endif
