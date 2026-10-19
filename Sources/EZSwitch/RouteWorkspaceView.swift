import SwiftUI

private enum WorkspaceSheet: Identifiable {
    case newProvider
    case provider(String)
    case newModel(UUID)
    case route(UUID?)
    case catalog(String)

    var id: String {
        switch self {
        case .newProvider: return "new-provider"
        case .provider(let name): return "provider-\(name)"
        case .newModel(let id): return "new-model-\(id)"
        case .route(let id): return "route-\(id?.uuidString ?? "new")"
        case .catalog(let name): return "catalog-\(name)"
        }
    }
}

@MainActor
private final class WorkspaceDraft: ObservableObject {
    @Published var query = ""
    @Published var collapsedProviders = Set<String>()
    @Published var collapsedRoutes = Set<UUID>()
    @Published var supplierTableHeights: [String: CGFloat] = [:]
    @Published var sheet: WorkspaceSheet?
    @Published var providerToDelete: String?
    @Published var routeToDelete: UUID?
    /// 跨所有供应商卡片共享的单个选中模型；任一时刻最多一张卡片显示选中。
    @Published var selectedModelID: UUID?
}

struct RouteWorkspaceView: View {
    @ObservedObject var store: ConfigStore
    /// 通用扩展状态信号：连接器连接变化时 revision 递增，据此重算供应商卡片不可用提示。
    @ObservedObject private var runtime = ExtensionRuntime.shared
    @StateObject private var ui = WorkspaceDraft()
    private var groups: [RemoteGroup] { store.remoteGroups(matching: ui.query) }
    private var remoteByID: [UUID: RemoteModel] {
        Dictionary(uniqueKeysWithValues: store.config.remotes.map { ($0.id, $0) })
    }
    /// 工作区共享选中只在模型仍存在时生效：模型被移除（删模型 / 删供应商 / 目录取消勾选）后自动清空。
    private var selectedModelID: UUID? {
        guard let id = ui.selectedModelID,
              store.config.remotes.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    var body: some View {
        NativeWorkspaceSplit(suppliers: supplierPanel, routes: routePanel)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .navigationTitle("供应商与路由")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("添加供应商") { ui.sheet = .newProvider }
                    Button("添加路由") { ui.sheet = .route(nil) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuIndicator(.hidden)
                .help("添加供应商或路由")
                .accessibilityLabel("添加")
            }
        }
        .sheet(item: $ui.sheet) { target in
            switch target {
            case .newProvider:
                NewProviderSheet(store: store)
            case .provider(let name):
                if let group = store.groupedRemotes().first(where: { $0.provider == name }) {
                    ProviderEditSheet(store: store, group: group)
                }
            case .newModel(let id):
                if let template = remoteByID[id] {
                    RemoteEditSheet(store: store, source: nil, template: template)
                }
            case .route(let id):
                FakeEditSheet(store: store, source: store.config.fakes.first { $0.id == id })
            case .catalog(let name):
                if let group = store.groupedRemotes().first(where: { $0.provider == name }),
                   let remote = group.remotes.first {
                    ModelCatalogSheet(store: store, provider: name, remote: remote)
                }
            }
        }
        .alert("配置未保存", isPresented: Binding(
            get: { store.configSaveError != nil },
            set: { if !$0 { store.configSaveError = nil } }
        )) {
            Button("重试保存") { store.save() }
            Button("关闭", role: .cancel) { store.configSaveError = nil }
        } message: {
            Text(store.configSaveError ?? "")
        }
        .alert("删除供应商？", isPresented: Binding(
            get: { ui.providerToDelete != nil }, set: { if !$0 { ui.providerToDelete = nil } }
        )) {
            Button("取消", role: .cancel) { ui.providerToDelete = nil }
            Button("删除", role: .destructive) {
                if let name = ui.providerToDelete { store.removeProvider(name) }
                ui.providerToDelete = nil
            }
        } message: {
            Text("供应商的所有模型会被删除；使用这些模型的路由将移除对应候选项。")
        }
        .alert("删除路由？", isPresented: Binding(
            get: { ui.routeToDelete != nil }, set: { if !$0 { ui.routeToDelete = nil } }
        )) {
            Button("取消", role: .cancel) { ui.routeToDelete = nil }
            Button("删除", role: .destructive) {
                if let id = ui.routeToDelete { store.removeFake(id: id) }
                ui.routeToDelete = nil
            }
        } message: {
            Text("客户端将无法再使用这个模型 ID。")
        }
    }

