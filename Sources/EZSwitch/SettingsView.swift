import SwiftUI
import AppKit

// 液态玻璃：系统 chrome（标题栏 / 工具栏 / 侧栏）由 SDK 27 链接 + navigationTitle/标准 toolbar
// 自动生效。可以放心用官方 .buttonStyle(.glass)（HIG 推荐用按钮样式而非自绘玻璃）；
// 但 backgroundExtensionEffect() 绝不能加在 List 上——官方语义是把该视图镜像复制到四周再模糊裁剪，
// 加在内容列表上会让行渲染错乱（实测：行文字空白、单元格错位）。

extension View {
    /// 工具栏按钮玻璃样式（macOS 26+ 才有）；低版本原样返回
    @ViewBuilder
    func glassButtonIfAvailable() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self
        }
    }

}

/// LSUIElement app 即使装了 NSApp.mainMenu，只要保持 .accessory，窗口成为 key 后
/// macOS 左上角菜单栏仍可能归上一个应用。这里只在 app 窗口可见时切到 .regular，
/// 全部窗口关闭后恢复 .accessory，避免长期占 Dock。
@MainActor
private final class WindowActivationController: NSObject {
    static let shared = WindowActivationController()

    private struct WeakWindow {
        weak var value: NSWindow?
    }

    private var registered: [ObjectIdentifier: WeakWindow] = [:]

    private override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowDidBecomeKey(_:)),
                           name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowWillClose(_:)),
                           name: NSWindow.willCloseNotification, object: nil)
    }

    func register(_ window: NSWindow?) {
        prune()
        guard let window else { return }
        registered[ObjectIdentifier(window)] = WeakWindow(value: window)
        if window.isKeyWindow { activate(window) }
    }

    private func isRegistered(_ window: NSWindow) -> Bool {
        registered[ObjectIdentifier(window)]?.value === window
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isRegistered(window) else { return }
        activate(window)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isRegistered(window) else { return }
        registered.removeValue(forKey: ObjectIdentifier(window))
        DispatchQueue.main.async { [weak self] in self?.restoreAccessoryIfNeeded() }
    }

    private func activate(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func restoreAccessoryIfNeeded() {
        prune()
        if registered.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }

    private func prune() {
        registered = registered.filter { $0.value.value != nil }
    }
}

private final class WindowActivationProbe: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            WindowActivationController.shared.register(self?.window)
        }
    }
}

/// 挂到每个 SwiftUI Window 的根视图；窗口出现时激活并置于最前，同时让菜单栏归属本 app。
struct WindowActivator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowActivationProbe(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - 设置窗口骨架

enum SettingsSection: Hashable {
    case models, remotes, activity, general
}

/// 侧栏当前页。不用 `@State`（本机只有 CommandLineTools，没有 SwiftUIMacros 插件，
/// `@State` 宏展开会报 "plugin for module 'SwiftUIMacros' not found"）。
@MainActor
final class SettingsNav: ObservableObject {
    @Published var section: SettingsSection = .models
    @Published var sidebarVisible = true
}

struct SettingsView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var nav: SettingsNav

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                SettingsSidebarRow(title: "路由", systemImage: "arrow.triangle.branch",
                                   section: .models, selection: nav.section) {
                    nav.section = .models
                }
                SettingsSidebarRow(title: "供应商", systemImage: "server.rack",
                                   section: .remotes, selection: nav.section) {
                    nav.section = .remotes
                }
                SettingsSidebarRow(title: "活动", systemImage: "waveform.path.ecg",
                                   section: .activity, selection: nav.section) {
                    nav.section = .activity
                }
                SettingsSidebarRow(title: "通用", systemImage: "gearshape",
                                   section: .general, selection: nav.section) {
                    nav.section = .general
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .frame(width: 190)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(width: nav.sidebarVisible ? 190 : 0, alignment: .leading)
            .clipped()
            .opacity(nav.sidebarVisible ? 1 : 0)
            .allowsHitTesting(nav.sidebarVisible)

            Divider().opacity(nav.sidebarVisible ? 1 : 0)

            NavigationStack {
                switch nav.section {
                case .models: ModelsPane(store: store)
                case .remotes: RemotesView(store: store)
                case .activity: LogWindowView()
                case .general: GeneralPane(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(WindowActivator().frame(width: 0, height: 0))
        // 侧栏展开时仍要给供应商页留出 260pt 列表 + 390pt 详情。
        .frame(minWidth: 860, minHeight: 580)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        nav.sidebarVisible.toggle()
                    }
                } label: {
                    Label(nav.sidebarVisible ? "隐藏侧栏" : "显示侧栏",
                          systemImage: "sidebar.left")
                }
                .help(nav.sidebarVisible ? "隐藏侧栏" : "显示侧栏")
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }
    }
}

