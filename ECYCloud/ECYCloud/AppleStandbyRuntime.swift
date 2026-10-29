#if os(iOS) || os(tvOS) || os(visionOS)
import Foundation
import ECYCloudKit
import ECYKernel

actor AppleStandbyRuntime: StandbyRuntime {
    private let group: String
    private var identifier: UInt64 = 0
    private var expiresAt: Date?
    private var directory: URL?
    private var lease: TunnelLease?

    init(applicationID: String) { group = "group." + applicationID }

    func start(_ lease: TunnelLease) throws {
        guard identifier == 0, lease.expiresAt > .now,
              !lease.configuration.isEmpty, lease.configuration.count <= 8 * 1024 * 1024 else { throw TunnelError.configuration }
        try Task.checkCancellation()
        let path = try TunnelFiles.runDirectory(group: group, lease: lease)
        directory = path; self.lease = lease
        // 空地址与 MTU 0 明确表示仅启用控制面，不创建包设备或系统路由。
        identifier = lease.configuration.withUnsafeBytes {
            ECYStart(UnsafeMutableRawPointer(mutating: $0.baseAddress), Int32($0.count), path.path, 0, "", "", "")
        }
        guard identifier != 0, lease.expiresAt > .now, !Task.isCancelled else {
            stop()
            throw TunnelError.start
        }
        expiresAt = lease.expiresAt
        TunnelFiles.keepCache(group: group, lease: lease, from: path)
        _ = try request(.init(.logging, group: lease.owner, level: lease.logLevel ?? "warning"))
    }

    func stop() {
        let started = identifier != 0
        if started { ECYStop(identifier) }
        identifier = 0; expiresAt = nil
        if let directory {
            if started, let lease { TunnelFiles.keepCache(group: group, lease: lease, from: directory) }
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil; lease = nil
    }

    func request(_ command: TunnelCommand) throws -> Data {
        guard identifier != 0, let expiresAt, expiresAt > .now else { throw TunnelError.expired }
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(command)
        guard data.count <= 4096 else { throw TunnelError.control }
        var response = [UInt8](repeating: 0, count: 65536)
        let count = data.withUnsafeBytes { input in
            response.withUnsafeMutableBytes { output in
                ECYControl(identifier, UnsafeMutableRawPointer(mutating: input.baseAddress), Int32(input.count), output.baseAddress, Int32(output.count))
            }
        }
        guard count > 0 else { throw TunnelError.control }
        return Data(response.prefix(Int(count)))
    }
}
#endif
