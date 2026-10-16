import Foundation
import Combine
import SwiftUI   // Array.move(fromOffsets:toOffset:)（fake 排序）来自 SwiftUI

// MARK: - 数据模型

enum EndpointKind: String, Codable, CaseIterable {
    case chat, responses, messages
    /// 原生 Gemini（generativelanguage.googleapis.com）。与前三者不同，它的上游
    /// 路径不是「Base URL + 固定后缀」，而是 `Base URL + /models/{model}:{operation}`，
    /// 由 `GeminiEndpoint` 构建；入站路径里的 model 是本地路由 id，转发前改写为真实模型。
    /// 仅显式启用：旧配置迁移与 `APIEndpointSettings.all(baseURL:)` 都不会打开它。
    case gemini

    var displayName: String {
        switch self {
        case .chat: return "Chat Completions"
        case .responses: return "Responses"
        case .messages: return "Messages"
        case .gemini: return "Gemini"
        }
    }

    /// Base URL 之外的协议相对路径（纯反向代理，不做协议转换）。
    /// 例如 OpenAI 填 `https://api.openai.com/v1`，最终请求 `/v1/chat/completions`；
    /// GLM Coding Plan 填 `https://open.bigmodel.cn/api/coding/paas/v4`，最终请求
    /// `/api/coding/paas/v4/chat/completions`。
    /// Gemini 无固定后缀（见 `GeminiEndpoint`），这里返回空串仅为穷尽 switch；
    /// `Forwarder.upstreamURL` 对 Gemini 直接返回 nil，避免拼出错误地址。
    var upstreamPath: String {
        switch self {
        case .chat: return "/chat/completions"
        case .responses: return "/responses"
        case .messages: return "/v1/messages"
        case .gemini: return ""
        }
    }
}

struct EndpointSetting: Codable, Equatable, Hashable {
    var enabled: Bool
    var baseURL: String

    static let disabled = EndpointSetting(enabled: false, baseURL: "")
}

/// 远端记录的连接身份。主干只内置原生 HTTP 的 `.api`；其它来源由扩展注册
/// （例如某个官方 CLI 连接器），任意字符串原样保留。非 `.api` 来源永不被当作 HTTP 上游。
struct RemoteSource: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }

    /// 主干原生 HTTP 供应商。
    static let api = RemoteSource("api")

    /// 只有原生 HTTP 来源可以走 URLSession 上游。
    var isAPI: Bool { self == .api }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 旧版「Responses 接入方式」字段：不再编码写出，仅供 AppConfig 做一次性迁移。
enum ResponsesTransport: String, Codable {
    case native
    case chatCompletions
}

/// 供应商级协议配置。每个模型复制同一份配置，UI 只允许在供应商设置中修改。
///
/// 只描述 **native** 协议（Chat / Responses / Messages / Gemini）；协议转换由
/// 独立的扩展配置（`AppConfig.extensions`）决定，两者互不污染。
struct APIEndpointSettings: Codable, Equatable, Hashable {
    var chat: EndpointSetting
    var responses: EndpointSetting
    var messages: EndpointSetting
    /// 原生 Gemini 协议配置。默认 `.disabled`：旧配置解码与历史工厂都不启用它，
    /// 需要用户显式打开（`enabled(_:baseURL:)` 会把 `.gemini` 映射进来）。
    var gemini: EndpointSetting

    init(chat: EndpointSetting, responses: EndpointSetting, messages: EndpointSetting,
         gemini: EndpointSetting = .disabled) {
        self.chat = chat
        self.responses = responses
        self.messages = messages
        self.gemini = gemini
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chat = try c.decodeIfPresent(EndpointSetting.self, forKey: .chat) ?? .disabled
        responses = try c.decodeIfPresent(EndpointSetting.self, forKey: .responses) ?? .disabled
        messages = try c.decodeIfPresent(EndpointSetting.self, forKey: .messages) ?? .disabled
        gemini = try c.decodeIfPresent(EndpointSetting.self, forKey: .gemini) ?? .disabled
        // 旧版 responsesTransport 由 AppConfig 迁移读取；这里忽略，编码也不再输出。
    }

    subscript(kind: EndpointKind) -> EndpointSetting {
        get {
            switch kind {
            case .chat: return chat
            case .responses: return responses
            case .messages: return messages
            case .gemini: return gemini
            }
        }
        set {
            switch kind {
            case .chat: chat = newValue
            case .responses: responses = newValue
            case .messages: messages = newValue
            case .gemini: gemini = newValue
            }
        }
    }

    var enabledKinds: [EndpointKind] {
        EndpointKind.allCases.filter { self[$0].enabled }
    }

    /// 历史工厂：与旧配置语义一致，只启用原始三种协议，绝不含糊地打开 Gemini。
    static func all(baseURL: String) -> APIEndpointSettings {
        APIEndpointSettings(
            chat: EndpointSetting(enabled: true, baseURL: baseURL),
            responses: EndpointSetting(enabled: true, baseURL: baseURL),
            messages: EndpointSetting(enabled: true, baseURL: baseURL)
        )
    }

    /// 只启用 `kinds` 中的协议（Gemini 需显式包含在 `kinds` 中才会打开）。
    static func enabled(_ kinds: Set<EndpointKind>, baseURL: String) -> APIEndpointSettings {
        APIEndpointSettings(
            chat: EndpointSetting(enabled: kinds.contains(.chat), baseURL: kinds.contains(.chat) ? baseURL : ""),
            responses: EndpointSetting(enabled: kinds.contains(.responses), baseURL: kinds.contains(.responses) ? baseURL : ""),
            messages: EndpointSetting(enabled: kinds.contains(.messages), baseURL: kinds.contains(.messages) ? baseURL : ""),
            gemini: EndpointSetting(enabled: kinds.contains(.gemini), baseURL: kinds.contains(.gemini) ? baseURL : "")
        )
    }
}

/// 一个远端供应商模型。入站路径决定转发格式，并路由到供应商为该协议配置的 Base URL。
struct RemoteModel: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    var apiKey: String
    var model: String
    var extraHeaders: [String: String]
    var apiEndpoints: APIEndpointSettings
    /// 非 `.api` 来源的记录由扩展连接器拥有：native 端点恒全部关闭、apiKey 为空
    /// （凭据由扩展自身持有）。
    var source: RemoteSource
    init(id: UUID, name: String, apiKey: String, model: String,
         extraHeaders: [String: String], apiEndpoints: APIEndpointSettings,
         source: RemoteSource = .api) {
        self.id = id
        self.name = name
        self.apiKey = apiKey
        self.model = model
        self.extraHeaders = extraHeaders
        self.apiEndpoints = apiEndpoints
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, apiKey, model, extraHeaders, apiEndpoints, source
        case legacyBaseURL = "baseURL"
        case legacyEndpoint = "endpoint"
        case legacyEndpoints = "endpoints"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        apiKey = try c.decode(String.self, forKey: .apiKey)
        model = try c.decode(String.self, forKey: .model)
        extraHeaders = try c.decodeIfPresent([String: String].self, forKey: .extraHeaders) ?? [:]
        // 旧配置无 source → 普通 API。
        source = try c.decodeIfPresent(RemoteSource.self, forKey: .source) ?? .api

        if let settings = try c.decodeIfPresent(APIEndpointSettings.self, forKey: .apiEndpoints) {
            apiEndpoints = settings
            return
        }

        let legacyBaseURL = try c.decodeIfPresent(String.self, forKey: .legacyBaseURL) ?? ""
        let enabled: Set<EndpointKind>
        if let kinds = try c.decodeIfPresent([EndpointKind].self, forKey: .legacyEndpoints), !kinds.isEmpty {
            enabled = Set(kinds)
        } else if let kind = try c.decodeIfPresent(EndpointKind.self, forKey: .legacyEndpoint) {
            enabled = [kind]
        } else {
            enabled = Self.inferLegacyEndpoints(baseURL: legacyBaseURL)
        }
        apiEndpoints = Self.legacyEndpointSettings(enabled: enabled, baseURL: legacyBaseURL)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(apiKey, forKey: .apiKey)
        try c.encode(model, forKey: .model)
        try c.encode(extraHeaders, forKey: .extraHeaders)
        try c.encode(apiEndpoints, forKey: .apiEndpoints)
        try c.encode(source, forKey: .source)
    }

    /// 旧配置不含 gemini 字段；字段内只有原始三种协议，迁移时也绝不推断出 Gemini。
    /// `allCases` 如今含 `.gemini`，故此处显式列出历史三种，避免旧配置被静默启用 Gemini。
    static let legacyMigrationKinds: Set<EndpointKind> = [.chat, .responses, .messages]

    private static func inferLegacyEndpoints(baseURL: String) -> Set<EndpointKind> {
        let lower = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return [] }
        if lower.contains("open.bigmodel.cn/api/anthropic") {
            // GLM Coding Plan 同一份订阅分别提供 Chat / Responses / Messages 地址。
            return legacyMigrationKinds
        }
        if lower.contains("/api/anthropic") || lower.contains("api.anthropic.com") {
            return [.messages]
        }
        if lower.contains("open.bigmodel.cn/api/coding/paas/v4") {
            return [.chat]
        }
        if lower.contains("open.bigmodel.cn/api") {
            return [.responses]
        }
        return legacyMigrationKinds
    }

    /// 旧配置只有一个 Base URL，且旧转发逻辑会固定追加 `/v1/...`。
    /// 迁移到“Base URL 为完整前缀”后，需要为旧的 Chat / Responses 地址补齐 `/v1`；
    /// GLM Coding Plan 的 Anthropic 地址则展开成官方三类地址。
    private static func legacyEndpointSettings(enabled: Set<EndpointKind>,
                                               baseURL: String) -> APIEndpointSettings {
        var settings = APIEndpointSettings(chat: .disabled, responses: .disabled, messages: .disabled)
        for kind in enabled {
            settings[kind] = EndpointSetting(enabled: true,
                                             baseURL: legacyBaseURL(baseURL, for: kind))
        }
        return settings
    }

    private static func legacyBaseURL(_ raw: String, for kind: EndpointKind) -> String {
        let base = ConfigStore.normalizeBaseURL(raw)
        let lower = base.lowercased()
        guard lower.contains("open.bigmodel.cn/api/anthropic") else {
            switch kind {
            case .chat, .responses:
                return addingLegacyVersionPrefix(to: base)
            case .messages:
                return removingLegacyVersionSuffix(from: base)
            case .gemini:
                // 旧配置从不包含 Gemini；仅为穷尽 switch。
                return base
            }
        }

        switch kind {
        case .chat:
            return "https://open.bigmodel.cn/api/coding/paas/v4"
        case .responses:
            return "https://open.bigmodel.cn/api/v1"
        case .messages:
            return "https://open.bigmodel.cn/api/anthropic"
        case .gemini:
            // 旧配置从不包含 Gemini；仅为穷尽 switch，保持 Base URL 原样。
            return base
        }
    }

    /// 旧版 Chat / Responses 的最终 URL 都包含 `/v1`。已经带版本段的地址保持原样。
    private static func addingLegacyVersionPrefix(to raw: String) -> String {
        let lower = raw.lowercased()
        if lower.hasSuffix("/v1") || lower.contains("/v1/")
            || lower.contains("/api/v") || lower.contains("/paas/v") {
            return raw
        }
        return raw + "/v1"
    }

    private static func removingLegacyVersionSuffix(from raw: String) -> String {
        guard raw.lowercased().hasSuffix("/v1") else { return raw }
        return String(raw.dropLast(3))
    }
}

