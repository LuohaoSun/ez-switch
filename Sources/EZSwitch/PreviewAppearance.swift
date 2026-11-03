import SwiftUI
import AppKit

// MARK: - 隔离预览外观选项
//
// 只服务于隔离的 StyleCheck 预览实例，用于在同一台机器上检查浅色/深色和窗口几何，
// 不读取、也不改写全局系统外观偏好。两个门禁必须同时成立才会生效：
//
//   1. Bundle.main.bundleIdentifier 以 `.stylecheck` 结尾；
//   2. EZSWITCH_CONFIG 指向 `/tmp/ezswitch-style-fixture/` 或
//      `/private/tmp/ezswitch-style-fixture/` 下的文件。
//
// 生产 bundle（local.sunluohao.ezswitch）和正式配置路径永远不会命中，
// 因此默认窗口尺寸、生产分支与窗口生命周期保持不变。
//
// 支持的环境变量（缺省时对应项不生效）：
//
//   EZSWITCH_PREVIEW_APPEARANCE=light|dark
//   EZSWITCH_PREVIEW_SIZE=1000x760|1120x760|1401x1066
//
// 任一变量非空但不是允许值时，整个预览配置视为无效，避免验收时“以为切了深色
// 其实仍是系统外观”这类静默偏差。

/// 预览实例可选的 app 外观。
enum PreviewAppearance: String, CaseIterable {
    case light
    case dark

    /// 只作用于当前进程的 `NSApp.appearance`，不修改系统全局偏好。
    var appKitAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// 预览实例允许的窗口内容尺寸（白名单，不接受任意几何）。
struct PreviewWindowSize: Equatable {
    /// 验收计划明确列出的三种尺寸。
    static let allowedRawValues = ["1000x760", "1120x760", "1401x1066"]

    let width: CGFloat
    let height: CGFloat

    private init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    init?(rawValue: String?) {
        guard let rawValue else { return nil }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1000x760": self.init(width: 1000, height: 760)
        case "1120x760": self.init(width: 1120, height: 760)
        case "1401x1066": self.init(width: 1401, height: 1066)
        default: return nil
        }
    }
}

/// 已通过门禁校验的预览配置；`nil` 表示当前进程不是隔离预览实例。
struct PreviewConfiguration: Equatable {
    let appearance: PreviewAppearance?
    let contentSize: PreviewWindowSize?

    var isActive: Bool { appearance != nil || contentSize != nil }
}

/// 预览门禁与环境变量解析。纯值逻辑，方便单元测试；不碰窗口和 UI。
enum PreviewOptions {
    static let bundleIdentifierSuffix = ".stylecheck"
    static let isolatedConfigDirectories = [
        "/tmp/ezswitch-style-fixture",
        "/private/tmp/ezswitch-style-fixture",
    ]

    /// 严格后缀匹配：生产 bundle id 没有该后缀。
    static func isStyleCheckBundle(identifier: String?) -> Bool {
        guard let identifier, !identifier.isEmpty else { return false }
        return identifier.hasSuffix(bundleIdentifierSuffix)
    }

    /// 配置必须位于固定的临时 fixture 目录内。先标准化再比较，防止 `..` 逃逸。
    static func isIsolatedConfigPath(_ rawPath: String?) -> Bool {
        guard let rawPath, !rawPath.isEmpty else { return false }
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return false }
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        return isolatedConfigDirectories.contains { directory in
            standardized == directory || standardized.hasPrefix(directory + "/")
        }
    }

    /// 解析并校验预览环境；任一非空值不合法时返回 `nil`。
    static func resolve(bundleIdentifier: String?,
                        environment: [String: String]) -> PreviewConfiguration? {
        guard isStyleCheckBundle(identifier: bundleIdentifier),
              isIsolatedConfigPath(environment["EZSWITCH_CONFIG"]) else {
            return nil
        }

        let appearance: PreviewAppearance?
        if let value = normalized(environment["EZSWITCH_PREVIEW_APPEARANCE"]) {
            guard let parsed = PreviewAppearance(rawValue: value) else { return nil }
            appearance = parsed
        } else {
            appearance = nil
        }

        let contentSize: PreviewWindowSize?
        if let value = normalized(environment["EZSWITCH_PREVIEW_SIZE"]) {
            guard let parsed = PreviewWindowSize(rawValue: value) else { return nil }
            contentSize = parsed
        } else {
            contentSize = nil
        }

        let configuration = PreviewConfiguration(appearance: appearance, contentSize: contentSize)
        return configuration.isActive ? configuration : nil
    }

    /// 当前进程的预览配置；生产环境返回 `nil`。
    static func current() -> PreviewConfiguration? {
        resolve(bundleIdentifier: Bundle.main.bundleIdentifier,
                environment: ProcessInfo.processInfo.environment)
    }

    /// 窗口首次出现时的一次性设置。只改本进程的 app 外观和该窗口内容尺寸，
    /// 不调整位置、不重开窗口、不触碰全局系统偏好。
    @MainActor
    static func apply(_ configuration: PreviewConfiguration, to window: NSWindow) {
        if let appearance = configuration.appearance {
            NSApp.appearance = appearance.appKitAppearance
        }
        if let contentSize = configuration.contentSize {
            window.setContentSize(NSSize(width: contentSize.width, height: contentSize.height))
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - 窗口挂载点

/// 一次性探针：只挂在设置窗口的根视图上。延迟到下一个主循环再设置，
/// 确保 SwiftUI 的 `.defaultSize` 和 AppKit 路径的默认几何已经落定。
private final class PreviewAppearanceProbeView: NSView {
    private let configuration: PreviewConfiguration
    private weak var appliedWindow: NSWindow?

    init(configuration: PreviewConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, appliedWindow !== window else { return }
        appliedWindow = window
        let configuration = configuration
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            PreviewOptions.apply(configuration, to: window)
        }
    }
}

/// 挂载到设置窗口根视图的探针。非预览实例返回空视图，不产生任何副作用。
struct PreviewAppearanceProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        guard let configuration = PreviewOptions.current() else {
            return NSView(frame: .zero)
        }
        return PreviewAppearanceProbeView(configuration: configuration)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
