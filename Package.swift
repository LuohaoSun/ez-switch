// swift-tools-version:5.9
import PackageDescription
import Foundation

// Set EZSWITCH_DISABLE_CURSOR=1 to compile and test the host with this extension absent.
let cursorEnabled = ProcessInfo.processInfo.environment["EZSWITCH_DISABLE_CURSOR"] != "1"
let cursorSourceExcludes = cursorEnabled ? [] : ["Extensions/Cursor"]
let cursorTestExcludes = cursorEnabled ? [] : ["Extensions/Cursor"]

let package = Package(
    name: "EZSwitch",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "EZSwitch", targets: ["EZSwitch"]),
        .executable(name: "ezs", targets: ["EZSCLI"])
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
            exclude: cursorSourceExcludes,
            resources: [
                // 预设供应商品牌图标，随 target 生成 EZSwitch_EZSwitch.bundle；
                // build-app.sh 再把该 bundle 复制进 .app/Contents/Resources。
                .copy("Resources/ProviderIcons")
            ],
            swiftSettings: cursorEnabled ? [.define("EZSWITCH_CURSOR_EXTENSION")] : [],
            linkerSettings: [
                // SwiftPM 在 macOS 13 部署目标下会把 LC_BUILD_VERSION.sdk 写成 13.0，
                // 导致系统按老 SDK 应用渲染。保留 minOS 13.0，同时把链接 SDK 标为 27.0。
                .unsafeFlags(["-Xlinker", "-platform_version",
                              "-Xlinker", "macos",
                              "-Xlinker", "13.0",
                              "-Xlinker", "27.0"])
            ]
        ),
        .executableTarget(name: "EZSCLI", path: "Sources/EZSCLI"),
        .testTarget(
            name: "EZSwitchTests",
            dependencies: ["EZSwitch"],
            path: "Tests/EZSwitchTests",
            exclude: cursorTestExcludes,
            swiftSettings: cursorEnabled ? [.define("EZSWITCH_CURSOR_EXTENSION")] : []
        ),
        .testTarget(
            name: "EZSCLITests",
            dependencies: ["EZSCLI"],
            path: "Tests/EZSCLITests"
        )
    ]
)
