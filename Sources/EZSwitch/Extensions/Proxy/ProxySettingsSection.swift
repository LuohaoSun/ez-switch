import SwiftUI

/// 出站代理扩展卡片：主开关在标题，展开体是当前系统代理状态与走代理的名单。
struct ProxySettingsSection: View {
    @ObservedObject var store: ConfigStore
    @StateObject private var draft = ProxySettingsDraft()

    private var isEnabled: Bool { store.config.extensions.outboundProxy.enabled }
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
            summary: "勾选的供应商走 macOS 系统代理；未勾选的严格直连。",
            isEnabled: Binding(
                get: { isEnabled },
                set: { draft.error = store.setOutboundProxyEnabled($0) }
            )
        ) {
            VStack(alignment: .leading, spacing: 14) {
                systemProxyRow
                nativeProviderList
                connectorList

                if let error = draft.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }

                footnotes
            }
            .task { refreshSystemProxy() }
            .onChange(of: isEnabled) { _ in refreshSystemProxy() }
        }
    }

    // MARK: 系统代理状态

    private var systemProxyRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("系统代理")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(SystemProxyDescription.text(draft.systemProxy))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Button {
                    refreshSystemProxy()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("重新读取 macOS 系统代理设置")

                Spacer(minLength: 0)
            }
        }
    }

    private func refreshSystemProxy() {
        draft.systemProxy = SystemProxy.current()
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
            Text("跟随 macOS 系统设置（含 PAC 与例外列表）；系统代理未开启时直连，在系统设置里开关代理后新请求即时生效。")
            Text("系统代理若要求账号密码，请求会失败并如实报错，不会偷偷直连。")
            if !connectors.isEmpty {
                Text("修改开关或名单会重启受影响的连接器组件，可能中断进行中的工具会话。")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 系统代理快照的中文描述，供卡片状态行与测试复用。
enum SystemProxyDescription {
    static func text(_ snapshot: SystemProxySnapshot) -> String {
        guard snapshot.isActive else { return "未开启，将直连" }
        var parts: [String] = []
        if let http = snapshot.http { parts.append("HTTP \(endpoint(http))") }
        if let https = snapshot.https, https != snapshot.http { parts.append("HTTPS \(endpoint(https))") }
        if let socks = snapshot.socks { parts.append("SOCKS \(endpoint(socks))") }
        if let pac = snapshot.pacURL {
            parts.append("PAC \(pac.host ?? pac.absoluteString)")
        } else if snapshot.pacEnabled {
            parts.append("PAC（地址不可读）")
        }
        if snapshot.autoDiscovery { parts.append("自动发现（WPAD）") }
        return parts.joined(separator: " · ")
    }

    private static func endpoint(_ value: SystemProxySnapshot.Endpoint) -> String {
        "\(value.host):\(value.port)"
    }
}

/// 代理卡片自身的可变 UI 状态（系统代理快照、写入错误）。
@MainActor
final class ProxySettingsDraft: ObservableObject {
    @Published var systemProxy = SystemProxySnapshot.empty
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
