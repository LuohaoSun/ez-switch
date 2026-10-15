import SwiftUI

/// Chat → Responses 扩展页的可变 UI 状态（名单勾选错误）。
@MainActor
final class ExtensionsDraft: ObservableObject {
    @Published var error: String?
}

/// 侧栏「扩展」页：内置 Chat → Responses 转区块，以及由 `BuiltinExtensions.panes`
/// 动态挂载的各连接器区块。本页不引用任何具体连接器类型或字面量。
struct ExtensionsPane: View {
    @ObservedObject var store: ConfigStore
    /// 连接器区块添加供应商成功后跳到“供应商与路由”页；容器（SettingsView）负责切换侧栏。
    var onOpenSuppliers: (() -> Void)? = nil

    @StateObject private var draft = ExtensionsDraft()

    private var isEnabled: Bool { store.config.extensions.chatToResponses.enabled }
    private var selectedProviders: Set<String> { store.config.extensions.chatToResponses.providerNames }
    private var groups: [RemoteGroup] { store.groupedRemotes() }
    /// Chat → Responses 只作用于普通 API 供应商；连接器供应商的 Chat/Responses 由
    /// 连接器自身处理，不出现在转换名单里（它也没有可填的 Base URL）。
    private var chatEligibleGroups: [RemoteGroup] {
        groups.filter { group in group.remotes.allSatisfy { $0.source == .api } }
    }

    var body: some View {
        Form {
            chatToResponsesSection
            ForEach(BuiltinExtensions.panes) { entry in
                entry.makeView(store) { onOpenSuppliers?() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("扩展")
    }

    // MARK: Chat → Responses

    @ViewBuilder
    private var chatToResponsesSection: some View {
        Section {
            Toggle("启用", isOn: Binding(
                get: { isEnabled },
                set: { store.setChatToResponsesEnabled($0) }
            ))
            .toggleStyle(.switch)

            Text("将所选供应商的 Responses 请求转到其 Chat 接口。")
                .font(.caption).foregroundStyle(.secondary)

            chatCompatibilityDisclosure
        } header: {
            Text("Chat → Responses")
        } footer: {
            Text("关闭总开关不会清除下面的选择。")
        }

        Section("应用到供应商") {
            if groups.isEmpty {
                Text("暂无供应商，请先在“供应商与路由”中添加。")
                    .foregroundStyle(.secondary)
            } else if chatEligibleGroups.isEmpty {
                Text("当前只有连接器供应商；其 Chat / Responses 由连接器处理，无需在此转换。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(chatEligibleGroups) { group in
                    providerRow(group)
                }
            }
            if let error = draft.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    /// 缺 Chat 时不可新选，但已选的仍可解除。
    private func providerRow(_ group: RemoteGroup) -> some View {
        let selected = selectedProviders.contains(group.provider)
        let reason = store.chatToResponsesUnavailableReason(for: group.provider)

        return VStack(alignment: .leading, spacing: 2) {
            Toggle(group.provider, isOn: selectionBinding(group.provider))
                .toggleStyle(.checkbox)
                .disabled(!selected && reason != nil)
            if let reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.orange : Color.secondary)
            }
        }
    }

    private func selectionBinding(_ provider: String) -> Binding<Bool> {
        Binding(
            get: { selectedProviders.contains(provider) },
            set: { value in
                draft.error = store.setChatToResponsesProvider(provider, selected: value)
            }
        )
    }

    @ViewBuilder
    private var chatCompatibilityDisclosure: some View {
        DisclosureGroup("兼容范围") {
            VStack(alignment: .leading, spacing: 4) {
                Text("转换由随附的 Responses 桥接完成，要求客户端携带完整对话历史。")
                Text("服务端状态不支持：previous_response_id、conversation，以及服务端压缩（compaction_trigger / compaction）会被拒绝，请改用本地压缩。")
                Text("转发复用所选供应商已配置的 Chat Completions Base URL 与凭据。")
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
