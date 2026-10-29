// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ECYCloudKit",
    platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v17), .visionOS(.v1)],
    products: [.library(name: "ECYCloudKit", targets: ["ECYCloudKit"])],
    targets: [
        .target(name: "ECYCloudKit", resources: [.process("Resources")]),
        .testTarget(name: "ECYCloudKitTests", dependencies: ["ECYCloudKit"])
    ]
)
