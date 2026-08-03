// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "COCHelper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "COCHelperCore", targets: ["COCHelperCore"]),
        .executable(name: "COCHelper", targets: ["COCHelper"]),
        .executable(name: "smoke-api", targets: ["smoke-api"])
    ],
    targets: [
        .target(
            name: "COCHelperCore",
            path: "Sources/COCHelperCore",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "COCHelper",
            dependencies: ["COCHelperCore"],
            path: "Sources/COCHelper"
        ),
        .executableTarget(
            name: "smoke-api",
            dependencies: ["COCHelperCore"],
            path: "Tools/smoke-api"
        ),
        .testTarget(
            name: "COCHelperCoreTests",
            dependencies: ["COCHelperCore"],
            path: "Tests/COCHelperCoreTests",
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
