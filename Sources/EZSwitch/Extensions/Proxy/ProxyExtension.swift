import Foundation

/// 通用出站代理扩展。策略求值、选择生命周期与失效清理都集中在此目录内；
/// 主干只经 `BuiltinExtensions` 的通用组合点调用，不出现本扩展细节。
enum ProxyExtension {
    /// 扩展配置键（`config.json` 的 extensions 下该键以 opaque 节点保存）。
    static let settingsKey = "outboundProxy"

    /// 连接器来源是否声明支持出站代理。
    static func supports(source: RemoteSource, registry: ExtensionRegistry) -> Bool {
        registry.connector(for: source)?.supportsOutboundProxy == true
    }

    /// 地址校验：nil = 可用，否则返回可展示原因。
    static func validate(_ address: String) -> String? {
        do {
            _ = try OutboundPolicy.validatedProxyURL(address)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "代理地址无效"
        }
    }

    // MARK: 策略求值

    /// 候选远端的出站策略：原生按供应商名，连接器按来源标识。
    static func policy(remote: RemoteModel, settings: ExtensionSettings) -> OutboundPolicy {
        remote.source.isAPI
            ? policy(provider: splitProviderModel(remote.name).provider, settings: settings)
            : policy(source: remote.source, settings: settings)
    }

    /// 连接器来源的出站策略（供应商登录/添加前即可用 source 选定）。
    static func policy(source: RemoteSource, settings: ExtensionSettings) -> OutboundPolicy {
        guard !source.isAPI else { return .direct }
        return selectedPolicy(settings) { node in
            rawStrings(node[Key.connectorSources])?.contains(source.rawValue) == true
        }
    }

    /// 原生供应商的出站策略（按供应商名选择）。
    static func policy(provider: String, settings: ExtensionSettings) -> OutboundPolicy {
        selectedPolicy(settings) { node in
            rawStrings(node[Key.providerNames])?.contains(provider) == true
        }
    }

    /// fail-closed：直接读 raw 的 enabled / 选中集合 / 地址，译文结构损坏时不退化成直连。
    private static func selectedPolicy(_ settings: ExtensionSettings,
                                       _ isSelected: ([String: ExtensionJSONValue]) -> Bool) -> OutboundPolicy {
        guard let node = settings.extensionValue(for: settingsKey)?.objectValue,
              rawBool(node[Key.enabled]), isSelected(node) else {
            return .direct
        }
        return resolve(node[Key.address])
    }

    private static func resolve(_ value: ExtensionJSONValue?) -> OutboundPolicy {
        guard case .string(let address)? = value,
              !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalid("代理地址为空")
        }
        do { return .proxy(try OutboundPolicy.validatedProxyURL(address)) }
        catch { return .invalid(error.localizedDescription) }
    }

    // MARK: 生命周期（由 BuiltinExtensions 通用 hook 转发）

    static func providerRenamed(from old: String, to new: String, in config: inout AppConfig) {
        var proxy = config.extensions.outboundProxy
        guard proxy.providerNames.contains(old) else { return }
        proxy.providerNames.remove(old)
        proxy.providerNames.insert(new)
        config.extensions.outboundProxy = proxy
    }

    static func providerRemoved(_ provider: String, in config: inout AppConfig) {
        var proxy = config.extensions.outboundProxy
        guard proxy.providerNames.remove(provider) != nil else { return }
        config.extensions.outboundProxy = proxy
    }

    /// 清理指向已不存在原生供应商的选中项；返回是否改动。
    @discardableResult
    static func prune(_ config: inout AppConfig) -> Bool {
        let native = Set(config.remotes.filter { $0.source.isAPI }
            .map { splitProviderModel($0.name).provider })
        var proxy = config.extensions.outboundProxy
        let pruned = proxy.providerNames.intersection(native)
        guard pruned != proxy.providerNames else { return false }
        proxy.providerNames = pruned
        config.extensions.outboundProxy = proxy
        return true
    }

    // MARK: raw 读取（对损坏结构宽容）

    private enum Key {
        static let enabled = "enabled"
        static let address = "address"
        static let providerNames = "providerNames"
        static let connectorSources = "connectorSources"
    }

    private static func rawBool(_ value: ExtensionJSONValue?) -> Bool {
        if case .bool(let flag) = value { return flag }
        return false
    }

    private static func rawStrings(_ value: ExtensionJSONValue?) -> Set<String>? {
        guard case .array(let items) = value else { return nil }
        return Set(items.compactMap { item in
            if case .string(let text) = item { return text }
            return nil
        })
    }
}
