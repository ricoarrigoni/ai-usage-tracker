// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsageTracker",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "UsageCore", targets: ["UsageCore"]),
        .executable(name: "aiusage", targets: ["aiusage"]),
        .executable(name: "AIUsageTracker", targets: ["AIUsageTrackerApp"]),
    ],
    targets: [
        .target(name: "UsageCore"),
        .target(name: "UsageUI", dependencies: ["UsageCore"]),
        .executableTarget(name: "aiusage", dependencies: ["UsageCore"]),
        .executableTarget(name: "AIUsageTrackerApp", dependencies: ["UsageCore", "UsageUI"]),
        .executableTarget(name: "panel-snapshot", dependencies: ["UsageCore", "UsageUI"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
    ]
)
