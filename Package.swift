// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "COCHelper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "COCHelperCore", targets: ["COCHelperCore"]),
        .executable(name: "COCHelper", targets: ["COCHelper"])
    ],
    targets: [
        .target(
            name: "COCHelperCore",
            path: "Sources/COCHelperCore"
        ),
        .executableTarget(
            name: "COCHelper",
            dependencies: ["COCHelperCore"],
            path: "Sources/COCHelper"
        ),
        .testTarget(
            name: "COCHelperCoreTests",
            dependencies: ["COCHelperCore"],
            path: "Tests/COCHelperCoreTests"
        )
    ]
)
