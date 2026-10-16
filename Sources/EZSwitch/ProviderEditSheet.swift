import SwiftUI

@MainActor
final class ProviderDraft: ObservableObject {
    @Published var name: String
    @Published var endpoints: APIEndpointSettings
    @Published var apiKey: String
    @Published var headers: String
    @Published var changeHeaders = false
    @Published var error: String?
    /// 连接器供应商的可用协议选择；未配置时视图已回退为 registry 全集。
    @Published var enabledEndpoints: Set<EndpointKind>
    let mixedEndpoints: Bool
    let mixedKey: Bool
    let mixedHeaders: Bool

    init(group: RemoteGroup, enabledEndpoints: Set<EndpointKind> = []) {
        name = group.provider
        let first = group.remotes.first
        mixedEndpoints = group.remotes.contains { $0.apiEndpoints != first?.apiEndpoints }
        mixedKey = group.remotes.contains { $0.apiKey != first?.apiKey }
        mixedHeaders = group.remotes.contains { $0.extraHeaders != first?.extraHeaders }
        endpoints = first?.apiEndpoints ?? APIEndpointSettings(
            chat: .disabled, responses: .disabled, messages: .disabled)
        apiKey = first?.apiKey ?? ""
        self.enabledEndpoints = enabledEndpoints
        let data = try? JSONSerialization.data(withJSONObject: mixedHeaders ? [:] : first?.extraHeaders ?? [:], options: [.prettyPrinted, .sortedKeys])
        headers = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

struct ProviderEditSheet: View {
    @ObservedObject var store: ConfigStore
    let group: RemoteGroup
    let onSaved: (String) -> Void
    @StateObject private var draft: ProviderDraft
    @Environment(\.dismiss) private var dismiss

    init(store: ConfigStore, group: RemoteGroup, onSaved: @escaping (String) -> Void = { _ in }) {
        self.store = store
        self.group = group
        self.onSaved = onSaved
        _draft = StateObject(wrappedValue: ProviderDraft(
            group: group, enabledEndpoints: Self.initialEndpoints(store: store, group: group)))
    }

    /// 未配置时回退为该连接器支持的全部协议。
    private static func initialEndpoints(store: ConfigStore, group: RemoteGroup)
        -> Set<EndpointKind> {
        guard let definition = registeredDefinition(store: store, group: group) else { return [] }
        let stored = store.config.extensions
            .connectorSettings(for: definition.settingsKey).enabledEndpoints
        return (stored ?? definition.endpoints).intersection(definition.endpoints)
    }

    /// 该供应商来源在注册表中的连接器定义；`.api` 或未注册来源为 nil。
    private static func registeredDefinition(store: ConfigStore, group: RemoteGroup)
        -> ConnectorDefinition? {
        guard let source = group.remotes.first?.source, !source.isAPI else { return nil }
        return store.registry.connector(for: source)
    }

    private var headersValue: [String: String]? {
        guard let data = draft.headers.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }

    /// 非 `.api` 记录由扩展提供：无用户可填的 Base URL / API Key / 请求头。
    private var connectorSource: RemoteSource? {
        guard let source = group.remotes.first?.source, source != .api else { return nil }
        return source
    }
    private var isConnectorManaged: Bool { connectorSource != nil }
    /// 缺失扩展时为 nil：协议不可编辑，且不改写其不透明配置。
    private var connectorDefinition: ConnectorDefinition? {
        Self.registeredDefinition(store: store, group: group)
    }

    private var validation: String? {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "供应商名称不能为空" }
        if isConnectorManaged { return nil }
        if let error = ConfigStore.validateEndpoints(ConfigStore.normalizedEndpoints(draft.endpoints)) { return error }
        if draft.changeHeaders && headersValue == nil { return "请求头须为 JSON 对象，名称和值均为字符串" }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("供应商设置").font(.title2.bold())
                Text("连接设置统一应用于 \(group.remotes.count) 个模型，保留各模型 ID 和路由绑定。")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Form {
                Section("供应商") {
                    TextField("名称", text: $draft.name)
                }
                if let definition = connectorDefinition {
                    connectorEndpointsSection(definition)
                } else if !isConnectorManaged {
                    endpointsSection
                    credentialsSection
                    headersSection
                }
            }.formStyle(.grouped)
            if let error = validation ?? draft.error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 20).padding(.bottom, 8)
            }
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存供应商设置") { save() }.keyboardShortcut(.defaultAction).disabled(validation != nil)
            }.padding(16)
        }.frame(width: 600, height: isConnectorManaged ? 420 : 760)
    }

    /// 连接器供应商：按定义列出该来源可用的协议开关，不含 Base URL / API Key / 请求头。
    @ViewBuilder
    private func connectorEndpointsSection(_ definition: ConnectorDefinition) -> some View {
        Section("接口协议") {
            ForEach(EndpointKind.allCases.filter { definition.endpoints.contains($0) }, id: \.self) { kind in
                Toggle(kind.displayName, isOn: connectorEndpointBinding(kind))
                    .toggleStyle(.switch)
            }
        }
    }

    private func connectorEndpointBinding(_ kind: EndpointKind) -> Binding<Bool> {
        Binding(
            get: { draft.enabledEndpoints.contains(kind) },
            set: { enabled in
                if enabled { draft.enabledEndpoints.insert(kind) }
                else { draft.enabledEndpoints.remove(kind) }
            }
        )
    }

    @ViewBuilder
    private var endpointsSection: some View {
        Section("接口协议") {
            EndpointSettingsEditor(settings: $draft.endpoints)
            if draft.mixedEndpoints {
                Text("当前供应商内模型的协议配置不一致；保存后会统一为以上设置。")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Base URL 填完整前缀；路由器只追加协议相对路径。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var credentialsSection: some View {
        Section("凭据") {
            SecureField("API Key", text: $draft.apiKey, prompt: Text("可留空"))
            Text(draft.mixedKey
                 ? "当前供应商内模型的 API Key 不一致；保存后会统一为以上值。"
                 : "保存后会统一应用到该供应商全部模型。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var headersSection: some View {
        Section("额外请求头") {
            Toggle("统一设置请求头", isOn: $draft.changeHeaders)
            if draft.changeHeaders {
                TextEditor(text: $draft.headers)
                    .font(.system(.caption, design: .monospaced)).frame(height: 80)
            } else {
                Text(draft.mixedHeaders ? "各模型请求头不同，保留原值" : "保留现有请求头")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        if connectorDefinition != nil {
            draft.error = store.updateConnectorProvider(
                group.provider, name: draft.name, enabledEndpoints: draft.enabledEndpoints)
        } else {
            draft.error = store.updateProvider(group.provider, name: draft.name,
                apiEndpoints: isConnectorManaged ? nil : ConfigStore.normalizedEndpoints(draft.endpoints),
                apiKey: isConnectorManaged ? nil : draft.apiKey,
                extraHeaders: isConnectorManaged ? nil : (draft.changeHeaders ? headersValue : nil))
        }
        if draft.error == nil {
            onSaved(draft.name.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        }
    }
}
