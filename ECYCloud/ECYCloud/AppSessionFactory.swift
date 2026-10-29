import Foundation
import ECYCloudKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
enum AppSessionFactory {
    static func make() throws -> ClientSession {
        #if os(macOS)
        try ClientPreferences.migrateMacDefaults(applicationID: Bundle.main.bundleIdentifier!)
        #endif
        let endpoints = try PanelEndpoints.bundled()
        let vault = KeychainVault(service: "\(Bundle.main.bundleIdentifier!).apple-native")
        let version = ClientRelease.currentVersion
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let systemVersion = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        #if os(macOS)
        let platform = "macOS"
        let name = Host.current().localizedName ?? "Mac"
        let model = "Mac（Swift）"
        #else
        #if os(tvOS)
        let platform = "tvOS"
        #elseif os(visionOS)
        let platform = "visionOS"
        #else
        let platform = UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #endif
        let name = UIDevice.current.name
        let model = UIDevice.current.model
        #endif
        let device = DeviceInfo(id: vault.deviceID, name: name, model: model,
                                os: "\(platform) \(systemVersion)", platform: platform, version: version)
        #if os(macOS)
        let connection = ConnectionController(driver: MacTunnelDriver())
        #else
        let applicationID = Bundle.main.bundleIdentifier!
        let connection = ConnectionController(driver: AppleTunnelDriver(
            applicationID: applicationID, standby: AppleStandbyRuntime(applicationID: applicationID)))
        #endif
        return ClientSession(endpoints: endpoints, api: PanelAPI(device: device), vault: vault, connection: connection,
                             cache: PanelResponseCache())
    }
}