extension RemoteModel {
    func endpointSetting(for kind: EndpointKind) -> EndpointSetting { apiEndpoints[kind] }

    /// **只表示 native 协议**是否启用。协议转换（Chat → Responses）由
    /// `AppConfig`/`ExtensionSettings` 的有效判断决定，见 `config.supports(_:remote:)`。
    func supports(_ kind: EndpointKind) -> Bool {
        apiEndpoints[kind].enabled
    }

    /// 该远端 native 已启用且填了地址的 Base URL（按首现去重）。
    var endpointBaseURLs: [String] {
        let activeURLs: [String] = EndpointKind.allCases.compactMap { kind -> String? in
            guard supports(kind) else { return nil }
            let url = apiEndpoints[kind].baseURL
            return url.isEmpty ? nil : url
        }
        return activeURLs.reduce(into: [String]()) { urls, url in
            if !urls.contains(url) { urls.append(url) }
        }
    }

    var endpointSummary: String {
        let names = EndpointKind.allCases.filter { supports($0) }.map(\.displayName)
        return names.isEmpty ? "未启用接口" : names.joined(separator: " / ")
    }
}

struct FakeModel: Codable, Identifiable, Equatable {
    var id: UUID
    var fakeModelID: String
    var displayName: String
    var remoteID: UUID?
    var fallbackRemoteIDs: [UUID] = []
    var autoFallback: Bool = true
    var selectedRemoteID: UUID?

    var startingRemoteID: UUID? {
        if let selectedRemoteID, orderedRemoteIDs.contains(selectedRemoteID) { return selectedRemoteID }
        return orderedRemoteIDs.first
    }

    var orderedRemoteIDs: [UUID] {
        var seen = Set<UUID>()
        return ([remoteID].compactMap { $0 } + fallbackRemoteIDs).filter { seen.insert($0).inserted }
    }

    private enum CodingKeys: String, CodingKey {
        case id, fakeModelID, displayName, remoteID, fallbackRemoteIDs, autoFallback, selectedRemoteID
    }

    init(id: UUID, fakeModelID: String, displayName: String, remoteID: UUID?,
         fallbackRemoteIDs: [UUID] = [], autoFallback: Bool = true) {
        self.id = id
        self.fakeModelID = fakeModelID
        self.displayName = displayName
        self.remoteID = remoteID
        self.fallbackRemoteIDs = fallbackRemoteIDs
        self.autoFallback = autoFallback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fakeModelID = try container.decode(String.self, forKey: .fakeModelID)
        displayName = try container.decode(String.self, forKey: .displayName)
        remoteID = try container.decodeIfPresent(UUID.self, forKey: .remoteID)
        fallbackRemoteIDs = try container.decodeIfPresent([UUID].self, forKey: .fallbackRemoteIDs) ?? []
        autoFallback = try container.decodeIfPresent(Bool.self, forKey: .autoFallback) ?? true
        selectedRemoteID = try container.decodeIfPresent(UUID.self, forKey: .selectedRemoteID)
    }
}

struct AppConfig: Codable, Equatable {
    var port: Int = 8788
    var remotes: [RemoteModel] = []
    var fakes: [FakeModel] = []
    /// 内置扩展配置（当前只有 Chat → Responses）。默认关闭、无选择。
    var extensions: ExtensionSettings = ExtensionSettings()

    private enum CodingKeys: String, CodingKey {
        case port, remotes, fakes, extensions
    }

    func adapter(for remote: RemoteModel, endpoint: EndpointKind) -> ProtocolAdapter {
        extensions.adapter(for: remote, endpoint: endpoint)
    }

    func supports(_ endpoint: EndpointKind, remote: RemoteModel,
                  registry: ExtensionRegistry = .builtIn) -> Bool {
        extensions.supports(endpoint, remote: remote, registry: registry)
    }

    var chatToResponsesProviders: Set<String> { extensions.chatToResponses.providerNames }
}

extension AppConfig {
    private struct LegacyRemoteProbe: Decodable {
        struct Endpoints: Decodable {
            var responsesTransport: ResponsesTransport?
        }
        var name: String?
        var apiEndpoints: Endpoints?
    }

    /// 缺 extensions 字段时按旧的 responsesTransport 迁移一次；已存在则原样尊重，
    /// 不得在 reload 时重新启用。迁移先遍历全部旧远端再交出去重，避免并集丢标记；
    /// 只设置扩展，保留每模型原有 native responses.enabled / baseURL。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 8788
        remotes = try c.decodeIfPresent([RemoteModel].self, forKey: .remotes) ?? []
        fakes = try c.decodeIfPresent([FakeModel].self, forKey: .fakes) ?? []
        extensions = try c.decodeIfPresent(ExtensionSettings.self, forKey: .extensions)
            ?? Self.migrateLegacyTransports(from: c)
    }

    private static func migrateLegacyTransports(
        from c: KeyedDecodingContainer<CodingKeys>
    ) -> ExtensionSettings {
        var settings = ExtensionSettings()
        guard let probes = try? c.decodeIfPresent([LegacyRemoteProbe].self, forKey: .remotes),
              !probes.isEmpty else { return settings }
        var providers: Set<String> = []
        for probe in probes
        where probe.apiEndpoints?.responsesTransport == .chatCompletions {
            guard let name = probe.name else { continue }
            providers.insert(splitProviderModel(name).provider)
        }
        guard !providers.isEmpty else { return settings }
        settings.chatToResponses.enabled = true
        settings.chatToResponses.providerNames = providers
        return settings
    }
}

/// "供应商 · 模型" 显示名拆分；没有分隔符时供应商与模型同名
func splitProviderModel(_ name: String) -> (provider: String, model: String) {
    if let r = name.range(of: " · ") {
        return (String(name[..<r.lowerBound]), String(name[r.upperBound...]))
    }
    return (name, name)
}

/// 子菜单的供应商分组
struct RemoteGroup: Identifiable {
    let provider: String
    var id: String { provider }
    let remotes: [RemoteModel]
}

// MARK: - 默认配置

extension AppConfig {
    static func example() -> AppConfig {
        let deepSeek = RemoteModel(
            id: UUID(), name: "DeepSeek官方 · deepseek-flash",
            apiKey: "sk-REPLACE-ME", model: "deepseek-flash", extraHeaders: [:],
            apiEndpoints: .enabled([.chat], baseURL: "https://api.deepseek.com/v1")
        )
        let remotes = [deepSeek]

        let fakes = [
            FakeModel(id: UUID(), fakeModelID: "main",
                      displayName: "main", remoteID: deepSeek.id),
        ]
        return AppConfig(port: 8788, remotes: remotes, fakes: fakes)
    }
}

// MARK: - Router（给 server 线程读，自带锁）

final class Router {
    private let lock = NSLock()
    /// 扩展连接器注册表；候选筛选与支持判定都读它。默认注册内置扩展。
    private let registry: ExtensionRegistry
    private var remotes: [UUID: RemoteModel] = [:]
    private var fakesByID: [String: FakeModel] = [:]
    private var allFakes: [FakeModel] = []
    /// 与 remotes/fakes 同一快照的扩展配置；候选筛选与 adapter 解析都读它。
    private var extensions = ExtensionSettings()
    /// 各连接器来源的运行时就绪状态（CLI 已装/已登录/能力满足）。不持久化，默认 false；
    /// `update(_:)` 不重置，只有控制方显式置 false 才关闭。
    private var connectorReady: [RemoteSource: Bool] = [:]
    private var retryAfter: [UUID: Date] = [:]
    /// 运行期“首选远端”：仅由手动选择或已完成的自动回退成功写入，candidates 与 UI 都从它读起。
    private var activeRemoteIDs: [UUID: UUID] = [:]
    /// 权威代次：请求开始时取快照，完成时仅当代次未变才允许提升首选，防止迟到完成覆盖手动选择。
    private var selectionEpochs: [UUID: UInt64] = [:]

    init(registry: ExtensionRegistry = .builtIn) {
        self.registry = registry
    }

    private struct BindingSnapshot: Equatable {
        let manualStart: UUID?
        let ordered: [UUID]
        let autoFallback: Bool
    }

    /// 锁内实现：按端点做 effective 筛选后的候选（未解析 adapter）。
    /// 连接器候选额外受「registry 注册 + 运行时就绪」双把关：缺失扩展或未就绪即
    /// 不可用，绝不回退 native。同一把锁下的 registry/ready/settings 快照一次取用。
    private func resolvedLocked(fakeModelID: String?, endpoint: EndpointKind?)
        -> (fake: FakeModel, remotes: [RemoteModel])? {
        guard let want = fakeModelID, let fake = fakesByID[want] else { return nil }
        let settings = extensions
        let ready = connectorReady
        let registry = self.registry
        var ordered = fake.orderedRemoteIDs.compactMap { remotes[$0] }
        if let index = ordered.firstIndex(where: { $0.id == effectivePreferredRemoteID(for: fake) }) {
            ordered = Array(ordered[index...]) + Array(ordered[..<index])
        }
        if !fake.autoFallback { ordered = Array(ordered.prefix(1)) }
        if let endpoint {
            ordered = ordered.filter { remote in
                if case .connector(let source) = settings.adapter(for: remote, endpoint: endpoint),
                   !(ready[source] ?? false) {
                    return false
                }
                return settings.supports(endpoint, remote: remote, registry: registry)
            }
        }
        let available = ordered.filter { (retryAfter[$0.id] ?? .distantPast) <= Date() }
        return (fake, fake.autoFallback ? (available.isEmpty ? ordered : available) : ordered)
    }

