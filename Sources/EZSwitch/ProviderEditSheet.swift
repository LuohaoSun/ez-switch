import SwiftUI

@MainActor
final class ProviderDraft: ObservableObject {
    @Published var name: String
    @Published var endpoints: APIEndpointSettings
    @Published var apiKey: String
    @Published var headers: String
    @Published var changeHeaders = false
    @Published var error: String?
    let mixedEndpoints: Bool
    let mixedKey: Bool
    let mixedHeaders: Bool

    init(group: RemoteGroup) {
        name = group.provider
        let first = group.remotes.first
        mixedEndpoints = group.remotes.contains { $0.apiEndpoints != first?.apiEndpoints }
        mixedKey = group.remotes.contains { $0.apiKey != first?.apiKey }
        mixedHeaders = group.remotes.contains { $0.extraHeaders != first?.extraHeaders }
        endpoints = first?.apiEndpoints ?? APIEndpointSettings(
            chat: .disabled, responses: .disabled, messages: .disabled)
        apiKey = first?.apiKey ?? ""
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
        _draft = StateObject(wrappedValue: ProviderDraft(group: group))
    }

    private var headersValue: [String: String]? {
        guard let data = draft.headers.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }

    /// 非 `.api` 记录的连接由扩展提供：无用户可填的 Base URL / API Key / 请求头。
    /// source 未在注册表中也按此处理（缺失扩展时仍是仅名称编辑器）。
    private var connectorSource: RemoteSource? {
        guard let source = group.remotes.first?.source, source != .api else { return nil }
        return source
    }
    private var isConnectorManaged: Bool { connectorSource != nil }
    /// 展示名优先取扩展注册；缺失注册时退回 `source.rawValue`，绝不暴露配置键或地址。
    private var connectorName: String {
        connectorSource.flatMap { store.registry.connector(for: $0)?.displayName }
            ?? connectorSource?.rawValue ?? ""
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
                if isConnectorManaged {
                    connectorConnectionSection
                } else {
                    endpointsSection
                    credentialsSection
                    headersSection
                }
                Section("应用范围") {
                    Text(group.remotes.map(\.model).joined(separator: "、"))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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

    /// 连接器供应商：native 接口编辑器整块替换为一行说明，登录/连接在“扩展”页管理。
    @ViewBuilder
    private var connectorConnectionSection: some View {
        Section("连接") {
            Text("连接由扩展管理")
            Text("\(connectorName) 供应商通过其扩展连接，凭据由扩展持有，无需填写 Base URL 或 API Key；请在“扩展”页管理登录、连接与模型同步。")
                .font(.caption).foregroundStyle(.secondary)
            Text("该供应商的模型由扩展提供，本页只修改供应商名称。")
                .font(.caption).foregroundStyle(.secondary)
        }
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
        // 连接器供应商只改名称，native 端点/凭据/请求头保持原样（传 nil 不覆盖）。
        draft.error = store.updateProvider(group.provider, name: draft.name,
            apiEndpoints: isConnectorManaged ? nil : ConfigStore.normalizedEndpoints(draft.endpoints),
            apiKey: isConnectorManaged ? nil : draft.apiKey,
            extraHeaders: isConnectorManaged ? nil : (draft.changeHeaders ? headersValue : nil))
        if draft.error == nil {
            onSaved(draft.name.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        }
    }
}
