// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SiftCore", targets: ["SiftCore"]),
        .library(name: "SiftBrain", targets: ["SiftBrain"]),
        .executable(name: "sift", targets: ["SiftApp"]),
        .executable(name: "sift-brain-mcp", targets: ["SiftBrainMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "1.9.0"),
    ],
    targets: [
        .target(name: "SiftCore"),
        .target(
            name: "SiftIndex",
            dependencies: [
                "SiftCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "SiftBrain",
            dependencies: [
                "SiftCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "SiftBrainMCP",
            dependencies: ["SiftBrain", "SiftCore"]
        ),
        .target(
            name: "SiftRuntime",
            dependencies: [
                "SiftCore",
                "SiftBrain",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "SiftViews",
            dependencies: [
                "SiftCore", "SiftIndex", "SiftRuntime", "SiftBrain",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]
        ),
        .executableTarget(
            name: "SiftApp",
            dependencies: ["SiftCore", "SiftIndex", "SiftRuntime", "SiftViews"]
        ),
        .testTarget(name: "SiftCoreTests", dependencies: ["SiftCore"]),
        .testTarget(name: "SiftIndexTests", dependencies: ["SiftIndex", "SiftCore", "SiftBrain"]),
        .testTarget(name: "SiftBrainTests", dependencies: ["SiftBrain"]),
        .testTarget(name: "SiftRuntimeTests", dependencies: ["SiftRuntime", "SiftBrain"]),
        .testTarget(name: "SiftViewsTests", dependencies: ["SiftViews", "SiftBrain"]),
    ]
)
