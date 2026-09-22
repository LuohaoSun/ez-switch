import Foundation
import Combine
import ServiceManagement
import SwiftUI   // Array.move(fromOffsets:toOffset:)（fake 排序）来自 SwiftUI

// MARK: - 数据模型

enum EndpointKind: String, Codable, CaseIterable {
    case chat, responses, messages

    var displayName: String {
        switch self {
        case .chat: return "Chat Completions"
        case .responses: return "Responses"
        case .messages: return "Messages"
        }
    }

    /// Base URL 之外的协议相对路径（纯反向代理，不做协议转换）。
    /// 例如 OpenAI 填 `https://api.openai.com/v1`，最终请求 `/v1/chat/completions`；
    /// GLM Coding Plan 填 `https://open.bigmodel.cn/api/coding/paas/v4`，最终请求
    /// `/api/coding/paas/v4/chat/completions`。
    var upstreamPath: String {
        switch self {
        case .chat: return "/chat/completions"
        case .responses: return "/responses"
        case .messages: return "/v1/messages"
        }
    }
}

struct EndpointSetting: Codable, Equatable, Hashable {
    var enabled: Bool
    var baseURL: String

    static let disabled = EndpointSetting(enabled: false, baseURL: "")
}

/// 供应商级协议配置。每个模型复制同一份配置，UI 只允许在供应商设置中修改。
struct APIEndpointSettings: Codable, Equatable, Hashable {
    var chat: EndpointSetting
    var responses: EndpointSetting
    var messages: EndpointSetting

    init(chat: EndpointSetting, responses: EndpointSetting, messages: EndpointSetting) {
        self.chat = chat
        self.responses = responses
        self.messages = messages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chat = try c.decodeIfPresent(EndpointSetting.self, forKey: .chat) ?? .disabled
        responses = try c.decodeIfPresent(EndpointSetting.self, forKey: .responses) ?? .disabled
        messages = try c.decodeIfPresent(EndpointSetting.self, forKey: .messages) ?? .disabled
    }

    subscript(kind: EndpointKind) -> EndpointSetting {
        get {
            switch kind {
            case .chat: return chat
            case .responses: return responses
            case .messages: return messages
            }
        }
        set {
            switch kind {
            case .chat: chat = newValue
            case .responses: responses = newValue
            case .messages: messages = newValue
            }
        }
    }

    var enabledKinds: [EndpointKind] {
        EndpointKind.allCases.filter { self[$0].enabled }
    }

    static func all(baseURL: String) -> APIEndpointSettings {
        APIEndpointSettings(
            chat: EndpointSetting(enabled: true, baseURL: baseURL),
            responses: EndpointSetting(enabled: true, baseURL: baseURL),
            messages: EndpointSetting(enabled: true, baseURL: baseURL)
        )
    }

