// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HealthToken",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "HealthTokenCore", targets: ["HealthTokenCore"]),
        .executable(name: "HealthToken", targets: ["HealthTokenApp"])
    ],
    targets: [
        .target(name: "HealthTokenCore"),
        .executableTarget(
            name: "HealthTokenApp",
            dependencies: ["HealthTokenCore"]
        ),
        .testTarget(
            name: "HealthTokenCoreTests",
            dependencies: ["HealthTokenCore"]
        )
    ]
)
