// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeOS",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClaudeOSCore", targets: ["ClaudeOSCore"]),
        .library(name: "ClaudeOSBrain", targets: ["ClaudeOSBrain"]),
        .executable(name: "claudeos", targets: ["ClaudeOSApp"]),
        .executable(name: "claudeos-spike", targets: ["ClaudeOSSpike"]),
        .executable(name: "claudeos-brain-mcp", targets: ["ClaudeOSBrainMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "1.9.0"),
    ],
    targets: [
        .target(name: "ClaudeOSCore"),
        .target(
            name: "ClaudeOSIndex",
            dependencies: [
                "ClaudeOSCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "ClaudeOSBrain",
            dependencies: [
                "ClaudeOSCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "ClaudeOSBrainMCP",
            dependencies: ["ClaudeOSBrain"]
        ),
        .target(
            name: "ClaudeOSRuntime",
            dependencies: [
                "ClaudeOSCore",
                "ClaudeOSBrain",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .target(
            name: "ClaudeOSUI",
            dependencies: [
                "ClaudeOSCore", "ClaudeOSIndex", "ClaudeOSRuntime",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]
        ),
        .executableTarget(
            name: "ClaudeOSApp",
            dependencies: ["ClaudeOSCore", "ClaudeOSIndex", "ClaudeOSRuntime", "ClaudeOSUI"]
        ),
        .executableTarget(
            name: "ClaudeOSSpike",
            dependencies: [
                "ClaudeOSCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .testTarget(name: "ClaudeOSCoreTests", dependencies: ["ClaudeOSCore"]),
        .testTarget(name: "ClaudeOSIndexTests", dependencies: ["ClaudeOSIndex", "ClaudeOSCore"]),
        .testTarget(name: "ClaudeOSBrainTests", dependencies: ["ClaudeOSBrain"]),
    ]
)
