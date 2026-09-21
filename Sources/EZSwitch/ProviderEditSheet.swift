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

    private var validation: String? {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "供应商名称不能为空" }
        if let error = ConfigStore.validateEndpoints(ConfigStore.normalizedEndpoints(draft.endpoints)) { return error }
        if draft.changeHeaders && headersValue == nil { return "请求头须为 JSON 对象，名称和值均为字符串" }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("供应商设置").font(.title2.bold())
                Text("三协议连接设置统一应用于 \(group.remotes.count) 个模型，保留各模型 ID 和路由绑定。")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Form {
                Section("供应商") {
                    TextField("名称", text: $draft.name)
                }
                Section("接口协议") {
                    EndpointSettingsEditor(settings: $draft.endpoints)
                    if draft.mixedEndpoints {
                        Text("当前供应商内模型的协议配置不一致；保存后会统一为以上设置。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("Base URL 填完整前缀；路由器只追加协议相对路径。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("凭据") {
                    SecureField("API Key", text: $draft.apiKey, prompt: Text("可留空"))
                    Text(draft.mixedKey
                         ? "当前供应商内模型的 API Key 不一致；保存后会统一为以上值。"
                         : "保存后会统一应用到该供应商全部模型。")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                Button("保存供应商设置") {
                    draft.error = store.updateProvider(group.provider, name: draft.name,
                        apiEndpoints: ConfigStore.normalizedEndpoints(draft.endpoints),
                        apiKey: draft.apiKey,
                        extraHeaders: draft.changeHeaders ? headersValue : nil)
                    if draft.error == nil {
                        onSaved(draft.name.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }.keyboardShortcut(.defaultAction).disabled(validation != nil)
            }.padding(16)
        }.frame(width: 600, height: 760)
    }
}
