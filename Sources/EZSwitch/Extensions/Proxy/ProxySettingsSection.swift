import SwiftUI

/// 出站代理扩展卡片：主开关在标题，展开体里是代理地址与走代理的来源名单。
struct ProxySettingsSection: View {
    @ObservedObject var store: ConfigStore
    @StateObject private var draft = ProxySettingsDraft()

    private var isEnabled: Bool { store.config.extensions.outboundProxy.enabled }
    private var savedAddress: String { store.config.extensions.outboundProxy.address }
    private var selectedProviders: Set<String> { store.config.extensions.outboundProxy.providerNames }
    private var selectedConnectorSources: Set<String> {
        store.config.extensions.outboundProxy.connectorSources
    }

    /// 只列原生 HTTP 供应商；连接器供应商由下方连接器行表示，不重复。
    private var nativeGroups: [RemoteGroup] {
        store.groupedRemotes().filter { group in group.remotes.allSatisfy { $0.source.isAPI } }
    }
    private var connectors: [ConnectorDefinition] { store.registry.registeredConnectors }

    var body: some View {
        ExtensionCard(
            title: "出站代理",
            systemImage: "network",
            summary: "通过指定代理连接所选供应商。",
            isEnabled: Binding(
                get: { isEnabled },
                set: { draft.error = store.setOutboundProxyEnabled($0) }
            )
        ) {
            VStack(alignment: .leading, spacing: 14) {
                addressField
                nativeProviderList
                connectorList

                if let error = draft.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }

                footnotes
            }
        }
    }

    // MARK: 代理地址

    private var addressField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("代理地址")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("代理地址", text: addressBinding,
                          prompt: Text(verbatim: "http://127.0.0.1:7890"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                Button("保存") { saveAddress() }
                    .disabled(!addressDirty)
            }
        }
    }

    /// 失焦不落盘：只有点「保存」才提交，草稿与已保存值不同才可点。
    private var addressBinding: Binding<String> {
        Binding(
            get: { draft.addressDraft ?? savedAddress },
            set: { draft.addressDraft = $0 }
        )
    }

    private var addressDirty: Bool {
        guard let value = draft.addressDraft else { return false }
        return value != savedAddress
    }

    private func saveAddress() {
        guard let value = draft.addressDraft else { return }
        if let message = store.setOutboundProxyAddress(value) {
            draft.error = message
        } else {
            draft.addressDraft = nil
            draft.error = nil
        }
    }

    // MARK: 名单

    @ViewBuilder
    private var nativeProviderList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("供应商")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if nativeGroups.isEmpty {
                Text("暂无供应商，请先在“供应商与路由”中添加。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(nativeGroups) { group in
                    Toggle(group.provider, isOn: providerBinding(group.provider))
                        .toggleStyle(.checkbox)
                }
            }
        }
    }

    @ViewBuilder
    private var connectorList: some View {
        if !connectors.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("连接器")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(connectors, id: \.source.rawValue) { definition in
                    connectorRow(definition)
                }
            }
        }
    }

    /// 不支持代理的连接器禁止新勾选，已勾选的仍可取消。
    private func connectorRow(_ definition: ConnectorDefinition) -> some View {
        let selected = selectedConnectorSources.contains(definition.source.rawValue)
        let unsupported = !definition.supportsOutboundProxy
        return VStack(alignment: .leading, spacing: 2) {
            Toggle(connectorLabel(definition), isOn: connectorBinding(definition))
                .toggleStyle(.checkbox)
                .disabled(unsupported && !selected)
            if unsupported {
                Text("该连接器不支持出站代理")
                    .font(.caption)
                    .foregroundStyle(selected ? Color.orange : Color.secondary)
            }
        }
    }

    /// 展示名；已绑定供应商名不同时附注一次。
    private func connectorLabel(_ definition: ConnectorDefinition) -> String {
        let bound = store.config.extensions
            .connectorSettings(for: definition.settingsKey).providerName
        guard let bound, bound != definition.displayName else { return definition.displayName }
        return "\(definition.displayName)（当前供应商：\(bound)）"
    }

    private func providerBinding(_ provider: String) -> Binding<Bool> {
        Binding(
            get: { selectedProviders.contains(provider) },
            set: { draft.error = store.setOutboundProxyProvider(provider, selected: $0) }
        )
    }

    private func connectorBinding(_ definition: ConnectorDefinition) -> Binding<Bool> {
        Binding(
            get: { selectedConnectorSources.contains(definition.source.rawValue) },
            set: { draft.error = store.setOutboundProxyConnector(definition.source, selected: $0) }
        )
    }

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !connectors.isEmpty {
                Text("修改代理会重启受影响的连接器组件，可能中断进行中的工具会话。")
            }
            Text("暂不支持代理认证与 PAC。")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 代理卡片自身的可变 UI 状态（地址草稿、写入错误）。
@MainActor
final class ProxySettingsDraft: ObservableObject {
    @Published var addressDraft: String?
    @Published var error: String?
}

extension ProxyExtension {
    /// 由 `BuiltinExtensions.panes` 统一挂载；`ProxyExtension` 本体由扩展目录定义。
    @MainActor static var pane: ExtensionPaneEntry {
        ExtensionPaneEntry(id: "outboundProxy") { store, _ in
            AnyView(ProxySettingsSection(store: store))
        }
    }
}
