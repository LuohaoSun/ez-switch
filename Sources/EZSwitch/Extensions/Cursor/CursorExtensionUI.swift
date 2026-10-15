import SwiftUI
import AppKit

/// Cursor 扩展的 UI 组合点：把扩展页区块与启动胶水注册进通用 seam。
/// 位于扩展目录内，`BuiltinExtensions` 是唯一引用它的大门。
extension CursorExtension {
    /// 扩展页区块入口，由 `BuiltinExtensions.panes` 动态渲染。
    @MainActor static var pane: ExtensionPaneEntry {
        ExtensionPaneEntry(id: settingsKey) { store, onOpenSuppliers in
            AnyView(CursorSettingsSection(store: store, onOpenSuppliers: onOpenSuppliers))
        }
    }

    /// 进程终止观察者 token；持有在扩展目录内，MainActor 隔离，attach 幂等。
    @MainActor private static var terminationObserver: NSObjectProtocol?

    /// 启动胶水：把长驻连接模型挂到配置与通用 runtime（幂等，无 UI 也会连），
    /// 并在扩展目录内登记进程终止回调，立即停掉自有 sidecar。
    @MainActor static func start(in store: ConfigStore, runtime: ExtensionRuntime) {
        CursorConnectionModel.shared.attach(to: store, runtime: runtime)
        installTerminationObserver()
    }

    /// 应用退出时同步停掉本扩展的 sidecar，不改 RouterApp 主干。
    /// 只在扩展目录内登记一次，重复 start 不重复注册。
    @MainActor private static func installTerminationObserver() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            CursorSidecarClient.shared.shutdownImmediately()
        }
    }
}
