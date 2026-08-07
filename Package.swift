// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacPowerFlowCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PowerMetricsCore", targets: ["PowerMetricsCore"])
    ],
    targets: [
        .target(
            name: "PowerMetricsCore",
            path: "PowerFlow/Core"
        ),
        .testTarget(
            name: "PowerMetricsCoreTests",
            dependencies: ["PowerMetricsCore"],
            path: "Tests/PowerMetricsCoreTests"
        )
    ]
)
