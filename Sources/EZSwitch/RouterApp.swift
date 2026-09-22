import SwiftUI
import AppKit

/// 启动参数。`--open-settings`：启动即打开设置窗。
/// 用静态标记防重复：menuBarExtraStyle(.menu) 的内容视图和 label 都可能各自 onAppear 一次。
enum LaunchFlag {
    static var openSettingsHandled = false
}

private enum AppBrand {
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "EZ Switch"
    }
}

@main
struct RouterApp: App {
    @StateObject private var store = ConfigStore.shared

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)   // 不占 Dock
        ConfigStore.shared.startServer()                      // 幂等；菜单没点开前就开始服务
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.menu)

        Window(AppBrand.name, id: "settings") {
            SettingsView(store: store)
        }
        .defaultSize(width: 980, height: 680)

        Window("日志", id: "logs") {
            LogWindowView()
        }
        .defaultSize(width: 560, height: 420)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 \(AppBrand.name)") {
                    NSApplication.shared.orderFrontStandardAboutPanel(nil)
                }
            }
            CommandGroup(replacing: .help) {
                Button("\(AppBrand.name) 帮助") {
                    showHelp()
                }
            }
        }
    }

    private func showHelp() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = AppBrand.name
        alert.informativeText = "点击菜单栏中的箭头图标可切换路由；选择“设置…”可管理模型、供应商和服务端口。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

/// 菜单栏图标（点开前就会实例化，所以 --open-settings 也挂这里）
private struct MenuBarLabel: View {
    @ObservedObject var store: ConfigStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: store.serverError != nil ? "exclamationmark.triangle" : store.runningPort == nil ? "network.slash" : "arrow.triangle.branch")
            .accessibilityLabel(store.serviceTitle)
            .onAppear { handleLaunchFlags(openWindow) }
    }
}

/// 菜单内容容器：首帧兜底起服务 + 处理启动参数
private struct MenuBarContent: View {
    @ObservedObject var store: ConfigStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuView(store: store)
            .onAppear {
                store.startServer()
                handleLaunchFlags(openWindow)
            }
    }
}

/// `--open-settings` 只生效一次（label 和内容视图可能各触发一遍）
@MainActor
private func handleLaunchFlags(_ openWindow: OpenWindowAction) {
    guard CommandLine.arguments.contains("--open-settings") else { return }
    guard !LaunchFlag.openSettingsHandled else { return }
    LaunchFlag.openSettingsHandled = true
    openWindow(id: "settings")
    NSApp.activate(ignoringOtherApps: true)
}

struct MenuView: View {
    @ObservedObject var store: ConfigStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let err = store.serverError {
            Text("⚠️ \(err)")
        }
        Text(store.serviceTitle)
        Button("复制本地地址 · " + store.connectionURL) { copyText(store.connectionURL) }
            .disabled(store.runningPort == nil)

        Divider()

        // 每条路由只绑定一个上游模型，所有 API 格式共用；子菜单按供应商分组。
        ForEach(store.config.fakes) { fake in
            Menu {
                let groups = store.groupedRemotes()
                if groups.isEmpty {
                    Text("未配置远端，请到设置里添加")
                } else {
                    ForEach(groups) { group in
                        Section(group.provider) {
                            ForEach(group.remotes) { remote in
                                Button(modelLabel(remote, fake: fake)) {
                                    store.setRoute(fakeID: fake.id, remoteID: remote.id)
                                }
                            }
                        }
                    }
                }
            } label: {
                Text(fake.fakeModelID)
                    + Text(gray("  " + (store.routeRemote(fake)?.routeLabel ?? "未绑定")))
            }
        }

        Divider()

        Button("设置…") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)   // accessory app 不开窗就抢不到焦点
        }

        Divider()

        Button("退出 \(AppBrand.name)") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func modelLabel(_ remote: RemoteModel, fake: FakeModel) -> String {
        remote.routeLabel + (fake.remoteID == remote.id ? "  ✓" : "")
    }

    /// 菜单项文本的灰色部分（menu 里 AttributedString 的颜色才能保留）
    private func gray(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        a.foregroundColor = .secondary
        return a
    }
}
