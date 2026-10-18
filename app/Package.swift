// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZCCare",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ZCCare", targets: ["ZCCare"])],
    targets: [
        // Everything that does not draw: the CLI's JSON, running it, and what
        // needs attention. The tests cover this part.
        .target(name: "ZCCareCore"),
        .executableTarget(name: "ZCCare", dependencies: ["ZCCareCore"]),
        .testTarget(name: "ZCCareCoreTests", dependencies: ["ZCCareCore"]),
    ]
)
