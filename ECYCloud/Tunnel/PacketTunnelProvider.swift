import Foundation
import NetworkExtension
import ECYCloudKit
import ECYKernel

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let control = DispatchQueue(label: "com.ecycloud.tunnel.control")
    private let output = DispatchQueue(label: "com.ecycloud.tunnel.output")
    private let lock = NSLock()
    private var activeID: UInt64 = 0
    private var expiration: DispatchWorkItem?
    private var leaseID: UUID?
    private var runDirectory: URL?
    private var runLease: TunnelLease?
    private var pendingStart: ((Error?) -> Void)?
    private var group: String { Bundle.main.object(forInfoDictionaryKey: "ECYAppGroup") as! String }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        control.async { [self] in
            guard pendingStart == nil, currentID == 0 else { completionHandler(TunnelError.start); return }
            pendingStart = completionHandler
            do {
                guard let protocolValue = protocolConfiguration as? NETunnelProviderProtocol,
                      let owner = protocolValue.providerConfiguration?["owner"] as? String,
                      let identifier = protocolValue.providerConfiguration?["leaseID"] as? String,
                      let identifier = UUID(uuidString: identifier) else { throw TunnelError.configuration }
                leaseID = identifier
                let lease = try TunnelFiles.load(group: group, owner: owner, id: identifier)
                let directory = try TunnelFiles.runDirectory(group: group, lease: lease)
                runDirectory = directory; runLease = lease
                let id = lease.configuration.withUnsafeBytes { buffer in
                    ECYStart(UnsafeMutableRawPointer(mutating: buffer.baseAddress), Int32(buffer.count), directory.path, 1500, "172.19.0.1/30", "fdfe:dcba:9876::1/126", "172.19.0.2:53")
                }
                guard id != 0 else { throw TunnelError.configuration }
                setID(id)
                TunnelFiles.keepCache(group: group, lease: lease, from: directory)
                let logging = try JSONEncoder().encode(TunnelCommand(.logging, group: lease.owner, level: lease.logLevel ?? "warning"))
                var loggingResponse = [UInt8](repeating: 0, count: 128)
                let loggingCount = logging.withUnsafeBytes { input in
                    loggingResponse.withUnsafeMutableBytes { output in
                        ECYControl(id, UnsafeMutableRawPointer(mutating: input.baseAddress), Int32(input.count), output.baseAddress, Int32(output.count))
                    }
                }
                guard loggingCount > 0 else { throw TunnelError.configuration }
                let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "172.19.0.1")
                settings.mtu = 1500
                let ipv4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.252"])
                ipv4.includedRoutes = [.default(), NEIPv4Route(destinationAddress: "172.19.0.2", subnetMask: "255.255.255.255")]
                let configuration = try JSONSerialization.jsonObject(with: lease.configuration) as! [String: Any]
                let routes = ((configuration["tun"] as? [String: Any])?["route-exclude-address"] as? [String] ?? []).compactMap(NetworkRoute.init)
                ipv4.excludedRoutes = routes.filter { !$0.ipv6 && !($0.address == "172.19.0.2" && $0.prefix == 32) }
                    .map { NEIPv4Route(destinationAddress: $0.address, subnetMask: $0.subnetMask) }
                settings.ipv4Settings = ipv4
                let ipv6 = NEIPv6Settings(addresses: ["fdfe:dcba:9876::1"], networkPrefixLengths: [126])
                ipv6.includedRoutes = [.default()]
                ipv6.excludedRoutes = routes.filter(\.ipv6).map { NEIPv6Route(destinationAddress: $0.address, networkPrefixLength: NSNumber(value: $0.prefix)) }
                settings.ipv6Settings = ipv6
                let dns = NEDNSSettings(servers: ["172.19.0.2"])
                dns.matchDomains = [""]
                settings.dnsSettings = dns
                setTunnelNetworkSettings(settings) { [self] error in
                    control.async { [self] in
                        guard currentID == id, pendingStart != nil else { return }
                        guard error == nil, lease.expiresAt > Date() else { failStart(TunnelError.start); return }
                        let expiry = DispatchWorkItem { [weak self] in
                            self?.cleanup()
                            self?.cancelTunnelWithError(TunnelError.expired)
                        }
                        expiration = expiry
                        control.asyncAfter(deadline: .now() + lease.expiresAt.timeIntervalSinceNow, execute: expiry)
                        readPackets(id: id)
                        output.async { [self] in writePackets(id: id) }
                        let completion = pendingStart; pendingStart = nil
                        completion?(nil)
                    }
                }
            } catch { failStart(error as? TunnelError ?? TunnelError.configuration) }
        }
    }
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        control.async { [self] in
            cleanup()
            let completion = pendingStart; pendingStart = nil
            completion?(TunnelError.start)
            completionHandler()
        }
    }
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard messageData.count <= 4096 else { completionHandler?(nil); return }
        control.async { [self] in
            guard currentID != 0, let envelope = try? JSONDecoder().decode(TunnelCommandEnvelope.self, from: messageData),
                  envelope.leaseID == leaseID,
                  let request = try? JSONEncoder().encode(envelope.command), request.count <= 4096 else { completionHandler?(nil); return }
            var response = [UInt8](repeating: 0, count: 65536)
            let count = request.withUnsafeBytes { input in
                response.withUnsafeMutableBytes { output in
                    ECYControl(currentID, UnsafeMutableRawPointer(mutating: input.baseAddress), Int32(input.count), output.baseAddress, Int32(output.count))
                }
            }
            completionHandler?(count > 0 ? Data(response.prefix(Int(count))) : nil)
        }
    }
    private var currentID: UInt64 { lock.lock(); defer { lock.unlock() }; return activeID }
    private func setID(_ id: UInt64) { lock.lock(); activeID = id; lock.unlock() }
    private func failStart(_ error: Error) {
        cleanup()
        let completion = pendingStart; pendingStart = nil
        completion?(error)
    }
    private func cleanup() {
        expiration?.cancel(); expiration = nil
        let id = currentID; setID(0)
        if id != 0 { ECYStop(id) }
        TunnelFiles.clear(group: group, id: leaseID)
        leaseID = nil
        if let runDirectory {
            if id != 0, let runLease { TunnelFiles.keepCache(group: group, lease: runLease, from: runDirectory) }
            try? FileManager.default.removeItem(at: runDirectory)
        }
        runDirectory = nil; runLease = nil
    }
    private func readPackets(id: UInt64) {
        guard currentID == id else { return }
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self, self.currentID == id else { return }
            for packet in packets {
                let result = packet.withUnsafeBytes { ECYSubmit(id, UnsafeMutableRawPointer(mutating: $0.baseAddress), Int32($0.count)) }
                if result == -1 { return }
            }
            self.readPackets(id: id)
        }
    }
    private func writePackets(id: UInt64) {
        var buffer = [UInt8](repeating: 0, count: 65535)
        while currentID == id {
            let count = buffer.withUnsafeMutableBytes { ECYRead(id, $0.baseAddress, Int32($0.count)) }
            if count < 0 { return }
            if count == 0 { continue }
            guard currentID == id else { return }
            let family = buffer[0] >> 4 == 6 ? AF_INET6 : AF_INET
            if !packetFlow.writePackets([Data(buffer.prefix(Int(count)))], withProtocols: [NSNumber(value: family)]) {
                control.async { [self] in
                    guard currentID == id else { return }
                    cleanup()
                    cancelTunnelWithError(TunnelError.start)
                }
                return
            }
        }
    }
}