    static func enabled(_ kinds: Set<EndpointKind>, baseURL: String) -> APIEndpointSettings {
        APIEndpointSettings(
            chat: EndpointSetting(enabled: kinds.contains(.chat), baseURL: kinds.contains(.chat) ? baseURL : ""),
            responses: EndpointSetting(enabled: kinds.contains(.responses), baseURL: kinds.contains(.responses) ? baseURL : ""),
            messages: EndpointSetting(enabled: kinds.contains(.messages), baseURL: kinds.contains(.messages) ? baseURL : "")
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

    init(id: UUID, name: String, apiKey: String, model: String,
         extraHeaders: [String: String], apiEndpoints: APIEndpointSettings) {
        self.id = id
        self.name = name
        self.apiKey = apiKey
        self.model = model
        self.extraHeaders = extraHeaders
        self.apiEndpoints = apiEndpoints
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, apiKey, model, extraHeaders, apiEndpoints
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
    }

    private static func inferLegacyEndpoints(baseURL: String) -> Set<EndpointKind> {
        let lower = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return [] }
        if lower.contains("open.bigmodel.cn/api/anthropic") {
            // GLM Coding Plan 同一份订阅分别提供 Chat / Responses / Messages 地址。
            return Set(EndpointKind.allCases)
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
        return Set(EndpointKind.allCases)
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
            }
        }

        switch kind {
        case .chat:
            return "https://open.bigmodel.cn/api/coding/paas/v4"
        case .responses:
            return "https://open.bigmodel.cn/api/v1"
        case .messages:
            return "https://open.bigmodel.cn/api/anthropic"
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

    func supports(_ kind: EndpointKind) -> Bool { apiEndpoints[kind].enabled }

    var endpointBaseURLs: [String] {
        EndpointKind.allCases.map { apiEndpoints[$0].baseURL }.filter { !$0.isEmpty }
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
}

struct AppConfig: Codable {
    var port: Int = 8788
    var remotes: [RemoteModel] = []
    var fakes: [FakeModel] = []
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
            id: UUID(), name: "DeepSeek官方 · deepseek-chat",
            apiKey: "sk-REPLACE-ME", model: "deepseek-chat", extraHeaders: [:],
            apiEndpoints: .enabled([.chat], baseURL: "https://api.deepseek.com/v1")
        )
        let openAI = RemoteModel(
            id: UUID(), name: "OpenAI官方 · gpt-5.2",
            apiKey: "sk-REPLACE-ME", model: "gpt-5.2", extraHeaders: [:],
            apiEndpoints: .enabled([.chat, .responses], baseURL: "https://api.openai.com/v1")
        )
        let remotes = [deepSeek, openAI]

        let fakes = [
            FakeModel(id: UUID(), fakeModelID: "main",
                      displayName: "main", remoteID: openAI.id),
        ]
        return AppConfig(port: 8788, remotes: remotes, fakes: fakes)
    }
}

// MARK: - Router（给 server 线程读，自带锁）

final class Router {
    private let lock = NSLock()
    private var remotes: [UUID: RemoteModel] = [:]
    private var fakesByID: [String: FakeModel] = [:]
    private var allFakes: [FakeModel] = []

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
        remotes = r
        fakesByID = f
        allFakes = config.fakes
        lock.unlock()
    }

    /// 只按 fakeModelID 路由；入站 API 格式由具体请求路径决定。
    func route(fakeModelID: String?) -> (fake: FakeModel, remote: RemoteModel)? {
        lock.lock()
        defer { lock.unlock() }
        guard let want = fakeModelID, let fake = fakesByID[want]
        else { return nil }
        guard let rid = fake.remoteID,
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
}

// MARK: - ConfigStore

@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published private(set) var config: AppConfig
    @Published var serverError: String?
    /// 服务真正成功监听的端口（nil = 还没起来）；用于设置页显示"运行中: X"
    @Published private(set) var runningPort: Int?

    let configURL: URL
    let router = Router()

    private var server: RouterServer?
    private var dirSource: DispatchSourceFileSystemObject?
    private var reloadTask: Task<Void, Never>?
    private var started = false

    convenience init() {
        self.init(configURL: ConfigStore.resolveConfigURL(), startsWatching: true)
    }