private struct SettingsSidebarRow: View {
    let title: String
    let systemImage: String
    let section: SettingsSection
    let selection: SettingsSection
    let action: () -> Void

    private var selected: Bool { section == selection }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.accentColor.opacity(0.16))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 模型页

/// 模型页的可变 UI 状态：当前打开的编辑 sheet 目标
@MainActor
final class ModelsPaneDraft: ObservableObject {
    @Published var target: FakeEditTarget?
    @Published var selection: UUID?
    @Published var deletion: FakeModel?
    @Published var confirmDelete = false
}

/// sheet(item:) 的目标；新增时 id 固定为 "new"
struct FakeEditTarget: Identifiable {
    let fake: FakeModel?
    var id: String { fake?.id.uuidString ?? "new" }
}

struct ModelsPane: View {
    @ObservedObject var store: ConfigStore
    @StateObject private var ui = ModelsPaneDraft()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ServiceSummary(store: store).padding(.horizontal, 24).padding(.top, 20)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("模型路由").font(.title2.bold())
                    Text("客户端使用固定模型 ID，目标可随时切换。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(store.config.fakes.count) 条路由").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 24)
            List(selection: $ui.selection) {
                if store.config.fakes.isEmpty {
                    EmptyState(title: "添加第一条路由", detail: "先添加供应商模型，再为客户端设置固定的模型 ID。", symbol: "arrow.triangle.branch")
                }
                ForEach(store.config.fakes) { fake in routeRow(fake) }
                    .onMove { offsets, destination in
                        let sources = offsets.map { store.config.fakes[$0].id }
                        let target = destination < store.config.fakes.count
                            ? store.config.fakes[destination].id : nil
                        store.moveFakes(sources: sources, before: target)
                    }
            }
            .listStyle(.inset)
            .onDeleteCommand { requestDelete() }
        }
        .navigationTitle("路由")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if let fake = selectedFake { ui.target = FakeEditTarget(fake: fake) }
                } label: { Label("编辑路由", systemImage: "pencil") }
                .disabled(selectedFake == nil).help("编辑选中的路由")
                Button { requestDelete() } label: { Label("删除路由", systemImage: "trash") }
                    .disabled(selectedFake == nil).help("删除选中的路由")
                Button { ui.target = FakeEditTarget(fake: nil) } label: {
                    Label("添加路由", systemImage: "plus")
                }
            }
        }
        .sheet(item: $ui.target) { target in
            FakeEditSheet(store: store, source: target.fake).id(target.id)
        }
        .alert("删除选中的路由？", isPresented: $ui.confirmDelete) {
            Button("取消", role: .cancel) { ui.deletion = nil }
            Button("删除", role: .destructive) {
                if let fake = ui.deletion { store.removeFake(id: fake.id) }
                ui.selection = nil
                ui.deletion = nil
            }
        } message: {
            Text("客户端将无法再使用 \(ui.deletion?.fakeModelID ?? "")。供应商模型会保留。")
        }
    }

    private var selectedFake: FakeModel? {
        store.config.fakes.first { $0.id == ui.selection }
    }

    private func requestDelete() {
        guard let fake = selectedFake else { return }
        ui.deletion = fake
        ui.confirmDelete = true
    }

    private func routeRow(_ fake: FakeModel) -> some View {
        let remote = store.routeRemote(fake)
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                .help("拖动排序，也可右键上移或下移")
            Text(fake.fakeModelID).font(.system(.body, design: .monospaced).weight(.medium))
                .lineLimit(1).truncationMode(.middle).help(fake.fakeModelID)
                .frame(maxWidth: 150, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Button { copyText(fake.fakeModelID) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("复制模型 ID").accessibilityLabel("复制模型 ID")
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                Menu {
                    Button("未绑定") { store.setRoute(fakeID: fake.id, remoteID: nil) }
                    ForEach(store.groupedRemotes()) { group in
                        Section(group.provider) {
                            ForEach(group.remotes) { target in
                                Button((fake.remoteID == target.id ? "✓ " : "") + target.routeLabel) {
                                    store.setRoute(fakeID: fake.id, remoteID: target.id)
                                }
                            }
                        }
                    }
                } label: {
                    Text(remote?.routeLabel ?? "选择目标模型")
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                }
                .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
                .help(remote?.routeLabel ?? "选择目标模型")
            Spacer(minLength: 8)
            StatusLabel(title: remote == nil ? "未绑定" : remote!.needsCredentials ? "凭据待配置" : "已绑定",
                        warning: remote == nil || remote?.needsCredentials == true)

        }
        .modifier(NativeListRow())
        .tag(fake.id)
        .contextMenu {
            Button("编辑…") { ui.target = FakeEditTarget(fake: fake) }
            Button("复制模型 ID") { copyText(fake.fakeModelID) }
            Divider()
            Button("上移") { store.nudgeFake(id: fake.id, by: -1) }
            Button("下移") { store.nudgeFake(id: fake.id, by: 1) }
            Divider()
            Button("删除…", role: .destructive) {
                ui.selection = fake.id
                requestDelete()
            }
        }
    }
}

