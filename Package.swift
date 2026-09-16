// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeProfiles",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProfileKit", targets: ["ProfileKit"]),
        .executable(name: "claude-profiles", targets: ["claude-profiles"]),
        .executable(name: "ClaudeProfilesApp", targets: ["ClaudeProfilesApp"]),
    ],
    targets: [
        .target(name: "ProfileKit"),
        .executableTarget(name: "claude-profiles", dependencies: ["ProfileKit"]),
        .executableTarget(name: "ClaudeProfilesApp", dependencies: ["ProfileKit"]),
        .testTarget(name: "ProfileKitTests", dependencies: ["ProfileKit"]),
    ]
)