    init(configURL url: URL, startsWatching: Bool = false) {
        self.configURL = url
        let (loaded, shouldPersistMigration) = ConfigStore.loadOrCreate(at: url)
        let (baseNormalized, didNormalizeBaseURLs) = ConfigStore.normalizeBaseURLs(loaded)
        let (merged, didMerge) = ConfigStore.mergeDuplicateRemotes(baseNormalized)
        let (normalizedFakes, didNormalizeFakes) = ConfigStore.normalizeFakes(merged)
        self.config = normalizedFakes
        router.update(self.config)
        Log.shared.log("config: \(url.path) (\(self.config.remotes.count) remotes, \(self.config.fakes.count) fakes)")
        if didNormalizeBaseURLs || didMerge || didNormalizeFakes || shouldPersistMigration {
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
            save()
        }
        if startsWatching { startWatching() }
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
            let key = [r.name, r.apiKey, r.model, endpoints].joined(separator: "\u{1F}")
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
            if let rid = fakes[i].remoteID, let keep = remap[rid] {
                fakes[i].remoteID = keep
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
            if let remoteID = fake.remoteID, !validRemoteIDs.contains(remoteID) {
                fake.remoteID = nil
                changed = true
            }
            if var existing = byID[fake.fakeModelID] {
                changed = true
                if existing.remoteID == nil, fake.remoteID != nil {
                    existing.remoteID = fake.remoteID
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

    /// 文件不存在 → 建目录 + 写默认示例配置；解码失败 → 用默认配置并 log。
    /// 第二个返回值表示磁盘上仍是旧字段结构，需要在内存迁移后强制写回。
    private static func loadOrCreate(at url: URL) -> (AppConfig, Bool) {
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
            return (example, false)
        }
        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(AppConfig.self, from: data)
            return (config, hasLegacyRemoteFields(data))
        } catch {
            Log.shared.log("config: decode failed (\(error)) — falling back to defaults")
            return (AppConfig.example(), false)
        }
    }

    private nonisolated static func hasLegacyRemoteFields(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let remotes = root["remotes"] as? [[String: Any]] else { return false }
        return remotes.contains {
            $0["baseURL"] != nil || $0["endpoint"] != nil || $0["endpoints"] != nil
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    // MARK: 操作

    /// 给指定路由换绑远端；绑定对全部入站 API 格式生效。
    func setRoute(fakeID: UUID, remoteID: UUID?) {
        guard let idx = config.fakes.firstIndex(where: { $0.id == fakeID }) else { return }
        let fake = config.fakes[idx]
        var name = "未配置"
        if let rid = remoteID {
            guard let remote = config.remotes.first(where: { $0.id == rid }) else {
                Log.shared.log("route: 拒绝 — remote \(rid) 不存在")
                return
            }
            name = remote.name
        }
        config.fakes[idx].remoteID = remoteID
        router.update(config)
        save()
        Log.shared.log("route switch: \(fake.fakeModelID) -> \(name)")
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
        config.fakes.move(fromOffsets: source, toOffset: destination)
        router.update(config)
        save()
        Log.shared.log("fake: 排序更新（\(config.fakes.count) 个）")
    }

    /// 行尾展示：当前绑定远端的模型 id（未绑定 → "未配置"）
    func boundModelID(for fake: FakeModel) -> String {
        guard let rid = fake.remoteID,
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
        router.update(config)
        save()
        Log.shared.log("fake: 更新 \(mid) → \(routeName(for: config.fakes[idx]))")
        return nil
    }

    // MARK: 远端

    @discardableResult
    func addRemote(_ remote: RemoteModel) -> String? {
        let endpoints = Self.normalizedEndpoints(remote.apiEndpoints)
        if let error = Self.validateEndpoints(endpoints) { return error }
        var remote = remote
        remote.apiEndpoints = endpoints
        config.remotes.append(remote)
        router.update(config)
        save()
        Log.shared.log("remote: 新增 \(remote.name) → \(remote.endpointSummary)")
        return nil
    }

    /// 新增供应商下的模型：凭据和三协议配置完整复制该供应商当前的统一配置。
    /// 旧配置中这些字段不一致时拒绝新增，必须先通过供应商设置统一。
    @discardableResult
    func addModel(provider: String, model: String) -> String? {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return "模型 ID 不能为空" }
        let members = config.remotes.filter { splitProviderModel($0.name).provider == provider }
        guard let first = members.first else { return "供应商已不存在，请重新打开设置" }
        guard members.allSatisfy({ $0.apiEndpoints == first.apiEndpoints })
        else { return "该供应商的接口配置不一致，请先在供应商设置中统一" }
        guard members.allSatisfy({ $0.apiKey == first.apiKey })
        else { return "该供应商的 API Key 不一致，请先在供应商设置中统一" }
        guard members.allSatisfy({ $0.extraHeaders == first.extraHeaders })
        else { return "该供应商的额外请求头不一致，请先在供应商设置中统一" }
        guard !members.contains(where: { $0.model == model }) else { return "该供应商下模型 ID 已存在" }

        let remote = RemoteModel(id: UUID(), name: "\(provider) · \(model)",
                                 apiKey: first.apiKey, model: model, extraHeaders: first.extraHeaders,
                                 apiEndpoints: first.apiEndpoints)
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

    /// 供应商共用字段一次提交，模型 ID 和路由引用保持不变。
    func updateProvider(_ provider: String, name: String, apiEndpoints: APIEndpointSettings?,
                        apiKey: String?, extraHeaders: [String: String]?) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(" · ") else { return "供应商名称不能为空或包含 · 分隔符" }
        guard name == provider || !config.remotes.contains(where: { splitProviderModel($0.name).provider == name }) else {
            return "该供应商名称已存在"
        }
        if let apiEndpoints, let error = Self.validateEndpoints(apiEndpoints) { return error }
        let indices = config.remotes.indices.filter { splitProviderModel(config.remotes[$0].name).provider == provider }
        guard !indices.isEmpty else { return "供应商已不存在，请重新打开设置" }
        for i in indices {
            config.remotes[i].name = "\(name) · \(config.remotes[i].model)"
            if let apiEndpoints { config.remotes[i].apiEndpoints = apiEndpoints }
            if let apiKey { config.remotes[i].apiKey = apiKey }
            if let extraHeaders { config.remotes[i].extraHeaders = extraHeaders }
        }
        router.update(config)
        save()
        Log.shared.log("provider: 更新 \(name)（\(indices.count) 个模型）")
        return nil
    }

    /// 删除远端并解绑全部引用。返回被解绑的模型 ID 列表。
    @discardableResult
    func removeRemote(id: UUID) -> [String] {
        guard let idx = config.remotes.firstIndex(where: { $0.id == id }) else { return [] }
        let remote = config.remotes.remove(at: idx)
        var unbound: [String] = []
        for i in config.fakes.indices where config.fakes[i].remoteID == id {
            unbound.append(config.fakes[i].fakeModelID)
            config.fakes[i].remoteID = nil
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

        var unbound: [String] = []
        for i in config.fakes.indices {
            guard let remoteID = config.fakes[i].remoteID, ids.contains(remoteID) else { continue }
            unbound.append(config.fakes[i].fakeModelID)
            config.fakes[i].remoteID = nil
        }
        router.update(config)
        save()
        Log.shared.log("provider: 删除 \(provider)（\(removed.count) 个远端，剩 \(config.remotes.count) 个远端）")
        if !unbound.isEmpty {
            Log.shared.log("provider: 解绑 \(unbound.joined(separator: ", "))")
        }
        return unbound
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

    static func isValidHTTPURL(_ raw: String) -> Bool {
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

    func save() {
        do {
            let data = try ConfigStore.encoder.encode(config)
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: configURL, options: .atomic)
        } catch {
            Log.shared.log("config: save failed: \(error)")
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
            let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            let oldPort = config.port
            let (baseNormalized, didNormalizeBaseURLs) = ConfigStore.normalizeBaseURLs(decoded)
            let (merged, didMerge) = ConfigStore.mergeDuplicateRemotes(baseNormalized)
            let (normalizedFakes, didNormalizeFakes) = ConfigStore.normalizeFakes(merged)
            config = normalizedFakes
            router.update(config)
            Log.shared.log("reload: ok (\(config.remotes.count) remotes)")
            if didNormalizeBaseURLs || didMerge || didNormalizeFakes || shouldPersistMigration {
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
                save()
            }
            if decoded.port != oldPort {
                Log.shared.log("reload: port \(oldPort) → \(decoded.port)，需重启生效")
            }
        } catch {
            Log.shared.log("reload: decode failed, 保留旧配置: \(error)")
        }
    }

    // MARK: 登录项（SMAppService 要求 .app bundle；swift run 裸跑时注册会失败，无害）

    var loginItemEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            Log.shared.log("login item: \(loginItemEnabled ? "enabled" : "disabled")")
        } catch {
            Log.shared.log("login item toggle failed: \(error)")
        }
        objectWillChange.send()
    }

    // MARK: 服务

    func startServer() {
        guard !started else { return }
        started = true
        // EZSWITCH_PORT 可覆盖监听端口；兼容旧 MODELROUTER_PORT，便于并行启动调试实例。
        let environment = ProcessInfo.processInfo.environment
        let port = (environment["EZSWITCH_PORT"] ?? environment["MODELROUTER_PORT"])
            .flatMap(Int.init) ?? config.port
        let s = RouterServer(router: router)
        server = s
        do {
            try s.start(port: port)
            runningPort = port
            Log.shared.log("server: listening on http://127.0.0.1:\(port)")
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
        guard let rid = fake.remoteID,
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
}
