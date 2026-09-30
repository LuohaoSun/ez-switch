import SwiftUI
import UniformTypeIdentifiers

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
    @Published var dropTarget: String?
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
        HStack(spacing: 0) {
            supplierPanel.frame(minWidth: 260, idealWidth: 305, maxWidth: 350)
            Divider()
            routePanel.frame(minWidth: 440, maxWidth: .infinity)
        }
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
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary).frame(width: 12)
                    Text(group.provider).font(.subheadline.bold()).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { toggleProvider(group.provider) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { toggleProvider(group.provider) }
                .modifier(NativeCardDragHandle(id: group.id, enabled: ui.query.isEmpty))
                .help("展开或收起；拖到其他供应商上方调整顺序")

                Text("\(group.remotes.count)")
                    .font(.caption).foregroundStyle(.secondary)
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
            .padding(.horizontal, 12).padding(.vertical, 10)

            if expanded {
                Divider().padding(.horizontal, 12)
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
                        .padding(.leading, 32).padding(.trailing, 12).padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .onDrag { NSItemProvider(object: remote.id.uuidString as NSString) }
                        .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
                            guard ui.query.isEmpty else { return false }
                            return acceptModelDrop(providers, provider: group.provider, before: remote.id)
                        }
                        .contextMenu {
                            Button("编辑模型…") { ui.sheet = .model(remote.id) }
                        }
                        .help("拖到右侧路由添加模型；在左侧拖到其他模型上方调整顺序")
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.035), radius: 5, y: 2)
    }

    private func toggleProvider(_ provider: String) {
        guard ui.query.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            if ui.collapsedProviders.contains(provider) { ui.collapsedProviders.remove(provider) }
            else { ui.collapsedProviders.insert(provider) }
        }
    }

    private func toggleRoute(_ id: UUID) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if ui.collapsedRoutes.contains(id) { ui.collapsedRoutes.remove(id) }
            else { ui.collapsedRoutes.insert(id) }
        }
    }

    private func acceptModelDrop(_ providers: [NSItemProvider], provider: String, before target: UUID) -> Bool {
        guard let item = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = item.loadObject(ofClass: NSString.self) { object, _ in
            guard let value = object as? String, let source = UUID(uuidString: value) else { return }
            DispatchQueue.main.async {
                guard splitProviderModel(self.remoteByID[source]?.name ?? "").provider == provider else { return }
                store.moveModels(provider: provider, sources: [source], before: target)
            }
        }
        return true
    }

    private var routePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    routeCard(fake)
                }
            }
        }.padding(20)
    }

    private func routeCard(_ fake: FakeModel) -> some View {
        let ids = fake.orderedRemoteIDs
        let expanded = !ui.collapsedRoutes.contains(fake.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary).frame(width: 12)
                    Text(fake.fakeModelID).font(.system(.headline, design: .monospaced)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { toggleRoute(fake.id) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { toggleRoute(fake.id) }
                .modifier(NativeCardDragHandle(id: fake.id))
                .help("展开或收起；拖动卡片调整路由顺序")
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
            .padding(.horizontal, 14).padding(.vertical, 12)

            if expanded {
                Divider().padding(.horizontal, 14)
                VStack(alignment: .leading, spacing: 4) {
                    if ids.isEmpty {
                        dropSlot(fake: fake, index: 0, label: "拖入模型")
                    } else {
                        ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                            if let remote = remoteByID[id] {
                                candidateRow(fake: fake, remote: remote, index: index)
                            }
                        }
                        dropSlot(fake: fake, index: ids.count, label: "拖入模型")
                    }
                }
                .padding(.horizontal, 8).padding(.top, 5).padding(.bottom, 9)
                .animation(.easeInOut(duration: 0.22), value: ids)
            } else {
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    let current = store.router.activeRemoteID(fakeID: fake.id).flatMap { remoteByID[$0] }
                    Text(current.map { "当前 · \($0.routeLabel)" } ?? "未配置模型")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .padding(.leading, 34).padding(.trailing, 14).padding(.bottom, 12)
            }
        }
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
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 2)) { _ in
                        if store.router.activeRemoteID(fakeID: fake.id) == remote.id {
                            Label("当前", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.tint)
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
        .overlay(alignment: .top) {
            if ui.dropTarget == "\(fake.id)-\(index)" {
                Rectangle().fill(Color.accentColor).frame(height: 3)
            }
        }
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(object: remote.id.uuidString as NSString) }
        .onDrop(of: [UTType.plainText.identifier], isTargeted: Binding(
            get: { ui.dropTarget == "\(fake.id)-\(index)" },
            set: { ui.dropTarget = $0 ? "\(fake.id)-\(index)" : nil }
        )) { providers in
            acceptDrop(providers, fakeID: fake.id, before: index)
        }
        .help("拖动调整尝试顺序，或将左侧模型拖到此位置")
    }

    private func dropSlot(fake: FakeModel, index: Int, label: String) -> some View {
        let targeted = ui.dropTarget == "\(fake.id)-\(index)"
        return HStack {
            Image(systemName: "plus.circle.dashed")
            Text(label)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.75))
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(targeted ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12),
                          style: StrokeStyle(lineWidth: 1, dash: [4])))
        .onDrop(of: [UTType.plainText.identifier], isTargeted: Binding(
            get: { ui.dropTarget == "\(fake.id)-\(index)" },
            set: { ui.dropTarget = $0 ? "\(fake.id)-\(index)" : nil }
        )) { providers in
            acceptDrop(providers, fakeID: fake.id, before: index)
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider], fakeID: UUID, before index: Int) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, let remoteID = UUID(uuidString: string) else { return }
            DispatchQueue.main.async {
                guard self.remoteByID[remoteID] != nil,
                      let fake = store.config.fakes.first(where: { $0.id == fakeID }) else { return }
                var ids = fake.orderedRemoteIDs
                let original = ids.firstIndex(of: remoteID)
                if let original { ids.remove(at: original) }
                let insertion = max(0, min(index - (original.map { $0 < index } == true ? 1 : 0), ids.count))
                ids.insert(remoteID, at: insertion)
                store.setRouteTargets(fakeID: fakeID, remoteIDs: ids, autoFallback: fake.autoFallback)
            }
        }
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
                    Button {
                        if draft.selected.contains(model) { draft.selected.remove(model) }
                        else { draft.selected.insert(model) }
                    } label: {
                        HStack {
                            Image(systemName: draft.selected.contains(model) ? "checkmark.circle.fill" : "circle")
                            Text(model).font(.system(.body, design: .monospaced))
                            Spacer()
                            if existing.contains(model) {
                                Text("已添加").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.buttonStyle(.plain)
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
