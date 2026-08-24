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
        .executable(name: "smoke-api", targets: ["smoke-api"]),
        .executable(name: "acceptance-runner", targets: ["acceptance-runner"])
    ],
    targets: [
        .target(
            name: "COCHelperCore",
            path: "Sources/COCHelperCore",
            resources: [
                .process("Resources"),
                // .copy 保留目录结构：GameCatalog/<gameVersion>/catalog.json，
                // 支持多版本目录共存（.process 会扁平化子目录）。
                .copy("GameCatalog")
            ]
        ),
        .target(
            name: "COCHelperApp",
            dependencies: ["COCHelperCore"],
            path: "Sources/COCHelperApp",
            resources: [
                // Issue #197：性能样本 fixtures（隐藏 seed 路径运行时加载）。
                // .copy 保留目录结构（与 GameCatalog 同模式）。
                .copy("PerfFixtures")
            ]
        ),
        .executableTarget(
            name: "COCHelper",
            dependencies: ["COCHelperCore", "COCHelperApp"],
            path: "Sources/COCHelper",
            swiftSettings: [
                // Issue #197：隐藏性能样本入口只在 debug 构建编译（#if DEBUG）。
                // Release 构建不定义 DEBUG → 菜单不进入生产 app。
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .executableTarget(
            name: "smoke-api",
            dependencies: ["COCHelperCore"],
            path: "Tools/smoke-api"
        ),
        .executableTarget(
            name: "acceptance-runner",
            dependencies: ["COCHelperCore", "COCHelperApp"],
            path: "Tools/acceptance-runner"
        ),
        .testTarget(
            name: "COCHelperCoreTests",
            dependencies: ["COCHelperCore", "COCHelperApp"],
            path: "Tests/COCHelperCoreTests",
            resources: [
                .process("Fixtures")
            ]
        ),
        .testTarget(
            name: "COCHelperCorePublicAPITests",
            dependencies: ["COCHelperCore"],
            path: "Tests/COCHelperCorePublicAPITests"
        )
    ]
)
