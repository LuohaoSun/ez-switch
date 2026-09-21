import SwiftUI
import AppKit

// MARK: - 供应商页

/// 供应商页的可变 UI 状态：搜索词 + 当前编辑的 sheet 目标
@MainActor
final class RemotesViewDraft: ObservableObject {
    @Published var query = ""
    @Published var newModelTemplate: RemoteModel?
    @Published var target: RemoteEditTarget?
    @Published var provider: RemoteGroup?
    @Published var selection: RemoteListSelection?
    @Published var deletion: RemoteModel?
    @Published var providerDeletion: RemoteGroup?
    @Published var confirmDelete = false

    init() {
        if let provider = UserDefaults.standard.string(forKey: "selectedProvider") {
            selection = .provider(provider)
        }
    }
}

struct RemoteEditTarget: Identifiable {
    let remote: RemoteModel?
    var id: String { remote?.id.uuidString ?? "new" }
}

private enum RemoteActionTarget {
    case provider(RemoteGroup)
    case model(RemoteModel)
}

enum RemoteListSelection: Hashable {
    case provider(String)
    case model(UUID)
}

struct RemotesView: View {
    @ObservedObject var store: ConfigStore
    @StateObject private var ui = RemotesViewDraft()

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("供应商").font(.headline)
                    Spacer()
                    Text("\(visibleGroups.count)").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 16).padding(.top, 20)
                List(selection: providerSelection) {
                    ForEach(visibleGroups) { group in
                        HStack(spacing: 8) {
                            Text(group.provider).lineLimit(1).truncationMode(.middle)
                                .help(group.provider)
                            Spacer(minLength: 4)
                            if group.remotes.contains(where: \.needsCredentials) {
                                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                                    .help("存在待配置凭据")
                            }
                            Text("\(group.remotes.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        .modifier(NativeListRow())
                        .tag(group.provider)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .onDeleteCommand { requestDelete() }
            }
            .frame(width: 260)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if let group = currentGroup {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.provider).font(.title2.bold()).lineLimit(1)
                            Text(providerAddress).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(providerAddress)
                            Text("\(group.remotes.count) 个匹配模型 / 共 \(allCurrentRemotes.count) 个")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(20)
                    List(selection: modelSelection) {
                        ForEach(group.remotes) { remote in row(for: remote) }
                    }.listStyle(.inset)
                        .onDeleteCommand { requestDelete() }
                } else {
                    EmptyState(title: store.config.remotes.isEmpty ? "添加第一个供应商" : "没有匹配的模型",
                               detail: store.config.remotes.isEmpty ? "点击右上角添加供应商及其第一个模型。" : "尝试其他搜索词。",
                               symbol: "server.rack")
                    Spacer()
                }
            }.frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: ui.query) { _ in reconcileSelection() }
        .onChange(of: store.config.remotes) { _ in reconcileSelection() }
        .onChange(of: store.config.fakes) { _ in reconcileSelection() }
        .searchable(text: $ui.query, prompt: "搜索所有供应商、模型或 URL")
        .navigationTitle("供应商")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { addItem() } label: {
                    Label(isModelTarget ? "添加模型" : "添加供应商", systemImage: "plus")
                }.help(isModelTarget ? "在当前供应商下添加模型" : "添加供应商")
                Button { editSelected() } label: {
                    Label(isModelTarget ? "编辑模型" : "编辑供应商", systemImage: "pencil")
                }.disabled(actionTarget == nil)
                    .help(isModelTarget ? "编辑选中的模型" : "编辑选中的供应商")
                Button { requestDelete() } label: {
                    Label(isModelTarget ? "删除模型" : "删除供应商", systemImage: "trash")
                }.disabled(actionTarget == nil)
                    .help(isModelTarget ? "删除选中的模型" : "删除选中的供应商")
            }
        }
        .sheet(item: $ui.provider) { group in
            ProviderEditSheet(store: store, group: group) { name in
                ui.selection = .provider(name)
                UserDefaults.standard.set(name, forKey: "selectedProvider")
            }.id(group.id)
        }
        .sheet(item: $ui.target) { t in
            RemoteEditSheet(store: store, source: t.remote, template: ui.newModelTemplate)
                .id(t.id)   // 换条目时重建 draft
        }
        .alert(Text(deletionTitle), isPresented: $ui.confirmDelete) {
            Button("取消", role: .cancel) {
                ui.deletion = nil
                ui.providerDeletion = nil
            }
            Button("删除", role: .destructive) {
                if let remote = ui.deletion {
                    store.removeRemote(id: remote.id)
                } else if let provider = ui.providerDeletion {
                    store.removeProvider(provider.provider)
                    UserDefaults.standard.removeObject(forKey: "selectedProvider")
                }
                ui.selection = nil
                ui.deletion = nil
                ui.providerDeletion = nil
            }
        } message: {
            Text(deleteMessage)
        }
    }

    private var usedIDs: Set<UUID> { Set(store.config.fakes.compactMap(\.remoteID)) }

    private var visibleGroups: [RemoteGroup] {
        store.remoteGroups(matching: ui.query)
    }

    private var currentGroup: RemoteGroup? {
        switch ui.selection {
        case .provider(let provider):
            return visibleGroups.first { $0.provider == provider } ?? visibleGroups.first
        case .model(let id):
            return visibleGroups.first { group in group.remotes.contains { $0.id == id } }
                ?? visibleGroups.first
        case nil:
            return visibleGroups.first
        }
    }

    private var providerSelection: Binding<String?> {
        Binding(get: {
            if case .provider(let provider) = ui.selection { return provider }
            return nil
        }, set: { value in
            guard let value else {
                if case .provider = ui.selection { ui.selection = nil }
                return
            }
            ui.selection = .provider(value)
            UserDefaults.standard.set(value, forKey: "selectedProvider")
        })
    }

    private var modelSelection: Binding<UUID?> {
        Binding(get: {
            if case .model(let id) = ui.selection { return id }
            return nil
        }, set: { value in
            guard let value else {
                if case .model = ui.selection { ui.selection = nil }
                return
            }
            ui.selection = .model(value)
        })
    }

    private var allCurrentRemotes: [RemoteModel] {
        guard let name = currentGroup?.provider else { return [] }
        return allProviderRemotes(name)
    }

    private var providerAddress: String {
        let summaries = Set(allCurrentRemotes.map(\.endpointSummary))
        return summaries.count == 1 ? summaries.first! : "\(summaries.count) 种协议配置 · 编辑供应商可统一设置"
    }

    private var actionTarget: RemoteActionTarget? {
        switch ui.selection {
        case .provider(let provider):
            guard visibleGroups.contains(where: { $0.provider == provider }) else { return nil }
            return .provider(RemoteGroup(provider: provider, remotes: allProviderRemotes(provider)))
        case .model(let id):
            guard visibleGroups.contains(where: { group in group.remotes.contains { $0.id == id } }),
                  let remote = store.config.remotes.first(where: { $0.id == id })
            else { return nil }
            return .model(remote)
        case nil:
            return nil
        }
    }

    private var isModelTarget: Bool {
        if case .model = actionTarget { return true }
        return false
    }

    private func addItem() {
        switch actionTarget {
        case .model:
            ui.newModelTemplate = allCurrentRemotes.first
        case .provider, nil:
            ui.newModelTemplate = nil
        }
        ui.target = RemoteEditTarget(remote: nil)
    }

    private func editSelected() {
        switch actionTarget {
        case .provider(let group):
            ui.provider = group
        case .model(let remote):
            ui.target = RemoteEditTarget(remote: remote)
        case nil:
            break
        }
    }

    private func requestDelete() {
        switch actionTarget {
        case .provider(let group):
            ui.providerDeletion = group
            ui.deletion = nil
        case .model(let remote):
            ui.deletion = remote
            ui.providerDeletion = nil
        case nil:
            return
        }
        ui.confirmDelete = true
    }

    private func reconcileSelection() {
        switch ui.selection {
        case .provider(let provider):
            if !visibleGroups.contains(where: { $0.provider == provider }) { ui.selection = nil }
        case .model(let id):
            if !visibleGroups.contains(where: { group in group.remotes.contains { $0.id == id } }) {
                ui.selection = nil
            }
        case nil:
            break
        }
    }

    private func allProviderRemotes(_ provider: String) -> [RemoteModel] {
        store.config.remotes.filter { splitProviderModel($0.name).provider == provider }
    }

    private var deletionTitle: String {
        ui.providerDeletion == nil ? "删除选中的模型？" : "删除选中的供应商？"
    }

    private var deleteMessage: String {
        if let provider = ui.providerDeletion {
            let ids = Set(provider.remotes.map(\.id))
            let routes = store.config.fakes.filter { $0.remoteID.map(ids.contains) == true }
                .map(\.fakeModelID)
            let scope = "删除供应商 \(provider.provider) 及其 \(provider.remotes.count) 个模型。"
            return scope + (routes.isEmpty
                ? "没有路由引用这些模型。"
                : "以下路由将失去目标：\(routes.joined(separator: "、"))。")
        }
        guard let remote = ui.deletion else { return "" }
        let routes = store.config.fakes.filter { $0.remoteID == remote.id }
            .map(\.fakeModelID)
        return "删除 \(remote.routeLabel)。" + (routes.isEmpty
            ? "此模型未被路由引用，其他模型会保留。"
            : "以下路由将失去目标：\(routes.joined(separator: "、"))。")
    }

    @ViewBuilder
    private func row(for remote: RemoteModel) -> some View {
        HStack(spacing: 14) {
            Text(remote.model)
                .font(.system(.body, design: .monospaced).weight(.medium))
                .lineLimit(1).truncationMode(.middle)
                .help(([remote.model, remote.endpointSummary] + remote.endpointBaseURLs).joined(separator: "\n"))
                .layoutPriority(1)
            Spacer(minLength: 8)
            if usedIDs.contains(remote.id) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                    .help("用于：" + store.config.fakes.filter { $0.remoteID == remote.id }
                        .map(\.fakeModelID).joined(separator: "、"))
                    .accessibilityLabel("已用于路由")
            }
            if remote.needsCredentials {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange).help("凭据待配置")
                    .accessibilityLabel("凭据待配置")
            }
        }
        .modifier(NativeListRow())
        .tag(remote.id)
        .contextMenu {
            Button("编辑…") { ui.target = RemoteEditTarget(remote: remote) }
            Button("复制模型 ID") { copyText(remote.model) }
            Divider()
            Button("删除…", role: .destructive) {
                ui.selection = .model(remote.id)
                requestDelete()
            }
        }
    }

    /// 行尾只显示 host（拿不到 host 时退回整串）
    static func host(of baseURL: String) -> String {
        if let u = URL(string: baseURL), let h = u.host, !h.isEmpty { return h }
        return baseURL
    }
}

