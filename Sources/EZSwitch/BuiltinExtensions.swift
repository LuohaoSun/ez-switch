import SwiftUI

/// The only composition point that names optional connector implementations.
enum BuiltinExtensions {
    static var connectors: [ConnectorDefinition] {
        return []
    }

    @MainActor static var panes: [ExtensionPaneEntry] {
        var entries: [ExtensionPaneEntry] = []
        #if EZSWITCH_PROXY_EXTENSION
        entries.append(ProxyExtension.pane)
        #endif
        return entries
    }

    @MainActor static func start(in store: ConfigStore, runtime: ExtensionRuntime) {
    }

    // MARK: 出站代理组合点（具体策略在扩展目录内实现）

    nonisolated static func outboundPolicy(remote: RemoteModel,
                                           settings: ExtensionSettings) -> OutboundPolicy {
        #if EZSWITCH_PROXY_EXTENSION
        return ProxyExtension.policy(remote: remote, settings: settings)
        #else
        return .direct
        #endif
    }

    nonisolated static func outboundPolicy(source: RemoteSource,
                                           settings: ExtensionSettings) -> OutboundPolicy {
        #if EZSWITCH_PROXY_EXTENSION
        return ProxyExtension.policy(source: source, settings: settings)
        #else
        return .direct
        #endif
    }

    /// 供应商改名后，让各扩展把按名字保存的选择迁移到新名字。
    static func providerRenamed(from old: String, to new: String, in config: inout AppConfig) {
        #if EZSWITCH_PROXY_EXTENSION
        ProxyExtension.providerRenamed(from: old, to: new, in: &config)
        #endif
    }

    /// 供应商删除后，让各扩展清理按名字保存的选择。
    static func providerRemoved(_ provider: String, in config: inout AppConfig) {
        #if EZSWITCH_PROXY_EXTENSION
        ProxyExtension.providerRemoved(provider, in: &config)
        #endif
    }

    /// 外部编辑后清理各扩展的悬空选择；返回是否改动。具体扩展在扩展目录内实现。
    @discardableResult
    static func pruneSelections(_ config: inout AppConfig) -> Bool {
        #if EZSWITCH_PROXY_EXTENSION
        return ProxyExtension.prune(&config)
        #else
        return false
        #endif
    }
}
