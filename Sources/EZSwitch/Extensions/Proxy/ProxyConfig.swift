import Foundation

/// 出站代理扩展配置（opaque 扩展键 `outboundProxy`）。未识别字段原样保留。
/// 原生供应商按 providerName 选择、连接器按 source 标识选择（后者改名/未加供应商前都稳定）。
struct OutboundProxySettings: Codable, Equatable {
    var enabled: Bool = false
    var address: String = ""
    var providerNames: Set<String> = []
    var connectorSources: Set<String> = []
    /// 未识别字段，原样保留。
    var extra: [String: ExtensionJSONValue] = [:]

    init(enabled: Bool = false, address: String = "", providerNames: Set<String> = [],
         connectorSources: Set<String> = []) {
        self.enabled = enabled
        self.address = address
        self.providerNames = providerNames
        self.connectorSources = connectorSources
    }

    private enum KnownKeys: String, CodingKey, CaseIterable {
        case enabled, address, providerNames, connectorSources
    }

    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: KnownKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        providerNames = try c.decodeIfPresent(Set<String>.self, forKey: .providerNames) ?? []
        connectorSources = try c.decodeIfPresent(Set<String>.self, forKey: .connectorSources) ?? []
        let dynamic = try decoder.container(keyedBy: DynamicKey.self)
        let known = Set(KnownKeys.allCases.map(\.stringValue))
        var bag: [String: ExtensionJSONValue] = [:]
        for key in dynamic.allKeys where !known.contains(key.stringValue) {
            bag[key.stringValue] = try dynamic.decode(ExtensionJSONValue.self, forKey: key)
        }
        extra = bag
    }

    /// 集合排序后写出，避免哈希序抖动。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: KnownKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(address, forKey: .address)
        try c.encode(providerNames.sorted(), forKey: .providerNames)
        try c.encode(connectorSources.sorted(), forKey: .connectorSources)
        guard !extra.isEmpty else { return }
        var dynamic = encoder.container(keyedBy: DynamicKey.self)
        for (key, value) in extra {
            guard let codingKey = DynamicKey(stringValue: key) else { continue }
            try dynamic.encode(value, forKey: codingKey)
        }
    }
}

/// 出站代理 raw 节点的状态：缺省（可自由新建）、有效（可编辑且保留未知字段）、
/// 损坏（已存在但无法 decode；除显式关闭外一律拒绝写入，以免覆盖原始 JSON）。
enum OutboundProxyNodeState {
    case absent
    case valid(OutboundProxySettings)
    case corrupt
}

extension ExtensionSettings {
    /// 出站代理节点（键为 `ProxyExtension.settingsKey`）的状态。
    var outboundProxyNodeState: OutboundProxyNodeState {
        guard let value = extensionValue(for: ProxyExtension.settingsKey) else { return .absent }
        guard value.objectValue != nil,
              let settings = try? value.decode(OutboundProxySettings.self) else { return .corrupt }
        return .valid(settings)
    }

    /// 出站代理设置，经通用 opaque 接口读写。损坏节点读出默认值（实际策略仍由 raw 把关），
    /// 写入路径须先经 `outboundProxyNodeState` 拒绝损坏节点，避免用默认值覆盖原始 JSON。
    var outboundProxy: OutboundProxySettings {
        get {
            guard case .valid(let settings) = outboundProxyNodeState else { return OutboundProxySettings() }
            return settings
        }
        set {
            guard let value = try? ExtensionJSONValue.from(newValue) else { return }
            setExtensionValue(value, for: ProxyExtension.settingsKey)
        }
    }
}

extension ConfigStore {
    /// 已有 raw 节点无法 decode 时统一返回的原因：拒绝写入，不覆盖原始 JSON、不改策略。
    private static let corruptProxyNodeError =
        "出站代理配置结构无法识别，已保留原配置未改动；请先关闭代理开关，或修复 config.json 后再修改"