// MARK: - 远端编辑 sheet

/// 额外请求头的一行（按行编辑，保存时再合成字典）
struct HeaderRow: Identifiable {
    let id = UUID()
    var key: String
    var value: String
}

@MainActor
final class RemoteEditDraft: ObservableObject {
    @Published var providerName: String
    @Published var model: String
    @Published var endpoints: APIEndpointSettings
    @Published var apiKey: String
    @Published var headers: [HeaderRow]
    @Published var revealKey = false
    @Published var confirmDelete = false
    @Published var error: String?

    init(source: RemoteModel?) {
        let split = splitProviderModel(source?.name ?? "")
        providerName = source == nil ? "" : split.provider
        model = source?.model ?? ""
        endpoints = source?.apiEndpoints ?? APIEndpointSettings(
            chat: .disabled, responses: .disabled, messages: .disabled)
        apiKey = source?.apiKey ?? ""
        headers = (source?.extraHeaders ?? [:])
            .sorted { $0.key < $1.key }
            .map { HeaderRow(key: $0.key, value: $0.value) }
    }
}

struct RemoteEditSheet: View {
    @ObservedObject var store: ConfigStore
    let source: RemoteModel?
    private let managesConnection: Bool
    private let addingModelToProvider: Bool

    @StateObject private var draft: RemoteEditDraft
    @Environment(\.dismiss) private var dismiss

