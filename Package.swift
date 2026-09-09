// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Claudock",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ClaudockApp", targets: ["ClaudeUsage"]), .executable(name: "claudock", targets: ["ClaudockCLI"])],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(name: "ClaudeUsage", dependencies: ["UsageCore"]),
        .executableTarget(name: "ClaudockCLI", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"])
    ],
    swiftLanguageModes: [.v5]
)