    /// 节点是否已存在但无法 decode（损坏）。
    private var outboundProxyNodeIsCorrupt: Bool {
        if case .corrupt = config.extensions.outboundProxyNodeState { return true }
        return false
    }

    /// 总开关。关闭恒允许，且是损坏节点的恢复操作；开启需节点可编辑且有有效地址。
    @discardableResult
    func setOutboundProxyEnabled(_ enabled: Bool) -> String? {
        guard enabled else { return disableOutboundProxy() }
        guard !outboundProxyNodeIsCorrupt else { return Self.corruptProxyNodeError }
        var settings = config.extensions.outboundProxy
        if let error = ProxyExtension.validate(settings.address) { return error }
        settings.enabled = true
        updateExtensions { $0.outboundProxy = settings }
        return nil
    }

    /// 显式关闭：恒允许。损坏的 object 节点只把 `enabled` 置 false，其余字段原样保留；
    /// 非 object 节点无可保留字段，写成规范禁用节点即完成恢复。
    private func disableOutboundProxy() -> String? {
        let key = ProxyExtension.settingsKey
        switch config.extensions.outboundProxyNodeState {
        case .absent:
            return nil
        case .valid(var settings):
            guard settings.enabled else { return nil }
            settings.enabled = false
            updateExtensions { $0.outboundProxy = settings }
            return nil
        case .corrupt:
            let recovered: ExtensionJSONValue
            if var node = config.extensions.extensionValue(for: key)?.objectValue {
                node["enabled"] = .bool(false)
                recovered = .object(node)
            } else if let canonical = try? ExtensionJSONValue.from(OutboundProxySettings()) {
                recovered = canonical
            } else {
                return Self.corruptProxyNodeError
            }
            updateExtensions { $0.setExtensionValue(recovered, for: key) }
            return nil
        }
    }

    /// 原子验证并保存地址。非法拒绝且不覆盖；空地址仅在关闭状态下允许清空。
    /// 损坏节点拒绝写入并保留原始 JSON。
    @discardableResult
    func setOutboundProxyAddress(_ address: String) -> String? {
        guard !outboundProxyNodeIsCorrupt else { return Self.corruptProxyNodeError }
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        var settings = config.extensions.outboundProxy
        if trimmed.isEmpty {
            guard !settings.enabled else { return "启用状态下不能清空代理地址" }
        } else if let error = ProxyExtension.validate(address) {
            return error
        }
        settings.address = trimmed
        updateExtensions { $0.outboundProxy = settings }
        return nil
    }

    /// 勾选/取消原生供应商。取消恒允许；勾选要求该名字是现存原生供应商。
    /// 损坏节点拒绝写入并保留原始 JSON。
    @discardableResult
    func setOutboundProxyProvider(_ name: String, selected: Bool) -> String? {
        guard !outboundProxyNodeIsCorrupt else { return Self.corruptProxyNodeError }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var settings = config.extensions.outboundProxy
        if selected {
            let isNative = config.remotes.contains {
                $0.source.isAPI && splitProviderModel($0.name).provider == trimmed
            }
            guard isNative else { return "该供应商不是原生供应商，无法走代理" }
            settings.providerNames.insert(trimmed)
        } else {
            settings.providerNames.remove(trimmed)
        }
        updateExtensions { $0.outboundProxy = settings }
        return nil
    }

    /// 勾选/取消连接器来源。选中不支持的连接器拒绝；取消恒允许。
    /// 损坏节点拒绝写入并保留原始 JSON。
    @discardableResult
    func setOutboundProxyConnector(_ source: RemoteSource, selected: Bool) -> String? {
        guard !outboundProxyNodeIsCorrupt else { return Self.corruptProxyNodeError }
        var settings = config.extensions.outboundProxy
        if selected {
            guard ProxyExtension.supports(source: source, registry: registry) else {
                return "该连接器不支持出站代理"
            }
            settings.connectorSources.insert(source.rawValue)
        } else {
            settings.connectorSources.remove(source.rawValue)
        }
        updateExtensions { $0.outboundProxy = settings }
        return nil
    }
}
