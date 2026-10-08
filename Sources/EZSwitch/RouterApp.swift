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
private final class AppWindowCoordinator {
    static let shared = AppWindowCoordinator()

    private var settingsWindow: NSWindow?
    let settingsNav = SettingsNav()
    private var openWindow: OpenWindowAction?
    private var pendingPresentation = false

    func register(_ action: OpenWindowAction) {
        openWindow = action
        if pendingPresentation {
            pendingPresentation = false
            DispatchQueue.main.async { self.showSettings(store: .shared) }
        }
    }

    func showSettings(store: ConfigStore, section: SettingsSection? = nil) {
        if let section { settingsNav.section = section }
        if #available(macOS 15, *) {
            guard let openWindow else {
                pendingPresentation = true
                return
            }
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        // macOS 13–14 cannot suppress a Window scene on login-item launch.
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
        window.setContentSize(NSSize(width: 1120, height: 760))
        window.minSize = NSSize(width: 1000, height: 640)
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
            AppWindowCoordinator.shared.showSettings(store: ConfigStore.shared)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppWindowCoordinator.shared.showSettings(store: ConfigStore.shared)
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

        if #available(macOS 15, *) {
            Window(AppBrand.name, id: "settings") {
                SettingsView(store: store, nav: AppWindowCoordinator.shared.settingsNav)
            }
            .defaultSize(width: 1120, height: 760)
            .windowResizability(.contentMinSize)
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
        }

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
            CommandGroup(replacing: .appSettings) {
                Button("EZ Switch 面板…") {
                    AppWindowCoordinator.shared.showSettings(store: store)
                }
                .keyboardShortcut(",", modifiers: .command)
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
        alert.informativeText = "点击菜单栏中的箭头图标可切换路由；选择“EZ Switch 面板...”可管理模型、供应商和服务端口。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

/// 菜单栏图标
private struct MenuBarLabel: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var updater = UpdateChecker.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: store.serverError != nil ? "exclamationmark.triangle" : store.runningPort == nil ? "network.slash" : updater.availableRelease != nil ? "arrow.down.circle" : "arrow.triangle.branch")
            .accessibilityLabel(updater.availableRelease.map { "\(store.serviceTitle)，新版本 \($0.version) 可用" } ?? store.serviceTitle)
            .onAppear { AppWindowCoordinator.shared.register(openWindow) }
    }
}

/// 菜单内容容器：首帧兜底起服务
private struct MenuBarContent: View {
    @ObservedObject var store: ConfigStore
    @StateObject private var usage = MenuUsageSummary()

    var body: some View {
        MenuView(store: store, usage: usage)
            .onAppear {
                store.startServer()
            }
            // 只在菜单可见时异步读取一次；不在主线程读库，也不做全局定时轮询。
            .task {
                await usage.refresh(store: store.usageStore)
            }
    }
}

/// 菜单栏"今日用量"摘要。异步、按需刷新，可见时才触发。
@MainActor
final class MenuUsageSummary: ObservableObject {
    @Published private(set) var todayTokens: Int?
    @Published private(set) var isAvailable = true
    /// 覆盖完整（已知用量 == 上游尝试数）时省略"（已知）"后缀。
    @Published private(set) var isCompleteCoverage = true

    var menuTitle: String {
        guard isAvailable else { return "今日用量: 暂不可用" }
        guard let tokens = todayTokens else { return "今日用量: 读取中…" }
        let suffix = isCompleteCoverage ? "" : "（已知）"
        return "今日用量: \(UsageFormat.compact(tokens)) Tokens\(suffix)"
    }

    func refresh(store: UsageStore, now: Date = Date()) async {
        let calendar = Calendar.current
        let from = calendar.startOfDay(for: now)
        guard let to = calendar.date(byAdding: .day, value: 1, to: from) else { return }
        do {
            let snapshot = try await store.snapshot(from: from, to: to, grouping: .route)
            todayTokens = snapshot.totals.total
            isCompleteCoverage = snapshot.totals.knownAttempts >= snapshot.totals.attempts
            isAvailable = true
        } catch {
            todayTokens = nil
            isAvailable = false
        }
    }
}

struct MenuView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var usage: MenuUsageSummary
    @ObservedObject private var updater = UpdateChecker.shared

    var body: some View {
        if let err = store.serverError {
            Text("⚠️ \(err)")
        }
        Text(store.serviceTitle)
        Button("复制本地地址 · " + store.connectionURL) { copyText(store.connectionURL) }
            .disabled(store.runningPort == nil)

        Divider()

        Button(usage.menuTitle) {
            AppWindowCoordinator.shared.showSettings(store: store, section: .usage)
        }
        .help("打开用量统计，查看今日与本机历史 Token 用量")

        if let release = updater.availableRelease {
            Button("新版本 \(release.version) 可用…") {
                AppWindowCoordinator.shared.showSettings(store: store, section: .general)
            }
        }

        Divider()

        ForEach(store.config.fakes) { fake in
            Menu {
                let candidates = fake.orderedRemoteIDs.compactMap { id in
                    store.config.remotes.first { $0.id == id }
                }
                if candidates.isEmpty {
                    Text("未添加模型，请在面板中拖入")
                } else {
                    ForEach(candidates) { remote in
                        Button(modelLabel(remote, fake: fake)) {
                            store.selectRouteModel(fakeID: fake.id, remoteID: remote.id)
                        }
                    }
                }
            } label: {
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    Text(fake.fakeModelID)
                        + Text(gray("  " + menuRouteLabel(fake)))
                }
            }
        }

        Divider()

        Button("EZ Switch 面板...") {
            AppWindowCoordinator.shared.showSettings(store: store)
        }

        Divider()

        Button("退出 \(AppBrand.name)") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func menuRouteLabel(_ fake: FakeModel) -> String {
        let activeID = store.router.activeRemoteID(fakeID: fake.id)
        return store.config.remotes.first(where: { $0.id == activeID })?.routeLabel ?? "未绑定"
    }

    private func modelLabel(_ remote: RemoteModel, fake: FakeModel) -> String {
        remote.routeLabel + (store.router.activeRemoteID(fakeID: fake.id) == remote.id ? "  ✓" : "")
    }

    /// 菜单项文本的灰色部分（menu 里 AttributedString 的颜色才能保留）
    private func gray(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        a.foregroundColor = .secondary
        return a
    }
}