// MARK: - fake 编辑 sheet

@MainActor
final class FakeEditDraft: ObservableObject {
    @Published var modelID: String
    @Published var remoteID: UUID?
    @Published var confirmDelete = false
    @Published var modelTouched = false

    init(source: FakeModel?) {
        modelID = source?.fakeModelID ?? ""
        remoteID = source?.remoteID
    }
}

struct FakeEditSheet: View {
    @ObservedObject var store: ConfigStore
    let source: FakeModel?

    @StateObject private var draft: FakeEditDraft
    @Environment(\.dismiss) private var dismiss

    init(store: ConfigStore, source: FakeModel?) {
        self.store = store
        self.source = source
        _draft = StateObject(wrappedValue: FakeEditDraft(source: source))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("客户端模型") {
                    TextField("对外模型 ID", text: $draft.modelID)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: draft.modelID) { _ in draft.modelTouched = true }

                    if draft.modelTouched, let error = errorText {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }

                Section("绑定") {
                    Picker("绑定远端", selection: $draft.remoteID) {
                        Text("未绑定").tag(UUID?.none)
                        ForEach(store.groupedRemotes()) { group in
                            Section(group.provider) {
                                ForEach(group.remotes) { remote in
                                    Text(remote.routeLabel)
                                        .tag(UUID?.some(remote.id))
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 500)
        .frame(minHeight: 360)
        .alert("删除这条路由？", isPresented: $draft.confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let src = source { store.removeFake(id: src.id) }
                dismiss()
            }
        } message: {
            Text(verbatim: "客户端将无法再使用此模型 ID。供应商模型会保留。")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if source != nil {
                Button("删除") { draft.confirmDelete = true }
                    .foregroundColor(.red)
            }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("保存") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(errorText != nil)
        }
        .padding(12)
    }

    /// 即时校验（红字）；nil = 可以保存
    private var errorText: String? {
        let mid = draft.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if mid.isEmpty { return "模型 ID 不能为空" }
        if store.config.fakes.contains(where: {
            $0.id != source?.id && $0.fakeModelID == mid
        }) {
            return "\(mid) 已存在"
        }
        return nil
    }

    private func save() {
        if let src = source {
            if let err = store.updateFake(id: src.id, fakeModelID: draft.modelID,
                                          remoteID: draft.remoteID) {
                // 兜底：理论上 errorText 已经拦住了
                Log.shared.log("fake: 保存被拒绝 — \(err)")
                return
            }
        } else if !store.addFake(fakeModelID: draft.modelID, remoteID: draft.remoteID) {
            return
        }
        dismiss()
    }
}
