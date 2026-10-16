import Foundation

/// 一次上游请求的协议适配方式：原样透传，把入站 Responses 转成 Chat Completions，
/// 或交给某个扩展连接器（按 `RemoteSource` 身份）转发。
/// 只从路由配置快照解析一次，之后该请求内所有 URL / 鉴权 / 转换 / 用量 / 重排判断复用。
enum ProtocolAdapter: Equatable, Sendable {
    case passthrough
    case chatToResponses
    /// 经宿主侧扩展连接器转发；连接器身份即远端来源，不承载凭据。
    case connector(RemoteSource)
}

/// 任意 JSON 值。用于原样保留扩展配置里未识别的字段与数值类型，不丢数据。
/// 整数优先保留为 `Int` / `UInt64`（避免经过 `Double` 丢精度），未能装下的数值退化为
/// `Decimal`，最后才是 `Double`。
enum ExtensionJSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case uint(UInt64)
    case decimal(Decimal)
    case number(Double)
    case string(String)
    case array([ExtensionJSONValue])
    case object([String: ExtensionJSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let value = try? c.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? c.decode(Int.self) {
            self = .int(value)
        } else if let value = try? c.decode(UInt64.self) {
            self = .uint(value)
        } else if let value = try? c.decode(Decimal.self) {
            self = .decimal(value)
        } else if let value = try? c.decode(Double.self) {
            self = .number(value)
        } else if let value = try? c.decode(String.self) {
            self = .string(value)
        } else if let value = try? c.decode([ExtensionJSONValue].self) {
            self = .array(value)
        } else if let value = try? c.decode([String: ExtensionJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported extension JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .int(let value): try c.encode(value)
        case .uint(let value): try c.encode(value)
        case .decimal(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
}

extension ExtensionJSONValue {
    /// 用标准 JSON 编解码在任意可编解码类型与本值之间转换（扩展配置读写共用）。
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }

    static func from<T: Encodable>(_ value: T) throws -> ExtensionJSONValue {
        try JSONDecoder().decode(ExtensionJSONValue.self, from: JSONEncoder().encode(value))
    }

    var objectValue: [String: ExtensionJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

/// Chat Completions → Responses 转换扩展。
///
/// 供应商当前没有独立 UUID，按供应商 **name** 作为身份键。关闭 `enabled` 不清除
/// `providerNames`；该扩展不改动任何 native 配置。存量旧 `responsesTransport`
/// 只在首次加载（缺 extensions 字段）时迁移一次。
struct ChatToResponsesSettings: Codable, Equatable {
    var enabled: Bool = false
    var providerNames: Set<String> = []

    init(enabled: Bool = false, providerNames: Set<String> = []) {
        self.enabled = enabled
        self.providerNames = providerNames
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, providerNames
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        providerNames = try c.decodeIfPresent(Set<String>.self, forKey: .providerNames) ?? []
    }

    /// 排序后写出，避免集合哈希序导致持久化输出抖动。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(providerNames.sorted(), forKey: .providerNames)
    }

    func covers(provider: String) -> Bool {
        enabled && providerNames.contains(provider)
    }
}

/// 通用扩展连接器配置：只声明启停与绑定，不保存任何凭据（token 由扩展自身持有，
/// 连接状态等运行时信息不写入 `config.json`）。供应商身份按 name。
/// 未识别字段原样保留，保证扩展升级/降级不丢数据。
struct ConnectorSettings: Codable, Equatable {
    /// 总开关。关闭只让候选不可用，不清除 providerName / providerAdded。
    var enabled: Bool = false
    /// 绑定的供应商名；未绑定为 nil。不承载 token。
    var providerName: String?
    /// 是否已加入供应商名单（由扩展页维护）。
    var providerAdded: Bool = false
    /// 显式协议选择原始串（持久化字段 `enabledEndpoints`）：nil = 继承来源全集，
    /// 空集 = 全关，未知协议串原样保留。
    private var enabledEndpointRaw: Set<String>?
    /// 未识别字段，原样保留。
    var extra: [String: ExtensionJSONValue] = [:]

    init(enabled: Bool = false, providerName: String? = nil, providerAdded: Bool = false,
         enabledEndpoints: Set<EndpointKind>? = nil) {
        self.enabled = enabled
        self.providerName = providerName
        self.providerAdded = providerAdded
        self.enabledEndpointRaw = enabledEndpoints.map { Set($0.map(\.rawValue)) }
    }

    /// UI/判定用：已解析的协议选择。nil = 继承，空集 = 全关；写入保留既有未知原串。
    var enabledEndpoints: Set<EndpointKind>? {
        get { enabledEndpointRaw.map { Set($0.compactMap(EndpointKind.init(rawValue:))) } }
        set {
            guard let newValue else {
                enabledEndpointRaw = nil
                return
            }
            let unknown = (enabledEndpointRaw ?? []).filter { EndpointKind(rawValue: $0) == nil }
            enabledEndpointRaw = Set(newValue.map(\.rawValue)).union(unknown)
        }
    }

    /// 未配置（nil）继承全集；已配置则只在显式集合内。
    func allows(_ endpoint: EndpointKind) -> Bool {
        guard let enabledEndpointRaw else { return true }
        return enabledEndpointRaw.contains(endpoint.rawValue)
    }

    private enum KnownKeys: String, CodingKey, CaseIterable {
        case enabled, providerName, providerAdded, enabledEndpoints
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
        providerName = try c.decodeIfPresent(String.self, forKey: .providerName)
        providerAdded = try c.decodeIfPresent(Bool.self, forKey: .providerAdded) ?? false
        // 字符串集合读取，未知协议值原样保留；结构非法则整体解码失败按 disabled 回退。
        enabledEndpointRaw = try c.decodeIfPresent(Set<String>.self, forKey: .enabledEndpoints)
        let dynamic = try decoder.container(keyedBy: DynamicKey.self)
        let known = Set(KnownKeys.allCases.map(\.stringValue))
        var extra: [String: ExtensionJSONValue] = [:]
        for key in dynamic.allKeys where !known.contains(key.stringValue) {
            extra[key.stringValue] = try dynamic.decode(ExtensionJSONValue.self, forKey: key)
        }
        self.extra = extra
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: KnownKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(providerName, forKey: .providerName)
        try c.encode(providerAdded, forKey: .providerAdded)
        if let enabledEndpointRaw {
            try c.encode(enabledEndpointRaw.sorted(), forKey: .enabledEndpoints)
        }
        guard !extra.isEmpty else { return }
        var dynamic = encoder.container(keyedBy: DynamicKey.self)
        for (key, value) in extra {
            guard let codingKey = DynamicKey(stringValue: key) else { continue }
            try dynamic.encode(value, forKey: codingKey)
        }
    }

    /// 开关开启 + 已加入 + 名字匹配。
    func routes(provider: String) -> Bool {
        enabled && providerAdded && providerName == provider
    }
}

/// 扩展配置。`chatToResponses` 有强类型；其余顶层键（连接器设置与任何未知扩展）
/// 一律以原始 JSON 保留，读写都不丢数据、不因未知结构报错。
struct ExtensionSettings: Codable, Equatable {
    var chatToResponses: ChatToResponsesSettings
    /// 除 `chatToResponses` 外的全部顶层键，原样保留。
    private var otherExtensions: [String: ExtensionJSONValue]

    init(chatToResponses: ChatToResponsesSettings = ChatToResponsesSettings()) {
        self.chatToResponses = chatToResponses
        self.otherExtensions = [:]
    }

    private enum CodingKeys: String, CodingKey {
        case chatToResponses
    }

    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chatToResponses = try c.decodeIfPresent(ChatToResponsesSettings.self, forKey: .chatToResponses)
            ?? ChatToResponsesSettings()
        let dynamic = try decoder.container(keyedBy: DynamicKey.self)
        var bag: [String: ExtensionJSONValue] = [:]
        for key in dynamic.allKeys where key.stringValue != CodingKeys.chatToResponses.stringValue {
            bag[key.stringValue] = try dynamic.decode(ExtensionJSONValue.self, forKey: key)
        }
        otherExtensions = bag
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(chatToResponses, forKey: .chatToResponses)
        guard !otherExtensions.isEmpty else { return }
        var dynamic = encoder.container(keyedBy: DynamicKey.self)
        for (key, value) in otherExtensions {
            guard let codingKey = DynamicKey(stringValue: key) else { continue }
            try dynamic.encode(value, forKey: codingKey)
        }
    }

    /// 读取某个连接器键的设置；缺失或不是对象时返回默认值，原值仍留在 bag 中不被丢弃。
    func connectorSettings(for key: String) -> ConnectorSettings {
        guard let value = otherExtensions[key],
              value.objectValue != nil,
              let settings = try? value.decode(ConnectorSettings.self) else {
            return ConnectorSettings()
        }
        return settings
    }

    /// 写入某个连接器键的设置（含未识别字段），保留其它顶层键。
    /// 编码失败时保留原值并记录，绝不静默清空已有节点。
    mutating func setConnectorSettings(_ settings: ConnectorSettings, for key: String) {
        guard let value = try? ExtensionJSONValue.from(settings) else {
            Log.shared.log("extension \(key): 连接器设置无法编码，保留原值不覆盖")
            return
        }
        otherExtensions[key] = value
    }

    func extensionValue(for key: String) -> ExtensionJSONValue? {
        otherExtensions[key]
    }

    mutating func setExtensionValue(_ value: ExtensionJSONValue?, for key: String) {
        guard key != CodingKeys.chatToResponses.rawValue else { return }
        otherExtensions[key] = value
    }

    /// 全部非 `chatToResponses` 顶层键（测试/诊断用；不暴露可变内容）。
    var extensionKeys: [String] { otherExtensions.keys.sorted() }
}

extension ExtensionSettings {
    /// 适配身份只由 `source` 决定：主干原生 HTTP（`.api`）才可能透传或做转换；
    /// 任何非 `.api` 来源恒为 `.connector(source)`，即便该来源尚未注册，绝不回退 native。
    func adapter(for remote: RemoteModel, endpoint: EndpointKind) -> ProtocolAdapter {
        if !remote.source.isAPI { return .connector(remote.source) }
        guard endpoint == .responses else { return .passthrough }
        return chatToResponses.covers(provider: splitProviderModel(remote.name).provider)
            ? .chatToResponses : .passthrough
    }

    /// 配置层面的可用性（不含运行时连接就绪，后者由 Router 把关）。连接器来源需由
    /// 传入 registry 注册且已开启并绑定；两类覆盖不满足时都不可用，绝不回退 native。
    func supports(_ endpoint: EndpointKind, remote: RemoteModel,
                  registry: ExtensionRegistry = .builtIn) -> Bool {
        switch adapter(for: remote, endpoint: endpoint) {
        case .passthrough:
            return remote.supports(endpoint)
        case .chatToResponses:
            let chat = remote.apiEndpoints.chat
            let url = ConfigStore.normalizeBaseURL(chat.baseURL)
            return chat.enabled && !url.isEmpty && ConfigStore.isValidHTTPURL(url)
        case .connector:
            return registry.supports(endpoint, remote: remote, settings: self)
        }
    }
}

/// 候选远端 + 其在本请求中的适配方式，从同一锁快照一次解析。
struct RoutedCandidate {
    let remote: RemoteModel
    let adapter: ProtocolAdapter
    var outboundPolicy: OutboundPolicy = .direct
}
