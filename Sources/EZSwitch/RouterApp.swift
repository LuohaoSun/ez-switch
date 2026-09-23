import SwiftUI
import AppKit
import Carbon

private enum AppBrand {
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "EZ Switch"
    }
}

enum AppLaunchContext {
    static func shouldShowPanel(for event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == kCoreEventClass, event.eventID == kAEOpenApplication else {
            return true
        }
        return event.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) == nil &&
            event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue != keyAELaunchedAsLogInItem
    }
}

@MainActor
private final class AppWindowManager {
    static let shared = AppWindowManager()

    private var settingsWindow: NSWindow?
    private let settingsNav = SettingsNav()

    func showSettings(store: ConfigStore, section: SettingsSection? = nil) {
        if let section { settingsNav.section = section }
        if let settingsWindow {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(store: store, nav: settingsNav))
        let window = NSWindow(contentViewController: hosting)
        window.title = AppBrand.name
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 980, height: 680))
        window.minSize = NSSize(width: 860, height: 580)
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdateChecker.shared.startAutomaticChecks()
        if AppLaunchContext.shouldShowPanel(for: NSAppleEventManager.shared().currentAppleEvent) {
            AppWindowManager.shared.showSettings(store: ConfigStore.shared)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppWindowManager.shared.showSettings(store: ConfigStore.shared)
        return true
    }
}

@main
struct RouterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ConfigStore.shared

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        ConfigStore.shared.startServer()                      // 幂等；菜单没点开前就开始服务
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.menu)

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
            CommandGroup(replacing: .appSettings) {}
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
        alert.informativeText = "点击菜单栏中的箭头图标可切换路由；选择“EZ Switch 面板...”可管理模型、供应商和服务端口。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

/// 菜单栏图标
private struct MenuBarLabel: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var updater = UpdateChecker.shared

    var body: some View {
        Image(systemName: store.serverError != nil ? "exclamationmark.triangle" : store.runningPort == nil ? "network.slash" : updater.availableRelease != nil ? "arrow.down.circle" : "arrow.triangle.branch")
            .accessibilityLabel(updater.availableRelease.map { "\(store.serviceTitle)，新版本 \($0.version) 可用" } ?? store.serviceTitle)
    }
}

/// 菜单内容容器：首帧兜底起服务
private struct MenuBarContent: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        MenuView(store: store)
            .onAppear {
                store.startServer()
            }
    }
}

struct MenuView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var updater = UpdateChecker.shared

    var body: some View {
        if let err = store.serverError {
            Text("⚠️ \(err)")
        }
        Text(store.serviceTitle)
        Button("复制本地地址 · " + store.connectionURL) { copyText(store.connectionURL) }
            .disabled(store.runningPort == nil)

        if let release = updater.availableRelease {
            Button("新版本 \(release.version) 可用…") {
                AppWindowManager.shared.showSettings(store: store, section: .general)
            }
        }

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

        Button("EZ Switch 面板...") {
            AppWindowManager.shared.showSettings(store: store)
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