    /// 设置某连接器来源的运行时就绪；控制方探测后写入，`update(_:)` 不重置。
    func setConnectorAvailable(source: RemoteSource, available: Bool) {
        lock.lock()
        connectorReady[source] = available
        lock.unlock()
    }

    /// 某连接器来源的运行时就绪状态（默认 false；测试/UI 读取用）。
    func connectorAvailable(source: RemoteSource) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return connectorReady[source] ?? false
    }

    func candidates(fakeModelID: String?, endpoint: EndpointKind? = nil) -> (fake: FakeModel, remotes: [RemoteModel])? {
        lock.lock()
        defer { lock.unlock() }
        return resolvedLocked(fakeModelID: fakeModelID, endpoint: endpoint)
    }

    /// 候选 + 适配方式，从同一把锁下的快照一次解析。请求处理只用这一份结果，
    /// 总开关中途变化也不会让同一次请求的各 attempt 解析出不同 adapter。
    func routedCandidates(fakeModelID: String?, endpoint: EndpointKind)
        -> (fake: FakeModel, candidates: [RoutedCandidate])? {
        lock.lock()
        defer { lock.unlock() }
        guard let resolved = resolvedLocked(fakeModelID: fakeModelID, endpoint: endpoint) else { return nil }
        let settings = extensions
        return (resolved.fake, resolved.remotes.map {
            RoutedCandidate(remote: $0,
                            adapter: settings.adapter(for: $0, endpoint: endpoint),
                            outboundPolicy: BuiltinExtensions.outboundPolicy(remote: $0, settings: settings))
        })
    }

    /// 自动回退开启且首选仍有效时用它；否则用持久起始（禁用自动回退时始终如此）。
    private func effectivePreferredRemoteID(for fake: FakeModel) -> UUID? {
        if fake.autoFallback,
           let preferred = activeRemoteIDs[fake.id],
           fake.orderedRemoteIDs.contains(preferred) {
            return preferred
        }
        return fake.startingRemoteID
    }

    func recordFailure(remoteID: UUID, retryAfter date: Date = Date().addingTimeInterval(60)) {
        lock.lock()
        retryAfter[remoteID] = date
        // 首选失败即失去资格；在途请求仍按已生成的候选顺序前进。
        activeRemoteIDs = activeRemoteIDs.filter { $0.value != remoteID }
        lock.unlock()
    }

    /// 手动选择：立即成为首选并提升代次，使在途请求的迟到完成不能覆盖。
    func selectRemote(fakeID: UUID, remoteID: UUID) {
        lock.lock()
        activeRemoteIDs[fakeID] = remoteID
        selectionEpochs[fakeID, default: 0] += 1
        retryAfter.removeValue(forKey: remoteID)
        lock.unlock()
    }

    /// 完成成功时调用：远端须仍存在且仍绑定；代次未变（nil = 直接调用不校验）才提升首选，
    /// 首选改变时提升代次。取消/流错误不会走到这里。
    func recordSuccess(fakeID: UUID, remoteID: UUID, epoch: UInt64? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let fake = allFakes.first(where: { $0.id == fakeID }),
              remotes[remoteID] != nil,
              fake.orderedRemoteIDs.contains(remoteID) else { return }
        retryAfter.removeValue(forKey: remoteID)
        if let epoch, epoch != (selectionEpochs[fakeID] ?? 0) { return }
        // 仅当“有效首选”确实改变时才提升代次；对持久起始的成功不提升，避免作废并发计划。
        if effectivePreferredRemoteID(for: fake) != remoteID {
            selectionEpochs[fakeID, default: 0] += 1
        }
        activeRemoteIDs[fakeID] = remoteID
    }

    /// 请求开始时取的权威代次快照，用于完成时的过期校验。
    func requestEpoch(fakeModelID: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        guard let fake = fakesByID[fakeModelID] else { return 0 }
        return selectionEpochs[fake.id] ?? 0
    }

    func activeRemoteID(fakeID: UUID) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard let fake = allFakes.first(where: { $0.id == fakeID }) else { return nil }
        return effectivePreferredRemoteID(for: fake)
    }

    func update(_ config: AppConfig) {
        var r: [UUID: RemoteModel] = [:]
        for remote in config.remotes {
            r[remote.id] = remote
        }
        var f: [String: FakeModel] = [:]
        for fake in config.fakes {
            if f[fake.fakeModelID] == nil { f[fake.fakeModelID] = fake }
        }
        lock.lock()
        let previous = Dictionary(uniqueKeysWithValues: allFakes.map {
            ($0.id, BindingSnapshot(manualStart: $0.selectedRemoteID,
                                    ordered: $0.orderedRemoteIDs,
                                    autoFallback: $0.autoFallback))
        })
        remotes = r
        fakesByID = f
        allFakes = config.fakes
        extensions = config.extensions
        let valid = Set(r.keys)
        retryAfter = retryAfter.filter { valid.contains($0.key) }
        // 手动起始/自动回退变化清首选；候选顺序或成员变化只提升代次作废旧计划，保留仍有效的首选。
        for fake in config.fakes {
            guard let prior = previous[fake.id] else { continue }
            let manualChanged = prior.manualStart != fake.selectedRemoteID
                || prior.autoFallback != fake.autoFallback
            if manualChanged || prior.ordered != fake.orderedRemoteIDs {
                selectionEpochs[fake.id, default: 0] += 1
            }
            if manualChanged {
                activeRemoteIDs.removeValue(forKey: fake.id)
            }
        }
        let validFakeIDs = Set(config.fakes.map(\.id))
        selectionEpochs = selectionEpochs.filter { validFakeIDs.contains($0.key) }
        activeRemoteIDs = activeRemoteIDs.filter { fakeID, remoteID in
            guard valid.contains(remoteID),
                  let fake = config.fakes.first(where: { $0.id == fakeID }) else { return false }
            return fake.orderedRemoteIDs.contains(remoteID)
                && (fake.autoFallback || fake.startingRemoteID == remoteID)
        }
        lock.unlock()
    }

    /// 只按 fakeModelID 路由；入站 API 格式由具体请求路径决定。
    func route(fakeModelID: String?) -> (fake: FakeModel, remote: RemoteModel)? {
        lock.lock()
        defer { lock.unlock() }
        guard let want = fakeModelID, let fake = fakesByID[want]
        else { return nil }
        guard let rid = fake.startingRemoteID,
              let remote = remotes[rid]
        else { return nil }
        return (fake, remote)
    }

    /// fake 存在但未绑定远端时，用于区分 404（id 不存在）和 502（未配置）
    func hasFake(fakeModelID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return fakesByID[fakeModelID] != nil
    }

    /// 全部 fake id（错误信息里列 known_models 用）
    func fakeIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return allFakes.map(\.fakeModelID)
    }

    /// /v1/models 用：全部 fake（config 顺序；重复的 fakeModelID 只列一次）
    func fakes() -> [FakeModel] {
        lock.lock()
        defer { lock.unlock() }
        var seen = Set<String>()
        return allFakes.filter { seen.insert($0.fakeModelID).inserted }
    }

    /// 至少有一个已绑定远端支持 `endpoint` 的 fake（config 顺序；id 去重）。
    /// 用 effective supports（含 Chat→Responses 覆盖与连接器注册/就绪把关），本地
    /// Gemini `models.list`/`models.get` 只暴露这些「Gemini 兼容」路由。
    func fakes(supporting endpoint: EndpointKind) -> [FakeModel] {
        lock.lock()
        defer { lock.unlock() }
        let settings = extensions
        let ready = connectorReady
        let registry = self.registry
        var seen = Set<String>()
        return allFakes.filter { fake in
            guard seen.insert(fake.fakeModelID).inserted else { return false }
            return fake.orderedRemoteIDs.contains { id in
                guard let remote = remotes[id] else { return false }
                if case .connector(let source) = settings.adapter(for: remote, endpoint: endpoint),
                   !(ready[source] ?? false) {
                    return false
                }
                return settings.supports(endpoint, remote: remote, registry: registry)
            }
        }
    }
}

// MARK: - ConfigStore

/// 配置写盘结果。
enum ConfigSaveOutcome: Equatable, Sendable {
    /// 已成功原子写盘。
    case saved
    /// 磁盘配置此前解析失败（`writeBlocked`），主动跳过写盘以保护原文件不被覆盖。
    case blocked
    /// 编码或 I/O 失败；关联值为可展示的原因。
    case failed(String)

    /// 是否真正写入磁盘。
    var succeeded: Bool { self == .saved }

    /// 失败时给 CLI/日志的一句话说明；成功为 nil。
    var failureMessage: String? {
        switch self {
        case .saved:
            return nil
        case .blocked:
            return "route changed in memory but not saved: the on-disk config cannot be parsed, "
                + "so the file was left untouched to protect it; the change may not survive a restart"
        case .failed(let reason):
            return "route changed in memory but not saved: \(reason); "
                + "the change may not survive a restart"
        }
    }
}

