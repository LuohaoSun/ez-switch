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
                // SwiftPM 把部署目标当成 SDK 版本写进 LC_BUILD_VERSION（实测 sdk 13.0），
                // 而系统按"链接的 SDK 版本"决定给不给新外观（Liquid Glass / 新窗口 chrome）——
                // sdk 13.0 会被当成老 app 渲染。显式声明 minos 13.0 / sdk 27.0：
                // 继续支持 macOS 13，同时让系统认出是新 SDK。
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
