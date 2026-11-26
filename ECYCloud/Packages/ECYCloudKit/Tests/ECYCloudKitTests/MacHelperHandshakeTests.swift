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

    // 旧版 helper 不发握手而是等请求：客户端不能干等到它超时，也不能先把请求写过去；与 helper_client.dart 一样报响应超时
    @Test func helperWithoutGreetingIsReportedAsOutdated() async throws {
        let (client, helper) = try Self.pair()
        defer { Darwin.close(helper) }
        let payload = try JSONSerialization.data(withJSONObject: ["command": "ping"])
        await #expect(throws: TunnelError.helperTimeout) {
            try await Task.detached {
                defer { Darwin.close(client) }
                return try MacHelperClient.converse(fd: client, payload: payload, greetingTimeout: .milliseconds(300))
            }.value
        }
        #expect(!Self.pending(helper, milliseconds: 0) || Self.readLine(helper).isEmpty, "未收到握手却写出了请求")
    }

    // helper 握手后卡在处理上：整次请求按调用方给的时限结束，不能固定等满 40 秒
    @Test func silentHelperAfterGreetingTimesOutWithinRequestedTimeout() async throws {
        let (client, helper) = try Self.pair()
        defer { Darwin.close(helper) }
        let payload = try JSONSerialization.data(withJSONObject: ["command": "kernel.stop"])
        Self.write(helper, #"{"ok":false,"error":"后台服务已更新，请重新打开客户端","data":{"nonce":"nonce-7"}}"# + "\n")
        let started = ContinuousClock.now
        await #expect(throws: TunnelError.helperTimeout) {
            try await Task.detached {
                defer { Darwin.close(client) }
                return try MacHelperClient.converse(fd: client, payload: payload, greetingTimeout: .seconds(5), timeout: .milliseconds(500))
            }.value
        }
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(TunnelError.helperTimeout.localizedDescription == L10n.t("后台服务响应超时"))
    }

    @Test func greetingWithoutNonceIsRejectedBeforeWriting() async throws {
        let (client, helper) = try Self.pair()
        defer { Darwin.close(helper) }
        let payload = try JSONSerialization.data(withJSONObject: ["command": "ping"])
        Self.write(helper, #"{"ok":false,"error":"拒绝"}"# + "\n")
        await #expect(throws: TunnelError.failed(L10n.message("拒绝"))) {
            try await Task.detached {
                defer { Darwin.close(client) }
                return try MacHelperClient.converse(fd: client, payload: payload, greetingTimeout: .seconds(2))
            }.value
        }
        #expect(Self.readLine(helper).isEmpty, "握手不含随机数仍写出了请求")
    }

    // helper 可达但拒绝了本进程（如覆盖安装后仍在运行的旧进程）：提示 helper 给出的原因，不说成后台服务没装
    @Test func rejectedCallerIsNotReportedAsMissingHelper() async throws {
        let (client, helper) = try Self.pair()
        defer { Darwin.close(helper) }
        let payload = try JSONSerialization.data(withJSONObject: ["command": "ping"])
        let reason = "拒绝来自非官方客户端的指令: /Users/synthetic/ECYCloud.app/Contents/MacOS/ECYCloud"
        Self.write(helper, #"{"ok":false,"error":"\#(reason)"}"# + "\n")
        let error = await #expect(throws: TunnelError.self) {
            try await Task.detached {
                defer { Darwin.close(client) }
                return try MacHelperClient.converse(fd: client, payload: payload, greetingTimeout: .seconds(2))
            }.value
        }
        #expect(error == .failed(L10n.message(reason)) && error != .helperUnavailable)
    }

    // 与 helper_client.dart 一致：连不上时等 helper 被重新拉起再试一次，第二次才按不可用处理
    @Test @MainActor func unreachableHelperIsRetriedOnceAfterRestartWindow() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID().uuidString.prefix(8)).sock").path
        defer { unlink(path) }
        let client = MacHelperClient(socketPath: path, restartWindow: .milliseconds(600))
        let started = ContinuousClock.now
        let request = Task { _ = try await client.request("ping") }
        try await Task.sleep(for: .milliseconds(200))
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(server) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in Array(path.utf8CString).withUnsafeBytes { destination.copyBytes(from: $0) } }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        #expect(bound == 0 && listen(server, 1) == 0)
        await #expect(throws: TunnelError.helperUnavailable) { try await request.value }
        #expect(ContinuousClock.now - started >= .milliseconds(600))
        #expect(Self.pending(server, milliseconds: 0), "第二次没有连到重新出现的 helper")
    }
}
#endif
