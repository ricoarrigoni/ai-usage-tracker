// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsageTracker",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "UsageCore", targets: ["UsageCore"]),
        .executable(name: "aiusage", targets: ["aiusage"]),
    ],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(name: "aiusage", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
    ]
)