    private var supplierPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("供应商与模型").font(.headline)
                Spacer()
            }
            TextField("搜索供应商或模型", text: $ui.query)
                .textFieldStyle(.roundedBorder)
            if store.config.remotes.isEmpty {
                EmptyState(title: "添加第一个供应商", detail: "先配置地址、凭据和模型，再拖到右侧路由。", symbol: "server.rack")
                Spacer()
            } else {
                NativeReorderableCards(items: groups, spacing: 10, enabled: ui.query.isEmpty,
                                       move: { store.moveProviders(sources: $0, before: $1) }) { group in
                    supplierGroup(group)
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func supplierGroup(_ group: RemoteGroup) -> some View {
        let expanded = !ui.query.isEmpty || !ui.collapsedProviders.contains(group.provider)
        return VStack(alignment: .leading, spacing: 0) {
            CollapsibleCardHeader(
                dragID: group.id,
                dragEnabled: ui.query.isEmpty,
                isExpanded: expanded,
                toggle: {
                    guard ui.query.isEmpty else { return }
                    if expanded { ui.collapsedProviders.insert(group.provider) }
                    else { ui.collapsedProviders.remove(group.provider) }
                },
                accessibilityLabel: "供应商 \(group.provider)，\(group.remotes.count) 个模型",
                help: ui.query.isEmpty ? "展开或收起；拖动标题调整供应商顺序" : "展开或收起"
            ) {
                HStack(spacing: 8) {
                    providerBrandIcon(group)
                        .frame(width: 18, height: 18)
                    Text(group.provider).font(.subheadline.bold()).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(group.remotes.count)").font(.caption).foregroundStyle(.secondary)
                }
            } accessory: {
                Menu {
                    providerMenu(group)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .help("管理 \(group.provider)")
                .accessibilityLabel("管理 \(group.provider) 供应商")
            }
            .contentShape(Rectangle())
            .contextMenu { providerMenu(group) }
            if let connector = unavailableConnector(group) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.caption)
                    Text("\(connector) 连接不可用，请在“扩展”页连接")
                        .font(.caption)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }
            CollapsibleBody(isExpanded: expanded,
                            expandedHeight: CollapsibleMetrics.supplierBodyHeight(
                                tableHeight: ui.supplierTableHeights[group.provider] ?? 0)) {
                Divider()
                    .padding(.horizontal, CollapsibleMetrics.supplierSelectionInset)
                    .padding(.top, CollapsibleMetrics.supplierSeparatorTop)
                NativeSupplierModelList(
                    items: group.remotes.map {
                        SupplierModelItem(id: $0.id, label: $0.model, needsCredentials: $0.needsCredentials)
                    },
                    provider: group.provider,
                    sortEnabled: ui.query.isEmpty,
                    store: store,
                    onRename: { store.updateModel(id: $0, model: $1) },
                    onDelete: { id in
                        store.removeRemote(id: id)
                        if ui.selectedModelID == id { ui.selectedModelID = nil }
                    },
                    selectedModelID: selectedModelID,
                    onSelectionChange: { ui.selectedModelID = $0 },
                    onContentHeightChange: { height in
                        // 表格上报的真实净高；高度变化不改 identity，拖动/选中/就地重命名不受影响。
                        if ui.supplierTableHeights[group.provider] != height {
                            ui.supplierTableHeights[group.provider] = height
                        }
                    },
                    isInteractive: expanded
                )
                .padding(.top, CollapsibleMetrics.supplierListTop)
            } collapsed: {
                // 供应商卡片收起时不保留摘要，与原有行为一致。
                EmptyView()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    @ViewBuilder
    private func providerMenu(_ group: RemoteGroup) -> some View {
        Button("获取模型列表…") { ui.sheet = .catalog(group.provider) }
        Button("添加模型…") {
            if let first = group.remotes.first { ui.sheet = .newModel(first.id) }
        }
        Button("编辑供应商…") { ui.sheet = .provider(group.provider) }
        Divider()
        Button("删除供应商…", role: .destructive) { ui.providerToDelete = group.provider }
    }

    @ViewBuilder
    private func routeMenu(_ fake: FakeModel) -> some View {
        Button("编辑路由 ID…") { ui.sheet = .route(fake.id) }
        Button("复制路由 ID") { copyText(fake.fakeModelID) }
        Divider()
        Button("删除路由…", role: .destructive) { ui.routeToDelete = fake.id }
    }

    /// 扩展连接器供应商：连接由扩展/CLI 提供，native 端点恒关闭。返回不可用时用于提示的
    /// 显示名（缺失扩展注册则退回 source.rawValue）；就绪状态只由通用 router 判定。
    private func unavailableConnector(_ group: RemoteGroup) -> String? {
        guard let source = group.remotes.first?.source, source != .api else { return nil }
        guard !store.router.connectorAvailable(source: source) else { return nil }
        return store.registry.connector(for: source)?.displayName ?? source.rawValue
    }

    /// 标题左侧品牌图标：命中 catalog 品牌用其离线图标，否则用中性 server.rack 保持标题对齐。
    @ViewBuilder
    private func providerBrandIcon(_ group: RemoteGroup) -> some View {        switch ProviderBrandResolver.resolve(group) {
        case .known(let iconName):
            ProviderPresetIcon(brandKey: iconName, label: group.provider)
        case .unknown:
            Image(systemName: "server.rack")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }

    private var routePanel: some View {
        let modelsByID = remoteByID
        return VStack(alignment: .leading, spacing: 12) {
            ServiceSummary(store: store)
            HStack {
                Text("路由 ID").font(.title2.bold())
                Spacer()
            }
            if store.config.fakes.isEmpty {
                EmptyState(title: "添加第一条路由", detail: "创建客户端模型 ID，然后从左侧拖入模型。", symbol: "arrow.triangle.branch")
                Spacer()
            } else {
                NativeReorderableCards(items: store.config.fakes, spacing: 14,
                                       move: { store.moveFakes(sources: $0, before: $1) }) { fake in
                    routeCard(fake, modelsByID: modelsByID)
                }
            }
        }.padding(20)
    }

    private func routeCard(_ fake: FakeModel, modelsByID: [UUID: RemoteModel]) -> some View {
        let expanded = !ui.collapsedRoutes.contains(fake.id)
        return VStack(alignment: .leading, spacing: 0) {
            CollapsibleCardHeader(
                dragID: fake.id,
                isExpanded: expanded,
                toggle: {
                    if expanded { ui.collapsedRoutes.insert(fake.id) }
                    else { ui.collapsedRoutes.remove(fake.id) }
                },
                accessibilityLabel: "路由 \(fake.fakeModelID)",
                help: "展开或收起；拖动标题调整路由顺序"
            ) {
                Text(fake.fakeModelID).font(.system(.headline, design: .monospaced)).lineLimit(1)
            } accessory: {
                HStack(spacing: 8) {
                    Toggle("自动切换", isOn: Binding(
                        get: { store.config.fakes.first(where: { $0.id == fake.id })?.autoFallback ?? false },
                        set: { store.setRouteTargets(fakeID: fake.id, remoteIDs: fake.orderedRemoteIDs, autoFallback: $0) }
                    )).toggleStyle(.switch).controlSize(.small)
                    Menu {
                        routeMenu(fake)
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 28, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .accessibilityLabel("管理路由 \(fake.fakeModelID)")
                }
            }
            .contentShape(Rectangle())
            .contextMenu { routeMenu(fake) }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            CollapsibleBody(isExpanded: expanded,
                            expandedHeight: CollapsibleMetrics.routeBodyHeight(
                                candidateCount: fake.orderedRemoteIDs.count),
                            collapsedHeight: CollapsibleMetrics.routeSummaryHeight) {
                Divider().padding(.top, CollapsibleMetrics.routeSeparatorTop).padding(.horizontal, 14)
                RouteCandidateList(store: store, fake: fake, modelsByID: modelsByID, isInteractive: expanded)
                    .padding(.horizontal, 14)
                    .padding(.bottom, CollapsibleMetrics.routeListBottom)
            } collapsed: {
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    let current = store.router.activeRemoteID(fakeID: fake.id).flatMap { modelsByID[$0] }
                    Text(current.map { "当前 · \($0.routeLabel)" } ?? "未配置模型")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: CollapsibleMetrics.routeSummaryLine, alignment: .leading)
                .padding(.leading, 34).padding(.trailing, 14)
                .padding(.top, CollapsibleMetrics.routeSummaryTop)
                .padding(.bottom, CollapsibleMetrics.routeSummaryBottom)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

}

/// 单条路由的候选项列表：行几何、拖动发起与插入落点全部交给原生 `NSTableView`（见 `NativeRouteCandidateList`），
/// 末尾占位行也由该表格提供；这里只把当前配置映射成行模型。
private struct RouteCandidateList: View {
    @ObservedObject var store: ConfigStore
    let fake: FakeModel
    let modelsByID: [UUID: RemoteModel]
    /// 收起时传给表格：不参与键盘焦点循环、不暴露辅助功能元素。
    let isInteractive: Bool

    var body: some View {
        // 每 2s 取一次“当前”远端；行标识不变时代表层只就地更新指示，不会 reload 表格或打断拖动。
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            NativeRouteCandidateList(
                items: candidateItems,
                activeRemoteID: store.router.activeRemoteID(fakeID: fake.id),
                store: store,
                fakeID: fake.id,
                isInteractive: isInteractive
            )
            .padding(.top, 4)
        }
    }

    private var candidateItems: [RouteCandidateItem] {
        fake.orderedRemoteIDs.map { id in
            RouteCandidateItem(id: id, label: modelsByID[id]?.routeLabel ?? "未知模型")
        }
    }
}

/// 目录选择只作用于当前展示的模型，接口未返回的现有模型不参与删除。
enum ModelCatalogSelection {
    /// 首次加载：勾选本次返回且本地已有（按当前配置）的模型。
    static func initialSelection(models: [String], existing: Set<String>) -> Set<String> {
        Set(models).intersection(existing)
    }

    /// 重新获取保留仍在列表中的草稿选择；新条目按当前配置初始化。
    static func selectionAfterRefetch(models: [String], previouslyDisplayed: Set<String>,
                                      previousSelection: Set<String>, existing: Set<String>) -> Set<String> {
        var result = Set<String>()
        for model in models {
            if previouslyDisplayed.contains(model) {
                if previousSelection.contains(model) { result.insert(model) }
            } else if existing.contains(model) {
                result.insert(model)
            }
        }
        return result
    }

    static func hasPendingChanges(selected: Set<String>, choices: Set<String>, existing: Set<String>) -> Bool {
        selected != choices.intersection(existing)
    }
}

@MainActor
private final class ModelCatalogDraft: ObservableObject {
    @Published var models: [String] = []
    @Published var selected = Set<String>()
    @Published var error: String?
    @Published var applyError: String?
    @Published var loading = true
}

private struct ModelCatalogSheet: View {
    @ObservedObject var store: ConfigStore
    let provider: String
    let remote: RemoteModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft = ModelCatalogDraft()

    private var existingModelIDs: Set<String> {
        Set(store.config.remotes.filter { splitProviderModel($0.name).provider == provider }.map(\.model))
    }

    private var choices: Set<String> { Set(draft.models) }
    private var canApply: Bool {
        !draft.loading && draft.error == nil && !draft.models.isEmpty
            && ModelCatalogSelection.hasPendingChanges(selected: draft.selected,
                                                        choices: choices,
                                                        existing: existingModelIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("获取模型列表 · \(provider)").font(.title2.bold())
            Text("勾选加入本地模型库；取消勾选会删除本地已有条目；接口未返回的模型保持不变。")
                .font(.callout).foregroundStyle(.secondary)
            if draft.loading {
                ProgressView("正在获取模型列表…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = draft.error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.title)
                    Text(error)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if draft.models.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.title)
                    Text("供应商未返回任何模型")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(draft.models, id: \.self) { model in
                    ModelSelectionToggle(model: model, selection: $draft.selected)
                }
                Text("已返回 \(draft.models.count) 个模型；勾选加入，取消勾选移除。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let applyError = draft.applyError {
                Text(applyError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("重新获取") { Task { await fetch() } }.disabled(draft.loading)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用更改") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
            }
        }
        .padding(20)
        .frame(width: 560, height: 550)
        .task { await fetch() }
        .onChange(of: draft.selected) { _ in draft.applyError = nil }
    }

    /// 重新获取只更新草稿视图：已展示过的 ID 沿用用户的勾选，新 ID 按当前配置初始化；不写配置。
    private func fetch() async {
        let previouslyDisplayed = Set(draft.models)
        let previousSelection = draft.selected
        draft.loading = true
        draft.error = nil
        draft.applyError = nil
        do {
            let fetched = try await ProviderModelCatalog.fetch(
                for: remote, settings: store.config.extensions, registry: store.registry)
            draft.models = fetched
            draft.selected = previouslyDisplayed.isEmpty
                ? ModelCatalogSelection.initialSelection(models: fetched, existing: existingModelIDs)
                : ModelCatalogSelection.selectionAfterRefetch(
                    models: fetched,
                    previouslyDisplayed: previouslyDisplayed,
                    previousSelection: previousSelection,
                    existing: existingModelIDs)
        } catch {
            draft.error = error.localizedDescription
        }
        draft.loading = false
    }

    private func apply() {
        guard canApply else { return }
        if let error = store.applyModelCatalogSelection(provider: provider, choices: choices,
                                                       selected: draft.selected) {
            draft.applyError = error
            return
        }
        dismiss()
    }
}
