// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EZSwitch",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "EZSwitch", targets: ["EZSwitch"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.62.0")
    ],
    targets: [
        .executableTarget(
            name: "EZSwitch",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Sources/EZSwitch",
            linkerSettings: [
                // SwiftPM 在 macOS 13 部署目标下会把 LC_BUILD_VERSION.sdk 写成 13.0，
                // 导致系统按老 SDK 应用渲染。保留 minOS 13.0，同时把链接 SDK 标为 27.0。
                .unsafeFlags(["-Xlinker", "-platform_version",
                              "-Xlinker", "macos",
                              "-Xlinker", "13.0",
                              "-Xlinker", "27.0"])
            ]
        ),
        .testTarget(
            name: "EZSwitchTests",
            dependencies: ["EZSwitch"],
            path: "Tests/EZSwitchTests"
        )
    ]
)
