import SwiftUI

private enum WorkspaceSheet: Identifiable {
    case newProvider
    case provider(String)
    case newModel(UUID)
    case model(UUID)
    case route(UUID?)
    case catalog(String)

    var id: String {
        switch self {
        case .newProvider: return "new-provider"
        case .provider(let name): return "provider-\(name)"
        case .newModel(let id): return "new-model-\(id)"
        case .model(let id): return "model-\(id)"
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
    @Published var sheet: WorkspaceSheet?
    @Published var providerToDelete: String?
    @Published var routeToDelete: UUID?
}

struct RouteWorkspaceView: View {
    @ObservedObject var store: ConfigStore
    @StateObject private var ui = WorkspaceDraft()
    private var groups: [RemoteGroup] { store.remoteGroups(matching: ui.query) }
    private var remoteByID: [UUID: RemoteModel] {
        Dictionary(uniqueKeysWithValues: store.config.remotes.map { ($0.id, $0) })
    }

    var body: some View {
        NativeWorkspaceSplit(suppliers: supplierPanel, routes: routePanel)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .navigationTitle("路由与模型")
        .sheet(item: $ui.sheet) { target in
            switch target {
            case .newProvider:
                RemoteEditSheet(store: store, source: nil)
            case .provider(let name):
                if let group = store.groupedRemotes().first(where: { $0.provider == name }) {
                    ProviderEditSheet(store: store, group: group)
                }
            case .newModel(let id):
                if let template = remoteByID[id] {
                    RemoteEditSheet(store: store, source: nil, template: template)
                }
            case .model(let id):
                if let remote = remoteByID[id] {
                    RemoteEditSheet(store: store, source: remote)
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
                Button { ui.sheet = .newProvider } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("添加供应商")
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
        return DisclosureGroup(isExpanded: Binding(
            get: { !ui.query.isEmpty || !ui.collapsedProviders.contains(group.provider) },
            set: { expanded in
                guard ui.query.isEmpty else { return }
                if expanded { ui.collapsedProviders.remove(group.provider) }
                else { ui.collapsedProviders.insert(group.provider) }
            }
        )) {
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(group.remotes) { remote in
                    HStack(spacing: 8) {
                        Text(remote.model).font(.system(.callout, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        if remote.needsCredentials {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange).help("凭据待配置")
                        }
                    }
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                    .modifier(NativeModelDrag(item: ModelDragItem(id: remote.id)))
                    .modifier(NativeModelDrop(enabled: ui.query.isEmpty, accept: { items in
                        acceptModelDrop(items, provider: group.provider, before: remote.id)
                    }))
                    .contextMenu {
                        Button("编辑模型…") { ui.sheet = .model(remote.id) }
                    }
                    .help("拖到右侧路由添加模型；在左侧拖到其他模型上方调整顺序")
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                Text(group.provider).font(.subheadline.bold()).lineLimit(1)
                    .padding(.trailing, 50)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .modifier(NativeCardDragHandle(id: group.id, enabled: ui.query.isEmpty))
                    .help("展开或收起；拖动标题调整供应商顺序")
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Text("\(group.remotes.count)").font(.caption).foregroundStyle(.secondary)
                Menu {
                    Button("获取模型列表…") { ui.sheet = .catalog(group.provider) }
                    Button("添加模型…") {
                        if let first = group.remotes.first { ui.sheet = .newModel(first.id) }
                    }
                    Button("编辑供应商…") { ui.sheet = .provider(group.provider) }
                    Divider()
                    Button("删除供应商…", role: .destructive) { ui.providerToDelete = group.provider }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).help("管理 \(group.provider)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .animation(.easeInOut(duration: 0.2), value: expanded)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.035), radius: 5, y: 2)
    }

    private func acceptModelDrop(_ items: [ModelDragItem], provider: String, before target: UUID) -> Bool {
        guard ui.query.isEmpty, !items.isEmpty,
              items.allSatisfy({ item in
                  guard let remote = remoteByID[item.id] else { return false }
                  return splitProviderModel(remote.name).provider == provider
              }) else { return false }
        store.moveModels(provider: provider, sources: items.map(\.id), before: target)
        return true
    }

    private var routePanel: some View {
        let modelsByID = remoteByID
        return VStack(alignment: .leading, spacing: 12) {
            ServiceSummary(store: store)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("路由 ID").font(.title2.bold())
                    Text("拖动调整切换顺序；点击模型设为当前。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { ui.sheet = .route(nil) } label: {
                    Label("添加路由", systemImage: "plus")
                }
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
        let ids = fake.orderedRemoteIDs
        let expanded = !ui.collapsedRoutes.contains(fake.id)
        return VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: Binding(
                get: { !ui.collapsedRoutes.contains(fake.id) },
                set: { expanded in
                    if expanded { ui.collapsedRoutes.remove(fake.id) }
                    else { ui.collapsedRoutes.insert(fake.id) }
                }
            )) {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    if ids.isEmpty {
                        dropSlot(fake: fake, index: 0, label: "拖入模型")
                    } else {
                        ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                            if let remote = modelsByID[id] {
                                candidateRow(fake: fake, remote: remote, index: index)
                            }
                        }
                        dropSlot(fake: fake, index: ids.count, label: "拖入模型")
                    }
                }
                .padding(.top, 5)
                .animation(.easeInOut(duration: 0.22), value: ids)
            } label: {
                HStack(spacing: 8) {
                    Text(fake.fakeModelID).font(.system(.headline, design: .monospaced)).lineLimit(1)
                        .padding(.trailing, 145)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .modifier(NativeCardDragHandle(id: fake.id))
                        .help("展开或收起；拖动标题调整路由顺序")
                }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 8) {
                    Toggle("自动切换", isOn: Binding(
                        get: { store.config.fakes.first(where: { $0.id == fake.id })?.autoFallback ?? false },
                        set: { store.setRouteTargets(fakeID: fake.id, remoteIDs: fake.orderedRemoteIDs, autoFallback: $0) }
                    )).toggleStyle(.switch).controlSize(.small)
                    Menu {
                        Button("编辑路由 ID…") { ui.sheet = .route(fake.id) }
                        Button("复制路由 ID") { copyText(fake.fakeModelID) }
                        Divider()
                        Button("删除路由…", role: .destructive) { ui.routeToDelete = fake.id }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            if !expanded {
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    let current = store.router.activeRemoteID(fakeID: fake.id).flatMap { modelsByID[$0] }
                    Text(current.map { "当前 · \($0.routeLabel)" } ?? "未配置模型")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 34).padding(.trailing, 14).padding(.bottom, 12)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: expanded)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.035), radius: 5, y: 2)
    }

    private func candidateRow(fake: FakeModel, remote: RemoteModel, index: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Button {
                store.selectRouteModel(fakeID: fake.id, remoteID: remote.id)
            } label: {
                HStack(spacing: 8) {
                    Text(remote.routeLabel).lineLimit(1).truncationMode(.middle)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    TimelineView(.periodic(from: .now, by: 2)) { _ in
                        if store.router.activeRemoteID(fakeID: fake.id) == remote.id {
                            Label("当前", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.tint)
                                .fixedSize()
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("选择此模型用于后续请求")
            Button {
                let ids = fake.orderedRemoteIDs.filter { $0 != remote.id }
                store.setRouteTargets(fakeID: fake.id, remoteIDs: ids, autoFallback: fake.autoFallback)
            } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).help("从路由移除")

        }
        .padding(.horizontal, 6).padding(.vertical, 8)
        .contentShape(Rectangle())
        .modifier(NativeModelDrag(item: ModelDragItem(id: remote.id)))
        .modifier(NativeModelDrop(accept: { items in
            acceptDrop(items, fakeID: fake.id, before: index)
        }))
        .help("拖动调整尝试顺序，或将左侧模型拖到此位置")
    }

    private func dropSlot(fake: FakeModel, index: Int, label: String) -> some View {
        return HStack {
            Image(systemName: "plus.circle.dashed")
            Text(label)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(Color.secondary.opacity(0.75))
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(Color.primary.opacity(0.12),
                          style: StrokeStyle(lineWidth: 1, dash: [4])))
        .modifier(NativeModelDrop(accept: { items in
            acceptDrop(items, fakeID: fake.id, before: index)
        }))
    }

    private func acceptDrop(_ items: [ModelDragItem], fakeID: UUID, before index: Int) -> Bool {
        guard !items.isEmpty, items.allSatisfy({ remoteByID[$0.id] != nil }),
              let fake = store.config.fakes.first(where: { $0.id == fakeID }) else { return false }
        var seen = Set<UUID>()
        let sources = items.map(\.id).filter { seen.insert($0).inserted }
        let original = fake.orderedRemoteIDs
        var ids = original.filter { !sources.contains($0) }
        let removedBefore = original.prefix(max(0, index)).filter { sources.contains($0) }.count
        let insertion = max(0, min(index - removedBefore, ids.count))
        ids.insert(contentsOf: sources, at: insertion)
        store.setRouteTargets(fakeID: fakeID, remoteIDs: ids, autoFallback: fake.autoFallback)
        return true
    }

}

@MainActor
private final class ModelCatalogDraft: ObservableObject {
    @Published var models: [String] = []
    @Published var selected = Set<String>()
    @Published var error: String?
    @Published var loading = true
}

private struct ModelCatalogSheet: View {
    @ObservedObject var store: ConfigStore
    let provider: String
    let remote: RemoteModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft = ModelCatalogDraft()

    private var existing: Set<String> {
        Set(store.config.remotes.filter { splitProviderModel($0.name).provider == provider }.map(\.model))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("获取模型列表 · \(provider)").font(.title2.bold())
            Text("从供应商接口读取模型 ID，选择要加入本地模型库的条目。")
                .font(.callout).foregroundStyle(.secondary)
            if draft.loading {
                ProgressView("正在获取模型列表…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = draft.error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.title)
                    Text(error)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(draft.models, id: \.self) { model in
                    HStack {
                        ModelSelectionToggle(model: model, selection: $draft.selected)
                        if existing.contains(model) {
                            Text("已添加").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("已返回 \(draft.models.count) 个模型；按需选择，已添加的条目会跳过。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("重新获取") { Task { await fetch() } }.disabled(draft.loading)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("添加所选模型") {
                    for model in draft.selected.sorted() where !existing.contains(model) {
                        _ = store.addModel(provider: provider, model: model)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.selected.subtracting(existing).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 550)
        .task { await fetch() }
    }

    private func fetch() async {
        draft.loading = true
        draft.error = nil
        do {
            draft.models = try await ProviderModelCatalog.fetch(for: remote)
        } catch {
            draft.error = error.localizedDescription
        }
        draft.loading = false
    }
}
