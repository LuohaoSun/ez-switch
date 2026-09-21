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
        AppMainMenu.shared.install()                          // accessory app 也需要自己的主菜单
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
    }
}

/// LSUIElement app 默认没有主菜单。安装一份标准 AppKit 菜单，并在 SwiftUI 完成启动、
/// app 被激活时重新确认，避免窗口成为 key window 后菜单栏仍归上一个 app。
@MainActor
private final class AppMainMenu: NSObject {
    static let shared = AppMainMenu()

    private var observingActivation = false

    private override init() {
        super.init()
    }

    func install() {
        let appName = AppBrand.name
        let mainMenu = NSMenu(title: "MainMenu")

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: appName)
        appMenuItem.submenu = appMenu

        addItem(to: appMenu, title: "关于 \(appName)",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        appMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "服务")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApplication.shared.servicesMenu = servicesMenu

        appMenu.addItem(.separator())
        addItem(to: appMenu, title: "隐藏 \(appName)",
                action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        addItem(to: appMenu, title: "隐藏其他应用",
                action: #selector(NSApplication.hideOtherApplications(_:)),
                keyEquivalent: "h", modifiers: [.command, .option])
        addItem(to: appMenu, title: "全部显示",
                action: #selector(NSApplication.unhideAllApplications(_:)))
        appMenu.addItem(.separator())
        addItem(to: appMenu, title: "退出 \(appName)",
                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "文件")
        fileMenuItem.submenu = fileMenu
        addItem(to: fileMenu, title: "关闭窗口",
                action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        addItem(to: editMenu, title: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        addItem(to: editMenu, title: "重做", action: Selector(("redo:")),
                keyEquivalent: "z", modifiers: [.command, .shift])
        editMenu.addItem(.separator())
        addItem(to: editMenu, title: "剪切",
                action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        addItem(to: editMenu, title: "复制",
                action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        addItem(to: editMenu, title: "粘贴",
                action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        addItem(to: editMenu, title: "全选",
                action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        addItem(to: windowMenu, title: "最小化",
                action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        addItem(to: windowMenu, title: "缩放", action: #selector(NSWindow.performZoom(_:)))
        windowMenu.addItem(.separator())
        addItem(to: windowMenu, title: "前置全部窗口",
                action: #selector(NSApplication.arrangeInFront(_:)))
        NSApplication.shared.windowsMenu = windowMenu

        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "帮助")
        helpMenuItem.submenu = helpMenu
        addItem(to: helpMenu, title: "\(appName) 帮助",
                action: #selector(showHelp(_:)), target: self)
        NSApplication.shared.helpMenu = helpMenu

        NSApplication.shared.mainMenu = mainMenu
        startObservingActivationIfNeeded()
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector?,
                         keyEquivalent: String = "",
                         modifiers: NSEvent.ModifierFlags = [.command],
                         target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = keyEquivalent.isEmpty ? [] : modifiers
        item.target = target
        menu.addItem(item)
        return item
    }

    private func startObservingActivationIfNeeded() {
        guard !observingActivation else { return }
        observingActivation = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidFinishLaunching(_:)),
            name: NSApplication.didFinishLaunchingNotification,
            object: NSApplication.shared
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApplication.shared
        )
    }

    @objc private func applicationDidFinishLaunching(_ notification: Notification) {
        install()
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        install()
    }

    @objc private func showHelp(_ sender: Any?) {
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