@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published private(set) var config: AppConfig
    @Published var serverError: String?
    /// 磁盘配置解析失败的原因（nil = 正常）。失败时使用空安全配置、绝不写盘覆盖原文件，
    /// 也不把示例 routes 呈现给用户；成功 reload 后自动解除。
    @Published private(set) var configLoadError: String?
    /// 服务真正成功监听的端口（nil = 还没起来）；用于设置页显示"运行中: X"
    @Published private(set) var runningPort: Int?

    let configURL: URL
    let router: Router
    /// 扩展连接器注册表；与 router 使用同一份，保证筛选与写入一致。
    let registry: ExtensionRegistry
    /// 用量统计存储；数据库懒开，record 非阻塞不抛错（失败只影响统计，不影响代理）。
    let usageStore: UsageStore

    private var server: RouterServer?
    private var cliServer: CLIControlServer?
    private var dirSource: DispatchSourceFileSystemObject?
    private var reloadTask: Task<Void, Never>?
    private var started = false
    /// 磁盘配置解析失败期间禁止写盘，避免用内存中的空配置覆盖用户的原始文件。
    private var writeBlocked = false

    convenience init() {
        self.init(configURL: ConfigStore.resolveConfigURL(), startsWatching: true)
    }

    init(configURL url: URL, startsWatching: Bool = false,
         registry: ExtensionRegistry = .builtIn) {
        self.configURL = url
        self.registry = registry
        self.router = Router(registry: registry)
        self.usageStore = UsageStore(url: UsageStore.databaseURL(for: url))
        let (loaded, shouldPersistMigration, loadError) = ConfigStore.loadOrCreate(at: url)
        let (baseNormalized, didNormalizeBaseURLs) = ConfigStore.normalizeBaseURLs(loaded)
        let (merged, didMerge) = ConfigStore.mergeDuplicateRemotes(baseNormalized)
        let (normalizedFakes, didNormalizeFakes) = ConfigStore.normalizeFakes(merged)
        let (prunedChat, didPruneSelection) = ConfigStore.pruneExtensionSelections(normalizedFakes)
        let (prunedConfig, didPruneConnector) = ConfigStore.pruneConnectorBindings(prunedChat,
                                                                                  registry: registry)
        self.config = prunedConfig
        self.configLoadError = loadError
        self.writeBlocked = loadError != nil
        router.update(self.config)
        if let loadError {
            Log.shared.log("config: \(url.path) 解析失败，已启用空安全配置并禁止写盘：\(loadError)")
        } else {
            Log.shared.log("config: \(url.path) (\(self.config.remotes.count) remotes, \(self.config.fakes.count) fakes)")
        }
        if loadError == nil,
           didNormalizeBaseURLs || didMerge || didNormalizeFakes || didPruneSelection
            || didPruneConnector || shouldPersistMigration {
            if shouldPersistMigration {
                Log.shared.log("config: 迁移旧远端字段为三协议配置，写回文件")
            }
            if didNormalizeBaseURLs {
                Log.shared.log("config: 规范化远端 Base URL，写回文件")
            }
            if didMerge {
                Log.shared.log("config: 合并 \(baseNormalized.remotes.count - merged.remotes.count) 条重复远端，写回文件")
            }
            if didNormalizeFakes {
                Log.shared.log("config: 合并 \(merged.fakes.count - normalizedFakes.fakes.count) 条重复路由，写回文件")
            }
            if didPruneSelection {
                Log.shared.log("config: 清理已不存在供应商的扩展选择，写回文件")
            }
            if didPruneConnector {
                Log.shared.log("config: 清理已不存在供应商的连接器绑定，写回文件")
            }
            save()
        }
        if startsWatching { startWatching() }
    }

    /// 把扩展里保存的供应商选择与现存供应商求交，避免外部编辑删除供应商后留下
    /// 隐藏规则、随后 addProvider 同名被幽灵继承。只清理名字，不动 enabled / 其它设置。
    static func pruneExtensionSelections(_ config: AppConfig) -> (AppConfig, Bool) {
        let providers = Set(config.remotes.map { splitProviderModel($0.name).provider })
        let selected = config.extensions.chatToResponses.providerNames
        let pruned = selected.intersection(providers)
        var out = config
        var changed = false
        if pruned != selected {
            out.extensions.chatToResponses.providerNames = pruned
            changed = true
        }
        if BuiltinExtensions.pruneSelections(&out) { changed = true }
        return (out, changed)
    }

    /// 只对「能验证的注册连接器来源」清理悬空绑定：绑定的供应商名不再是该来源的现存
    /// 供应商（删除/改名遗留，或同名被原生 API 占回），或 added-but-no-name 不一致态。
    /// 未注册扩展键的 JSON 原样保留、永不触碰；只清理绑定，不动 enabled。
    static func pruneConnectorBindings(_ config: AppConfig,
                                       registry: ExtensionRegistry = .builtIn) -> (AppConfig, Bool) {
        var out = config
        var changed = false
        for definition in registry.registeredConnectors {
            let sourceNames = Set(out.remotes.filter { $0.source == definition.source }
                .map { splitProviderModel($0.name).provider })
            var binding = out.extensions.connectorSettings(for: definition.settingsKey)
            guard binding.providerName != nil || binding.providerAdded else { continue }
            let staleName = binding.providerName.map { !sourceNames.contains($0) } ?? false
            let inconsistent = binding.providerName == nil && binding.providerAdded
            guard staleName || inconsistent else { continue }
            binding.providerName = nil
            binding.providerAdded = false
            out.extensions.setConnectorSettings(binding, for: definition.settingsKey)
            changed = true
        }
        return (out, changed)
    }

    /// Base URL 是完整前缀，只去掉无关的结尾斜杠；不再剥离 `/v1`。
    static func normalizeBaseURLs(_ config: AppConfig) -> (AppConfig, Bool) {
        var out = config
        var changed = false
        for i in out.remotes.indices {
            for kind in EndpointKind.allCases {
                let current = out.remotes[i].apiEndpoints[kind]
                guard !current.baseURL.isEmpty else { continue }
                let normalized = normalizeBaseURL(current.baseURL)
                if normalized != current.baseURL {
                    out.remotes[i].apiEndpoints[kind].baseURL = normalized
                    changed = true
                }
            }
        }
        return (out, changed)
    }

    /// 合并 name+apiKey+model+三协议配置完全相同的远端，保留先出现的那条；
    /// 指向被合并掉那条的 fake 改指保留的那条（否则这些 fake 会变成"未配置"）。
    /// 返回 (新配置, 是否发生了合并)
    static func mergeDuplicateRemotes(_ config: AppConfig) -> (AppConfig, Bool) {
        var merged: [RemoteModel] = []
        var indexOf: [String: Int] = [:]
        var remap: [UUID: UUID] = [:]   // 被合并掉 → 保留的
        for r in config.remotes {
            let endpoints = EndpointKind.allCases.map { kind -> String in
                let setting = r.apiEndpoints[kind]
                return "\(kind.rawValue):\(setting.enabled):\(setting.baseURL)"
            }.joined(separator: "\u{1E}")
            let key = [r.source.rawValue, r.name, r.apiKey, r.model, endpoints].joined(separator: "\u{1F}")
            if let i = indexOf[key] {
                remap[r.id] = merged[i].id
            } else {
                indexOf[key] = merged.count
                merged.append(r)
            }
        }
        guard !remap.isEmpty else { return (config, false) }
        var fakes = config.fakes
        for i in fakes.indices {
            let ids = fakes[i].orderedRemoteIDs.map { remap[$0] ?? $0 }
            var seen = Set<UUID>()
            let unique = ids.filter { seen.insert($0).inserted }
            fakes[i].remoteID = unique.first
            fakes[i].fallbackRemoteIDs = Array(unique.dropFirst())
            if let selected = fakes[i].selectedRemoteID {
                fakes[i].selectedRemoteID = remap[selected] ?? selected
            }
        }
        var out = config
        out.remotes = merged
        out.fakes = fakes
        return (out, true)
    }

    /// 旧配置可能按 API 类型为同一 fakeModelID 保存多条记录；现在只保留一条，
    /// 并优先保留第一条能解析到现有远端的绑定。
    static func normalizeFakes(_ config: AppConfig) -> (AppConfig, Bool) {
        var order: [String] = []
        var byID: [String: FakeModel] = [:]
        var changed = false
        let validRemoteIDs = Set(config.remotes.map(\.id))
        for original in config.fakes {
            var fake = original
            let valid = fake.orderedRemoteIDs.filter { validRemoteIDs.contains($0) }
            if valid != fake.orderedRemoteIDs || (fake.remoteID == nil && !valid.isEmpty) {
                fake.remoteID = valid.first
                fake.fallbackRemoteIDs = Array(valid.dropFirst())
                changed = true
            }
            if let selected = fake.selectedRemoteID, !valid.contains(selected) {
                fake.selectedRemoteID = nil
                changed = true
            }
            if var existing = byID[fake.fakeModelID] {
                changed = true
                if existing.remoteID == nil, fake.remoteID != nil {
                    existing.remoteID = fake.remoteID
                    existing.fallbackRemoteIDs = fake.fallbackRemoteIDs
                    existing.selectedRemoteID = fake.selectedRemoteID
                    byID[fake.fakeModelID] = existing
                }
            } else {
                byID[fake.fakeModelID] = fake
                order.append(fake.fakeModelID)
            }
        }
        guard changed else { return (config, false) }
        var out = config
        out.fakes = order.compactMap { byID[$0] }
        return (out, true)
    }

    nonisolated static func resolveConfigURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let p = environment["EZSWITCH_CONFIG"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        if let p = environment["MODEL_ROUTER_CONFIG"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let configURL = base.appendingPathComponent("EZSwitch/config.json")
        let legacyURL = base.appendingPathComponent("ModelRouter/config.json")
        let fm = FileManager.default
        if !fm.fileExists(atPath: configURL.path), fm.fileExists(atPath: legacyURL.path) {
            do {
                try fm.createDirectory(at: configURL.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: legacyURL, to: configURL)
                Log.shared.log("config: migrated legacy config to \(configURL.path)")
            } catch {
                Log.shared.log("config: legacy config migration failed, continue using \(legacyURL.path): \(error)")
                return legacyURL
            }
        }
        return configURL
    }

    /// 文件不存在 → 建目录 + 写默认示例配置；解码失败 → 使用**空安全配置**并返回错误，
    /// 绝不写盘、绝不呈现示例 routes（保护用户原文件）。
    /// 第二个返回值表示磁盘上仍是旧字段结构，需要在内存迁移后强制写回。
    /// 第三个返回值是解析失败原因（nil = 正常）。
    private static func loadOrCreate(at url: URL) -> (AppConfig, Bool, String?) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            let example = AppConfig.example()
            if let data = try? Self.encoder.encode(example) {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    try data.write(to: url, options: .atomic)
                    Log.shared.log("config: wrote default example to \(url.path)")
                } catch {
                    Log.shared.log("config: cannot write default config: \(error)")
                }
            }
            return (example, false, nil)
        }
        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(AppConfig.self, from: data)
            return (config, hasLegacyRemoteFields(data) || hasLegacyTransportFields(data), nil)
        } catch {
            Log.shared.log("config: decode failed (\(error)) — 保持原文件不变，使用空安全配置并禁止写盘")
            return (AppConfig(), false, "配置文件无法解析，已忽略且不会覆盖原文件：\(error)")
        }
    }

    private nonisolated static func hasLegacyRemoteFields(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let remotes = root["remotes"] as? [[String: Any]] else { return false }
        return remotes.contains {
            $0["baseURL"] != nil || $0["endpoint"] != nil || $0["endpoints"] != nil
        }
    }

    /// 磁盘上仍是旧「Responses 接入方式」结构（有 responsesTransport 且尚无
    /// 顶层 extensions）→ 内存迁移后需要写回，避免每次启动重复迁移。
    private nonisolated static func hasLegacyTransportFields(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["extensions"] == nil,
              let remotes = root["remotes"] as? [[String: Any]] else { return false }
        return remotes.contains { remote in
            guard let endpoints = remote["apiEndpoints"] as? [String: Any] else { return false }
            return endpoints["responsesTransport"] != nil
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    // MARK: 操作

    /// 给指定路由换绑远端；返回写盘结果，nil = 未应用（fake 或 remote 不存在）。
    @discardableResult
    func setRoute(fakeID: UUID, remoteID: UUID?) -> ConfigSaveOutcome? {
        guard let idx = config.fakes.firstIndex(where: { $0.id == fakeID }) else { return nil }
        let fake = config.fakes[idx]
        var name = "未配置"
        if let rid = remoteID {
            guard let remote = config.remotes.first(where: { $0.id == rid }) else {
                Log.shared.log("route: 拒绝 — remote \(rid) 不存在")
                return nil
            }
            name = remote.name
        }
        config.fakes[idx].remoteID = remoteID
        config.fakes[idx].selectedRemoteID = nil
        if remoteID == nil { config.fakes[idx].fallbackRemoteIDs = [] }
        else { config.fakes[idx].fallbackRemoteIDs.removeAll { $0 == remoteID } }
        router.update(config)
        let outcome = save()
        Log.shared.log("route switch: \(fake.fakeModelID) -> \(name)")
        return outcome
    }

    @discardableResult
    func setRouteTargets(fakeID: UUID, remoteIDs: [UUID], autoFallback: Bool) -> Bool {
        guard let idx = config.fakes.firstIndex(where: { $0.id == fakeID }) else { return false }
        let valid = Set(config.remotes.map(\.id))
        guard remoteIDs.allSatisfy(valid.contains), Set(remoteIDs).count == remoteIDs.count else { return false }
        config.fakes[idx].remoteID = remoteIDs.first
        config.fakes[idx].fallbackRemoteIDs = Array(remoteIDs.dropFirst())
        if let selected = config.fakes[idx].selectedRemoteID, !remoteIDs.contains(selected) {
            config.fakes[idx].selectedRemoteID = nil
        }
        config.fakes[idx].autoFallback = autoFallback
        router.update(config)
        save()
        Log.shared.log("route targets: \(config.fakes[idx].fakeModelID) -> \(remoteIDs.count) models")
        return true
    }

    /// 选中候选远端作为运行期首选并落盘；返回是否命中该候选。写盘失败仅记日志。
    @discardableResult
    func selectRouteModel(fakeID: UUID, remoteID: UUID) -> Bool {
        applyRouteSelection(fakeID: fakeID, remoteID: remoteID) != nil
    }

    /// 同 `selectRouteModel`，但把写盘结果回传；nil = 未命中候选。
    @discardableResult
    func selectRouteModelOutcome(fakeID: UUID, remoteID: UUID) -> ConfigSaveOutcome? {
        applyRouteSelection(fakeID: fakeID, remoteID: remoteID)
    }

    private func applyRouteSelection(fakeID: UUID, remoteID: UUID) -> ConfigSaveOutcome? {
        guard let index = config.fakes.firstIndex(where: { $0.id == fakeID }),
              config.fakes[index].orderedRemoteIDs.contains(remoteID) else { return nil }
        config.fakes[index].selectedRemoteID = remoteID == config.fakes[index].remoteID ? nil : remoteID
        router.update(config)
        router.selectRemote(fakeID: fakeID, remoteID: remoteID)
        let outcome = save()
        Log.shared.log("route select: \(config.fakes[index].fakeModelID) -> \(remoteID)")
        return outcome
    }

    /// 新增一个路由；fakeModelID 全局唯一，为空或重复则拒绝。
    @discardableResult
    func addFake(fakeModelID: String, remoteID: UUID?) -> Bool {
        let id = fakeModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            Log.shared.log("fake: 拒绝 — model id 为空")
            return false
        }
        guard !config.fakes.contains(where: { $0.fakeModelID == id }) else {
            Log.shared.log("fake: 拒绝 — \(id) 已存在")
            return false
        }
        let fake = FakeModel(id: UUID(), fakeModelID: id, displayName: id, remoteID: remoteID)
        config.fakes.append(fake)
        router.update(config)
        save()
        Log.shared.log("fake: 新增 \(id) → \(routeName(for: fake))")
        return true
    }

    /// 删除 fake 路由；删除后对应模型 ID 的请求返回 404。
    func removeFake(id: UUID) {
        guard let idx = config.fakes.firstIndex(where: { $0.id == id }) else { return }
        let fake = config.fakes.remove(at: idx)
        router.update(config)
        save()
        Log.shared.log("fake: 删除 \(fake.fakeModelID)（剩 \(config.fakes.count) 个 fake）")
    }

    /// 拖动排序：config.fakes 的顺序就是菜单栏里的显示顺序。
    func moveFakes(from source: IndexSet, to destination: Int) {
        var reordered = config.fakes
        reordered.move(fromOffsets: source, toOffset: destination)
        guard reordered != config.fakes else { return }
        config.fakes = reordered
        router.update(config)
        save()
        Log.shared.log("fake: 排序更新（\(config.fakes.count) 个）")
    }

    /// 行尾展示：当前绑定远端的模型 id（未绑定 → "未配置"）
    func boundModelID(for fake: FakeModel) -> String {
        guard let rid = fake.startingRemoteID,
              let r = config.remotes.first(where: { $0.id == rid })
        else { return "未配置" }
        return r.model
    }

    /// macOS 27 拖拽重排的落点：把若干 fake 移到 target 之前（target nil = 末尾）。
    func moveFakes(sources: [UUID], before target: UUID?) {
        let moving = config.fakes.filter { sources.contains($0.id) }
        guard !moving.isEmpty else { return }
        let to: Int
        if let t = target {
            guard let ti = config.fakes.firstIndex(where: { $0.id == t }) else { return }
            to = ti
        } else {
            to = config.fakes.count
        }
        let idxs = moving.compactMap { m in config.fakes.firstIndex(where: { $0.id == m.id }) }
        guard !idxs.isEmpty else { return }
        moveFakes(from: IndexSet(idxs), to: to)
    }

    /// 相对移动（-1 上移 / +1 下移）；已是列表边缘则不动
    func nudgeFake(id: UUID, by delta: Int) {
        guard let idx = config.fakes.firstIndex(where: { $0.id == id }) else { return }
        if delta < 0 {
            guard idx > 0 else { return }
            moveFakes(from: IndexSet(integer: idx), to: idx - 1)
        } else {
            guard idx + 1 < config.fakes.count else { return }
            moveFakes(from: IndexSet(integer: idx), to: idx + 2)
        }
    }

    /// 移到列表顶部 / 底部
    func moveFakeToGroupEdge(id: UUID, top: Bool) {
        guard let idx = config.fakes.firstIndex(where: { $0.id == id }) else { return }
        if top {
            moveFakes(from: IndexSet(integer: idx), to: 0)
        } else {
            moveFakes(from: IndexSet(integer: idx), to: config.fakes.count)
        }
    }

    /// 编辑一个 fake；返回中文错误信息，nil = 成功
    @discardableResult
    func updateFake(id: UUID, fakeModelID: String, remoteID: UUID?) -> String? {
        guard let idx = config.fakes.firstIndex(where: { $0.id == id }) else {
            Log.shared.log("fake: 更新失败 — \(id) 不存在")
            return "这个 fake model 已不存在"
        }
        let mid = fakeModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mid.isEmpty else { return "模型 ID 不能为空" }
        guard !config.fakes.contains(where: {
            $0.id != id && $0.fakeModelID == mid
        }) else {
            return "\(mid) 已存在"
        }
        config.fakes[idx].fakeModelID = mid
        config.fakes[idx].displayName = mid
        config.fakes[idx].remoteID = remoteID
        config.fakes[idx].selectedRemoteID = nil
        if remoteID == nil { config.fakes[idx].fallbackRemoteIDs = [] }
        else { config.fakes[idx].fallbackRemoteIDs.removeAll { $0 == remoteID } }
        router.update(config)
        save()
        Log.shared.log("fake: 更新 \(mid) → \(routeName(for: config.fakes[idx]))")
        return nil
    }

    // MARK: 远端

    /// 供应商作为整体排序；旧配置即使交错存放模型，也按分组后的顺序写回。
    func moveProviders(sources: [String], before target: String?) {
        var groups = groupedRemotes()
        let sourceSet = Set(sources)
        guard !sourceSet.isEmpty,
              sourceSet.count == sources.count,
              sources.allSatisfy({ name in groups.contains(where: { $0.provider == name }) })
        else { return }
        guard let destination = target.flatMap({ name in groups.firstIndex(where: { $0.provider == name }) })
                ?? (target == nil ? groups.count : nil),
              target.map({ !sourceSet.contains($0) }) ?? true else { return }
        let offsets = IndexSet(groups.indices.filter { sourceSet.contains(groups[$0].provider) })
        groups.move(fromOffsets: offsets, toOffset: destination)
        let reordered = groups.flatMap(\.remotes)
        guard reordered != config.remotes else { return }
        config.remotes = reordered
        router.update(config)
        save()
        Log.shared.log("provider: 排序更新（\(groups.count) 个）")
    }

    /// 模型只在所属供应商内排序，不改变其他供应商在配置中的位置。
    func moveModels(provider: String, sources: [UUID], before target: UUID?) {
        let indices = config.remotes.indices.filter {
            splitProviderModel(config.remotes[$0].name).provider == provider
        }
        var models = indices.map { config.remotes[$0] }
        let sourceSet = Set(sources)
        guard !sourceSet.isEmpty, sourceSet.count == sources.count,
              sources.allSatisfy({ id in models.contains(where: { $0.id == id }) }) else { return }
        guard let destination = target.flatMap({ id in models.firstIndex(where: { $0.id == id }) })
                ?? (target == nil ? models.count : nil),
              target.map({ !sourceSet.contains($0) }) ?? true else { return }
        let offsets = IndexSet(models.indices.filter { sourceSet.contains(models[$0].id) })
        let original = models
        models.move(fromOffsets: offsets, toOffset: destination)
        guard models != original else { return }
        for (index, model) in zip(indices, models) { config.remotes[index] = model }
        router.update(config)
        save()
        Log.shared.log("remote: \(provider) 模型排序更新（\(models.count) 个）")
    }

    @discardableResult
    func addRemote(_ remote: RemoteModel) -> String? {
        let parsed = splitProviderModel(remote.name)
        let provider = parsed.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayModel = parsed.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = remote.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayModel.isEmpty, !model.isEmpty else { return "模型 ID 不能为空" }
        guard !provider.isEmpty else { return "供应商名称不能为空或包含 · 分隔符" }
        guard !config.remotes.contains(where: {
            splitProviderModel($0.name).provider.trimmingCharacters(in: .whitespacesAndNewlines)
                == provider
                && $0.model.trimmingCharacters(in: .whitespacesAndNewlines) == model
        }) else { return "该供应商下模型 ID 已存在" }
        guard !config.remotes.contains(where: {
            splitProviderModel($0.name).provider.trimmingCharacters(in: .whitespacesAndNewlines)
                == provider
        }) else { return "该供应商名称已存在" }

        var remote = remote
        remote.name = remote.name.trimmingCharacters(in: .whitespacesAndNewlines)
        remote.model = model
        let endpoints = Self.normalizedEndpoints(remote.apiEndpoints)
        if let error = Self.validateEndpoints(endpoints) { return error }
        remote.apiEndpoints = endpoints
        config.remotes.append(remote)
        router.update(config)
        save()
        Log.shared.log("remote: 新增 \(remote.name) → \(remote.endpointSummary)")
        return nil
    }

    @discardableResult
    func addProvider(name: String, modelIDs: [String], apiKey: String,
                     extraHeaders: [String: String], apiEndpoints: APIEndpointSettings) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(" · ") else { return "供应商名称不能为空或包含 · 分隔符" }
        guard !config.remotes.contains(where: { splitProviderModel($0.name).provider == name })
        else { return "该供应商名称已存在" }
        let models = modelIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !models.isEmpty, models.allSatisfy({ !$0.isEmpty }) else { return "请选择至少一个模型" }
        guard Set(models).count == models.count else { return "模型 ID 重复" }
        let endpoints = Self.normalizedEndpoints(apiEndpoints)
        if let error = Self.validateEndpoints(endpoints) { return error }
        config.remotes.append(contentsOf: models.map {
            RemoteModel(id: UUID(), name: "\(name) · \($0)", apiKey: apiKey, model: $0,
                        extraHeaders: extraHeaders, apiEndpoints: endpoints)
        })
        router.update(config)
        save()
        Log.shared.log("provider: 新增 \(name)（\(models.count) 个模型）")
        return nil
    }

    /// 供应商下所有模型共用同一份连接配置；不存在或不一致时返回可展示的错误。
    private func unifiedProviderConfig(_ provider: String)
        -> (template: RemoteModel?, members: [RemoteModel], error: String?) {
        let members = config.remotes.filter { splitProviderModel($0.name).provider == provider }
        guard let first = members.first else { return (nil, members, "供应商已不存在，请重新打开设置") }
        guard members.allSatisfy({ $0.source == first.source })
        else { return (nil, members, "该供应商的连接来源不一致，请先在供应商设置中统一") }
        guard members.allSatisfy({ $0.apiEndpoints == first.apiEndpoints })
        else { return (nil, members, "该供应商的接口配置不一致，请先在供应商设置中统一") }
        guard members.allSatisfy({ $0.apiKey == first.apiKey })
        else { return (nil, members, "该供应商的 API Key 不一致，请先在供应商设置中统一") }
        guard members.allSatisfy({ $0.extraHeaders == first.extraHeaders })
        else { return (nil, members, "该供应商的额外请求头不一致，请先在供应商设置中统一") }
        return (first, members, nil)
    }

    /// 新增供应商下的模型：连接来源、凭据和协议配置复制该供应商的统一配置。
    @discardableResult
    func addModel(provider: String, model: String) -> String? {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return "模型 ID 不能为空" }
        let (template, members, error) = unifiedProviderConfig(provider)
        guard let first = template else { return error }
        guard !members.contains(where: { $0.model == model }) else { return "该供应商下模型 ID 已存在" }

        let remote = RemoteModel(id: UUID(), name: "\(provider) · \(model)",
                                 apiKey: first.apiKey, model: model, extraHeaders: first.extraHeaders,
                                 apiEndpoints: first.apiEndpoints, source: first.source)
        config.remotes.append(remote)
        router.update(config)
        save()
        Log.shared.log("remote: 新增 \(remote.name) → \(remote.endpointSummary)")
        return nil
    }

    /// 编辑模型只改模型 ID 与名称；Base URL、API Key、请求头沿用当前供应商配置。
    @discardableResult
    func updateModel(id: UUID, model: String) -> String? {
        guard let idx = config.remotes.firstIndex(where: { $0.id == id }) else {
            Log.shared.log("remote: 更新失败 — \(id) 不存在")
            return "这个模型已不存在"
        }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return "模型 ID 不能为空" }
        let current = config.remotes[idx]
        let provider = splitProviderModel(current.name).provider
        guard !config.remotes.contains(where: {
            $0.id != id && splitProviderModel($0.name).provider == provider && $0.model == model
        }) else { return "该供应商下模型 ID 已存在" }

        let name = current.name.range(of: " · ") == nil ? model : "\(provider) · \(model)"
        config.remotes[idx].name = name
        config.remotes[idx].model = model
        router.update(config)
        save()
        Log.shared.log("remote: 更新 \(name) → \(config.remotes[idx].endpointSummary)")
        return nil
    }

    /// 供应商共用字段一次提交，模型 ID 和路由引用保持不变。改名到已存在的供应商
    /// 一律拒绝；合法改名时同步迁移扩展里保存的供应商名。连接器来源的供应商只允许
    /// 改名，拒绝改接口 / 凭据 / 请求头（凭据由扩展自身持有，native 端点恒为关闭）。
    func updateProvider(_ provider: String, name: String, apiEndpoints: APIEndpointSettings?,
                        apiKey: String?, extraHeaders: [String: String]?) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(" · ") else { return "供应商名称不能为空或包含 · 分隔符" }
        guard name == provider || !config.remotes.contains(where: { splitProviderModel($0.name).provider == name }) else {
            return "该供应商名称已存在"
        }
        let indices = config.remotes.indices.filter { splitProviderModel(config.remotes[$0].name).provider == provider }
        guard !indices.isEmpty else { return "供应商已不存在，请重新打开设置" }
        let isConnector = indices.allSatisfy { !config.remotes[$0].source.isAPI }
        if isConnector, apiEndpoints != nil || apiKey != nil || extraHeaders != nil {
            return "连接器供应商只支持改名，不支持修改接口、凭据或请求头"
        }
        if let apiEndpoints, let error = Self.validateEndpoints(apiEndpoints) { return error }
        let sources = Set(indices.map { config.remotes[$0].source })
        for i in indices {
            config.remotes[i].name = "\(name) · \(config.remotes[i].model)"
            if let apiEndpoints { config.remotes[i].apiEndpoints = apiEndpoints }
            if let apiKey { config.remotes[i].apiKey = apiKey }
            if let extraHeaders { config.remotes[i].extraHeaders = extraHeaders }
        }
        if name != provider {
            migrateProviderSelection(from: provider, to: name)
            migrateConnectorProviderName(from: provider, to: name, sources: sources)
            BuiltinExtensions.providerRenamed(from: provider, to: name, in: &config)
        }
        router.update(config)
        save()
        Log.shared.log("provider: 更新 \(name)（\(indices.count) 个模型）")
        return nil
    }

    /// 改名和协议选择通过校验后统一保存，内部 HTTP 配置保持不变。
    @discardableResult
    func updateConnectorProvider(_ provider: String, name: String,
                                 enabledEndpoints: Set<EndpointKind>) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(" · ") else { return "供应商名称不能为空或包含 · 分隔符" }
        guard name == provider || !config.remotes.contains(where: { splitProviderModel($0.name).provider == name })
        else { return "该供应商名称已存在" }
        let indices = config.remotes.indices.filter { splitProviderModel(config.remotes[$0].name).provider == provider }
        guard !indices.isEmpty else { return "供应商已不存在，请重新打开设置" }
        let sources = Set(indices.map { config.remotes[$0].source })
        guard sources.count == 1, let source = sources.first, !source.isAPI else {
            return "该供应商不是连接器供应商，不支持协议开关"
        }
        guard let definition = registry.connector(for: source) else {
            return "该连接器来源未注册，只支持改名"
        }
        guard enabledEndpoints.isSubset(of: definition.endpoints) else { return "所选协议不被该连接器支持" }
        let settingsKey = definition.settingsKey
        var binding = config.extensions.connectorSettings(for: settingsKey)
        guard binding.providerName == provider else { return "该连接器供应商未绑定，请先在扩展页重新连接" }

        for i in indices {
            config.remotes[i].name = "\(name) · \(config.remotes[i].model)"
        }
        binding.enabledEndpoints = enabledEndpoints
        if name != provider {
            migrateProviderSelection(from: provider, to: name)
            binding.providerName = name
            BuiltinExtensions.providerRenamed(from: provider, to: name, in: &config)
        }
        config.extensions.setConnectorSettings(binding, for: settingsKey)
        router.update(config)
        save()
        Log.shared.log("provider: 更新连接器 \(name)（\(indices.count) 个模型，端点 \(enabledEndpoints.map(\.rawValue).sorted().joined(separator: ","))）")
        return nil
    }

    private func migrateProviderSelection(from old: String, to new: String) {
        var names = config.extensions.chatToResponses.providerNames
        guard names.contains(old) else { return }
        names.remove(old)
        names.insert(new)
        config.extensions.chatToResponses.providerNames = names
    }

    /// 供应商改名时同步迁移其连接器绑定名：只对「被改名远端自身 source 对应的已注册
    /// 定义」生效，未注册扩展的 JSON 永不改动。
    private func migrateConnectorProviderName(from old: String, to new: String,
                                              sources: Set<RemoteSource>) {
        for source in sources {
            guard let definition = registry.connector(for: source) else { continue }
            var binding = config.extensions.connectorSettings(for: definition.settingsKey)
            guard binding.providerName == old else { continue }
            binding.providerName = new
            config.extensions.setConnectorSettings(binding, for: definition.settingsKey)
        }
    }

    /// 某来源的供应商消失时清空其连接器绑定（含 providerAdded），避免悬空引用与幽灵继承。
    /// 只对该来源已注册的定义生效；未知扩展 JSON 保留。
    private func clearConnectorBinding(ifProvider provider: String, source: RemoteSource) {
        guard let definition = registry.connector(for: source) else { return }
        var binding = config.extensions.connectorSettings(for: definition.settingsKey)
        guard binding.providerName == provider else { return }
        binding.providerName = nil
        binding.providerAdded = false
        config.extensions.setConnectorSettings(binding, for: definition.settingsKey)
    }

    /// 删除远端并解绑全部引用。返回被解绑的模型 ID 列表。
    @discardableResult
    func removeRemote(id: UUID) -> [String] {
        guard let idx = config.remotes.firstIndex(where: { $0.id == id }) else { return [] }
        let remote = config.remotes.remove(at: idx)
        let provider = splitProviderModel(remote.name).provider
        // 该供应商最后一个模型被删 → 清掉扩展选择与该来源连接器绑定，重新添加同名供应商不会幽灵继承。
        if !config.remotes.contains(where: { splitProviderModel($0.name).provider == provider }) {
            config.extensions.chatToResponses.providerNames.remove(provider)
            clearConnectorBinding(ifProvider: provider, source: remote.source)
            BuiltinExtensions.providerRemoved(provider, in: &config)
        }
        var unbound: [String] = []
        for i in config.fakes.indices where config.fakes[i].orderedRemoteIDs.contains(id) {
            let remaining = config.fakes[i].orderedRemoteIDs.filter { $0 != id }
            config.fakes[i].remoteID = remaining.first
            config.fakes[i].fallbackRemoteIDs = Array(remaining.dropFirst())
            if let selected = config.fakes[i].selectedRemoteID, !remaining.contains(selected) {
                config.fakes[i].selectedRemoteID = nil
            }
            if remaining.isEmpty { unbound.append(config.fakes[i].fakeModelID) }
        }
        router.update(config)
        save()
        Log.shared.log("remote: 删除 \(remote.name)（剩 \(config.remotes.count) 个远端）")
        if !unbound.isEmpty {
            Log.shared.log("remote: 解绑 \(unbound.joined(separator: ", "))")
        }
        return unbound
    }

    /// 删除整个供应商及其全部模型，并解绑所有相关路由。
    @discardableResult
    func removeProvider(_ provider: String) -> [String] {
        let removed = config.remotes.filter { splitProviderModel($0.name).provider == provider }
        guard !removed.isEmpty else { return [] }
        let ids = Set(removed.map(\.id))
        config.remotes.removeAll { ids.contains($0.id) }
        config.extensions.chatToResponses.providerNames.remove(provider)
        for source in Set(removed.map(\.source)) {
            clearConnectorBinding(ifProvider: provider, source: source)
        }
        BuiltinExtensions.providerRemoved(provider, in: &config)

        var unbound: [String] = []
        for i in config.fakes.indices {
            let old = config.fakes[i].orderedRemoteIDs
            let remaining = old.filter { !ids.contains($0) }
            guard remaining.count != old.count else { continue }
            config.fakes[i].remoteID = remaining.first
            config.fakes[i].fallbackRemoteIDs = Array(remaining.dropFirst())
            if let selected = config.fakes[i].selectedRemoteID, !remaining.contains(selected) {
                config.fakes[i].selectedRemoteID = nil
            }
            if remaining.isEmpty { unbound.append(config.fakes[i].fakeModelID) }
        }
        router.update(config)
        save()
        Log.shared.log("provider: 删除 \(provider)（\(removed.count) 个远端，剩 \(config.remotes.count) 个远端）")
        if !unbound.isEmpty {
            Log.shared.log("provider: 解绑 \(unbound.joined(separator: ", "))")
        }
        return unbound
    }

    /// 供应商模型目录选择对账：只处理该供应商、且 model ID 在 choices 内的模型。
    /// 未勾选的现存模型按 removeRemote 清理，勾选但缺失的用 addModel 补建；
    /// 预校验失败时不做任何改动。返回可展示的错误，nil = 成功。
    @discardableResult
    func applyModelCatalogSelection(provider: String, choices: Set<String>, selected: Set<String>) -> String? {
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let wanted = selected.intersection(choices)
        let canonicalWanted = wanted.map(trim)
        let wantedSet = Set(canonicalWanted)
        let choiceSet = Set(choices.map(trim))
        let members = config.remotes.filter { splitProviderModel($0.name).provider == provider }
        let existingModels = Set(members.map { trim($0.model) })

        guard canonicalWanted.allSatisfy({ !$0.isEmpty }) else { return "模型 ID 不能为空" }
        var toAdd: [String] = []
        var seen = Set<String>()
        for id in canonicalWanted where !existingModels.contains(id) {
            guard seen.insert(id).inserted else { return "模型 ID 重复" }
            toAdd.append(id)
        }
        toAdd.sort()
        let toRemove = members.filter {
            let id = trim($0.model)
            return choiceSet.contains(id) && !wantedSet.contains(id)
        }
        guard !toAdd.isEmpty || !toRemove.isEmpty else { return nil }

        if !toAdd.isEmpty {
            let (template, _, error) = unifiedProviderConfig(provider)
            guard template != nil else { return error }
        }

        // 先新增（模板尚在），再清理；预校验已保证 addModel 不会失败。
        for model in toAdd {
            if let error = addModel(provider: provider, model: model) { return error }
        }
        for remote in toRemove {
            removeRemote(id: remote.id)
        }
        return nil
    }

    /// 供应商页：全部远端按供应商分组（组序 = 首次出现），query 对名称、模型、协议和 URL 过滤
    func remoteGroups(matching query: String) -> [RemoteGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var order: [String] = []
        var buckets: [String: [RemoteModel]] = [:]
        for r in config.remotes {
            if !q.isEmpty {
                let hay = (r.name + " " + r.model + " " + r.endpointSummary + " " + r.endpointBaseURLs.joined(separator: " ")).lowercased()
                if !hay.contains(q) { continue }
            }
            let p = splitProviderModel(r.name).provider
            if buckets[p] == nil { order.append(p) }
            buckets[p, default: []].append(r)
        }
        return order.map { RemoteGroup(provider: $0, remotes: buckets[$0]!) }
    }

    // MARK: 端口

    /// 端口 clamp 到 1...65535；改完写盘，进程已监听端口不变（需重启）
    func setPort(_ port: Int) {
        let p = min(max(port, 1), 65535)
        guard p != config.port else { return }
        config.port = p
        router.update(config)
        save()
        Log.shared.log("port: \(p)，重启后生效")
    }

    /// trim → 去掉结尾 "/"；版本路径属于 Base URL 的一部分，必须保留。
    nonisolated static func normalizeBaseURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    nonisolated static func isValidHTTPURL(_ raw: String) -> Bool {
        guard let u = URL(string: raw),
              let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = u.host, !host.isEmpty
        else { return false }
        return true
    }

    static func normalizedEndpoints(_ settings: APIEndpointSettings) -> APIEndpointSettings {
        var out = settings
        for kind in EndpointKind.allCases where !out[kind].baseURL.isEmpty {
            out[kind].baseURL = normalizeBaseURL(out[kind].baseURL)
        }
        return out
    }

    static func validateEndpoints(_ settings: APIEndpointSettings) -> String? {
        var enabled = 0
        for kind in EndpointKind.allCases {
            let setting = settings[kind]
            guard setting.enabled else { continue }
            enabled += 1
            let baseURL = normalizeBaseURL(setting.baseURL)
            if baseURL.isEmpty { return "\(kind.displayName) 已启用，请填写 Base URL" }
            if !isValidHTTPURL(baseURL) { return "\(kind.displayName) 的 Base URL 必须是有效的 http/https 地址" }
        }
        return enabled == 0 ? "至少启用一种接口协议" : nil
    }

    /// 写入磁盘；返回可检查的写盘结果。
    @discardableResult
    func save() -> ConfigSaveOutcome {
        guard !writeBlocked else {
            Log.shared.log("config: 跳过写盘 — 磁盘配置文件解析失败，保护原文件不被覆盖")
            return .blocked
        }
        do {
            let data = try ConfigStore.encoder.encode(config)
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: configURL, options: .atomic)
            return .saved
        } catch {
            Log.shared.log("config: save failed: \(error)")
            return .failed(String(describing: error))
        }
    }

    func reloadFromDisk() {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            Log.shared.log("reload: \(configURL.path) 不存在，跳过")
            return
        }
        do {
            let data = try Data(contentsOf: configURL)
            let shouldPersistMigration = ConfigStore.hasLegacyRemoteFields(data)
                || ConfigStore.hasLegacyTransportFields(data)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            // 文件已可解析：解除写盘保护与错误提示。
            // 仅当确有错误态时才赋值 —— @Published 每次赋值都会发 objectWillChange，
            // 无变化的重载（自写盘）不得因此多发布一次。
            writeBlocked = false
            if configLoadError != nil { configLoadError = nil }
            let oldPort = config.port
            let (baseNormalized, didNormalizeBaseURLs) = ConfigStore.normalizeBaseURLs(decoded)
            let (merged, didMerge) = ConfigStore.mergeDuplicateRemotes(baseNormalized)
            let (normalizedFakes, didNormalizeFakes) = ConfigStore.normalizeFakes(merged)
            let (prunedChat, didPruneSelection) = ConfigStore.pruneExtensionSelections(normalizedFakes)
            let (prunedConfig, didPruneConnector) = ConfigStore.pruneConnectorBindings(prunedChat,
                                                                                       registry: registry)
            let needsPersist = didNormalizeBaseURLs || didMerge || didNormalizeFakes
                || didPruneSelection || didPruneConnector || shouldPersistMigration
            // 文件监控也会收到本应用的写入；相同内容无需再次发布，但仍须保留迁移写回。
            if prunedConfig == config, !needsPersist {
                return
            }
            if prunedConfig != config {
                config = prunedConfig
                router.update(config)
                Log.shared.log("reload: ok (\(config.remotes.count) remotes)")
            }
            if needsPersist {
                if shouldPersistMigration {
                    Log.shared.log("reload: 迁移旧远端字段为三协议配置，写回文件")
                }
                if didNormalizeBaseURLs {
                    Log.shared.log("reload: 规范化远端 Base URL，写回文件")
                }
                if didMerge {
                    Log.shared.log("reload: 合并 \(baseNormalized.remotes.count - merged.remotes.count) 条重复远端，写回文件")
                }
                if didNormalizeFakes {
                    Log.shared.log("reload: 合并 \(merged.fakes.count - normalizedFakes.fakes.count) 条重复路由，写回文件")
                }
                if didPruneSelection {
                    Log.shared.log("reload: 清理已不存在供应商的扩展选择，写回文件")
                }
                if didPruneConnector {
                    Log.shared.log("reload: 清理已不存在供应商的连接器绑定，写回文件")
                }
                save()
            }
            if decoded.port != oldPort {
                Log.shared.log("reload: port \(oldPort) → \(decoded.port)，需重启生效")
            }
        } catch {
            // 解析失败：保留旧内存配置，进入写盘保护，绝不用坏文件或空配置覆盖磁盘。
            writeBlocked = true
            configLoadError = "配置文件无法解析，已忽略且不会覆盖原文件：\(error)"
            Log.shared.log("reload: decode failed, 保留旧配置并禁止写盘: \(error)")
        }
    }

    // MARK: 服务

    func startServer() {
        guard !started else { return }
        started = true
        // EZSWITCH_PORT 可覆盖监听端口；兼容旧 MODELROUTER_PORT，便于并行启动调试实例。
        let environment = ProcessInfo.processInfo.environment
        let port = (environment["EZSWITCH_PORT"] ?? environment["MODELROUTER_PORT"])
            .flatMap(Int.init) ?? config.port
        let notifications = AutoFallbackNotificationService.shared
        let s = RouterServer(router: router, usageStore: usageStore,
                             extensionRegistry: registry,
                             onAutoFallback: { event in
                                 Task { @MainActor in notifications.receive(event) }
                             })
        server = s
        do {
            try s.start(port: port)
            runningPort = port
            Log.shared.log("server: listening on http://127.0.0.1:\(port)")
            let control = CLIControlServer(configURL: configURL)
            do {
                try control.start(store: self)
                cliServer = control
                Log.shared.log("cli: listening on \(CLIControlPath.socket(for: configURL).path)")
            } catch {
                Log.shared.log("cli: start failed: \(error)")
            }
        } catch {
            serverError = "Server failed on port \(port): \(error)"
            Log.shared.log("server: start failed: \(error)")
        }
    }

    // MARK: 文件监控（watch 父目录：atomic save 会换 inode）

    private func startWatching() {
        let dir = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else {
            Log.shared.log("watch: 无法打开目录 \(dir.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                               eventMask: [.write, .delete, .rename, .extend],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirSource = source
        Log.shared.log("watch: \(dir.path)")
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.reloadFromDisk()
        }
    }

    // MARK: 菜单 / 管理窗口辅助

    /// 单个 fake 当前绑定的远端名（未配置 → "未配置"）
    func routeName(for fake: FakeModel) -> String {
        guard let rid = fake.startingRemoteID,
              let r = config.remotes.first(where: { $0.id == rid })
        else { return "未配置" }
        return r.name
    }

    /// 按供应商分组（组按首次出现排序，组内保持 remotes 原顺序）
    func groupedRemotes() -> [RemoteGroup] {
        var order: [String] = []
        var buckets: [String: [RemoteModel]] = [:]
        for r in config.remotes {
            let p = splitProviderModel(r.name).provider
            if buckets[p] == nil { order.append(p) }
            buckets[p, default: []].append(r)
        }
        return order.map { RemoteGroup(provider: $0, remotes: buckets[$0]!) }
    }

    // MARK: Chat → Responses 扩展

    /// 只切换总开关：保留已选供应商，不改动任何 native 配置。
    func setChatToResponsesEnabled(_ enabled: Bool) {
        guard config.extensions.chatToResponses.enabled != enabled else { return }
        config.extensions.chatToResponses.enabled = enabled
        router.update(config)
        save()
        Log.shared.log("extension chatToResponses: enabled=\(enabled)")
    }

    /// 勾选/取消供应商。取消始终允许；勾选要求该供应商全部模型 Chat 可用。
    /// 不满足时返回短中文原因且不做改动。
    @discardableResult
    func setChatToResponsesProvider(_ provider: String, selected: Bool) -> String? {
        let name = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.remotes.contains(where: { splitProviderModel($0.name).provider == name }) else {
            return "供应商已不存在，请重新打开设置"
        }
        if selected {
            if let reason = chatToResponsesUnavailableReason(for: name) { return reason }
            config.extensions.chatToResponses.providerNames.insert(name)
        } else {
            config.extensions.chatToResponses.providerNames.remove(name)
        }
        router.update(config)
        save()
        Log.shared.log("extension chatToResponses: \(name) selected=\(selected)")
        return nil
    }

    /// nil = 可选；否则返回不可选的短中文原因。
    func chatToResponsesUnavailableReason(for provider: String) -> String? {
        let name = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let members = config.remotes.filter { splitProviderModel($0.name).provider == name }
        guard !members.isEmpty else { return "供应商不存在" }
        let usable = members.allSatisfy { remote in
            let chat = remote.apiEndpoints.chat
            let url = ConfigStore.normalizeBaseURL(chat.baseURL)
            return chat.enabled && !url.isEmpty && ConfigStore.isValidHTTPURL(url)
        }
        return usable ? nil : "需先为该供应商启用 Chat Completions 并填写有效的 Base URL"
    }

    // MARK: 连接器扩展（通用）

    /// 通用扩展配置变更入口：具体扩展只提供变更闭包，更新 router 快照与落盘在此统一处理。
    /// 无实际变化时不做任何写入。
    func updateExtensions(_ mutate: (inout ExtensionSettings) -> Void) {
        var extensions = config.extensions
        mutate(&extensions)
        guard extensions != config.extensions else { return }
        config.extensions = extensions
        router.update(config)
        save()
    }

    /// 只切换某连接器总开关，保留绑定与供应商记录；关闭只让该来源候选不可用。
    func setConnectorEnabled(settingsKey: String, enabled: Bool) {
        var settings = config.extensions.connectorSettings(for: settingsKey)
        guard settings.enabled != enabled else { return }
        settings.enabled = enabled
        config.extensions.setConnectorSettings(settings, for: settingsKey)
        router.update(config)
        save()
        Log.shared.log("extension \(settingsKey): enabled=\(enabled)")
    }

    /// 原子创建/补齐某连接器来源的供应商记录并绑定。记录 source 为传入来源、
    /// apiKey 空、native 端点全关（不伪造 Base URL/凭据）；模型 ID 须来自已验证目录。
    /// 名字冲突时用唯一化名字，不劫持已有供应商；重复调用幂等。
    @discardableResult
    func addConnectorProvider(source: RemoteSource, settingsKey: String,
                              modelIDs: [String], named name: String) -> String? {
        // 只允许经登记的连接器来源创建记录：原生 HTTP 来源与未注册/键不匹配的来源一律拒绝，
        // 避免误用通用 API 造出「禁端点 .api 记录」或绑定到错误的设置键。
        guard !source.isAPI else { return "原生 HTTP 来源不能作为连接器供应商" }
        guard registry.connector(for: source)?.settingsKey == settingsKey else {
            return "连接器来源未注册或与设置键不匹配"
        }
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !base.contains(" · ") else { return "供应商名称不能为空或包含 · 分隔符" }
        let models = modelIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !models.isEmpty, models.allSatisfy({ !$0.isEmpty }) else { return "模型 ID 不能为空" }
        guard Set(models).count == models.count else { return "模型 ID 重复" }

        // 已绑定的该来源供应商优先（幂等）；否则取未占用名字。
        var settings = config.extensions.connectorSettings(for: settingsKey)
        let sourceNames = Set(config.remotes.filter { $0.source == source }
            .map { splitProviderModel($0.name).provider })
        let target = settings.providerName.flatMap { sourceNames.contains($0) ? $0 : nil }
            ?? uniqueProviderName(base: base)
        let existing = Set(config.remotes.filter { splitProviderModel($0.name).provider == target }
            .map(\.model))
        let toAdd = models.filter { !existing.contains($0) }
        let bindingChanged = settings.providerName != target || !settings.providerAdded
        guard !toAdd.isEmpty || bindingChanged else { return nil }

        config.remotes.append(contentsOf: toAdd.map {
            RemoteModel(id: UUID(), name: "\(target) · \($0)", apiKey: "", model: $0,
                        extraHeaders: [:],
                        apiEndpoints: APIEndpointSettings(chat: .disabled, responses: .disabled,
                                                          messages: .disabled),
                        source: source)
        })
        settings.providerName = target
        settings.providerAdded = true
        config.extensions.setConnectorSettings(settings, for: settingsKey)
        router.update(config)
        save()
        Log.shared.log("extension \(settingsKey): 绑定 \(target)（+\(toAdd.count) 个模型）")
        return nil
    }

    /// 唯一化供应商名：已占用时追加 " 2"、" 3"…，绝不覆盖已有供应商。
    private func uniqueProviderName(base: String) -> String {
        let taken = Set(config.remotes.map { splitProviderModel($0.name).provider })
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// 解除绑定但保留记录（记录随之不可用）；不删除供应商、模型或 route。
    func removeConnectorProvider(settingsKey: String) {
        var settings = config.extensions.connectorSettings(for: settingsKey)
        guard settings.providerName != nil || settings.providerAdded else { return }
        settings.providerName = nil
        settings.providerAdded = false
        config.extensions.setConnectorSettings(settings, for: settingsKey)
        router.update(config)
        save()
        Log.shared.log("extension \(settingsKey): 解除供应商绑定")
    }
}