    init(store: ConfigStore, source: RemoteModel?, template: RemoteModel? = nil) {
        self.store = store
        self.source = source
        self.managesConnection = source == nil && template == nil
        self.addingModelToProvider = source == nil && template != nil
        let initial = RemoteEditDraft(source: source ?? template)
        if source == nil { initial.model = "" }
        _draft = StateObject(wrappedValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("供应商") {
                    if managesConnection {
                        TextField("名称", text: $draft.providerName, prompt: Text(verbatim: "Krill"))
                    } else {
                        Text(draft.providerName)
                            .textSelection(.enabled)
                    }
                }

                Section(managesConnection ? "首个模型" : "模型") {
                    TextField("模型 ID", text: $draft.model)
                        .font(.system(.body, design: .monospaced))

                    if draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("模型 ID 不能为空").font(.caption).foregroundStyle(.red)
                    }
                }

                if managesConnection {
                    Section("接口协议") {
                        EndpointSettingsEditor(settings: $draft.endpoints)
                        Text("启用哪些协议就填写对应 Base URL；Base URL 是完整前缀，路由器只追加协议相对路径。")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Section("凭据") {
                        HStack(spacing: 8) {
                            if draft.revealKey {
                                TextField("API Key", text: $draft.apiKey)
                                    .font(.system(.body, design: .monospaced))
                            } else {
                                SecureField("API Key", text: $draft.apiKey)
                                    .font(.system(.body, design: .monospaced))
                            }
                            Button {
                                draft.revealKey.toggle()
                            } label: {
                                Image(systemName: draft.revealKey ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(draft.revealKey ? "隐藏 key" : "显示 key")
                        }
                    }

                    Section("额外请求头") {
                        ForEach($draft.headers) { $row in
                            HStack(spacing: 8) {
                                TextField("Header", text: $row.key)
                                    .font(.system(.caption, design: .monospaced))
                                TextField("值", text: $row.value)
                                    .font(.system(.caption, design: .monospaced))
                                Button {
                                    draft.headers.removeAll { $0.id == row.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("删除这一行")
                            }
                        }
                        Button("＋ 添加请求头") {
                            draft.headers.append(HeaderRow(key: "", value: ""))
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let err = errorText ?? draft.error {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }

            Divider()
            footer
        }
        .frame(width: 540)
        .frame(minHeight: managesConnection ? 760 : 340)
        .alert("删除这个供应商模型？", isPresented: $draft.confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let src = source { store.removeRemote(id: src.id) }
                dismiss()
            }
        } message: {
            Text(verbatim: deleteMessage)
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

    /// 引用这个远端的路由。
    private var referencingFakes: [String] {
        guard let src = source else { return [] }
        return store.config.fakes
            .filter { $0.remoteID == src.id }
            .map(\.fakeModelID)
    }

    private var deleteMessage: String {
        let list = referencingFakes
        if list.isEmpty { return "此模型未被路由引用，其他供应商模型会保留。" }
        return "删除后以下路由将失去目标：\(list.joined(separator: ", "))"
    }

    /// 即时校验（红字）；nil = 可以保存
    private var errorText: String? {
        if draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "模型 ID 不能为空"
        }
        if managesConnection,
           let error = ConfigStore.validateEndpoints(ConfigStore.normalizedEndpoints(draft.endpoints)) {
            return error
        }
        return nil
    }

    private func save() {
        guard errorText == nil else { return }
        draft.error = nil
        let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = draft.providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        // provider 空或与 model 同名时，名字就是 model
        let name = (provider.isEmpty || provider == model) ? model : "\(provider) · \(model)"
        if let src = source {
            draft.error = store.updateModel(id: src.id, model: model)
        } else if addingModelToProvider {
            draft.error = store.addModel(provider: provider, model: model)
        } else {
            var parsed: [String: String] = [:]
            for h in draft.headers {
                let k = h.key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !k.isEmpty else { continue }   // 跳过空 key
                parsed[k] = h.value                 // 重名后者覆盖
            }
            draft.error = store.addRemote(RemoteModel(id: UUID(), name: name,
                                                      apiKey: draft.apiKey, model: model,
                                                      extraHeaders: parsed,
                                                      apiEndpoints: ConfigStore.normalizedEndpoints(draft.endpoints)))
        }
        if draft.error == nil { dismiss() }
    }
}
