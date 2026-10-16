// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "AgentBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentBarCore", targets: ["AgentBarCore"]),
        .executable(name: "AgentBar", targets: ["AgentBar"]),
    ],
    targets: [
        .target(name: "AgentBarCore"),
        .executableTarget(name: "AgentBar", dependencies: ["AgentBarCore"]),
        .testTarget(name: "AgentBarCoreTests", dependencies: ["AgentBarCore", "AgentBar"]),
    ]
)
