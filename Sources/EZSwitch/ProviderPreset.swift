import Foundation

/// 供应商预设（纯数据）：新建供应商时可一键带入的连接配置，不含密钥。
///
/// Base URL 是完整前缀，路由器直接拼接协议相对路径（见 `Forwarder.upstreamURL`）：
/// chat `/chat/completions`、responses `/responses`、messages `/v1/messages`。
/// 因此 messages 的 Base URL 不能以 `/v1` 结尾，否则会拼出 `/v1/v1/messages`。
/// 原生 Gemini 的 Base URL 到 `/v1beta` 为止，路由器再追加 `/models/{model}:generateContent`。
struct ProviderPreset: Identifiable {
    let id: String
    let name: String
    /// 稳定品牌图标 id；同品牌不同套餐共用。
    let iconName: String
    let endpoints: APIEndpointSettings
    let extraHeaders: [String: String]
    /// 搜索别名（中英文品牌词）。
    var aliases: [String] = []

    static let all: [ProviderPreset] = [
        ProviderPreset(
            id: "zhipu-coding",
            name: "智谱 Coding",
            iconName: "zhipu",
            endpoints: make(chat: "https://open.bigmodel.cn/api/coding/paas/v4",
                            messages: "https://open.bigmodel.cn/api/anthropic"),
            extraHeaders: [:],
            aliases: ["zcode", "glm", "bigmodel", "智谱", "z.ai"]
        ),
        ProviderPreset(
            id: "zai-coding",
            name: "Z.AI Coding",
            iconName: "zai",
            endpoints: make(chat: "https://api.z.ai/api/coding/paas/v4",
                            messages: "https://api.z.ai/api/anthropic"),
            extraHeaders: [:],
            aliases: ["zcode", "z.ai", "zai", "glm", "智谱"]
        ),
        ProviderPreset(
            id: "opencode-zen",
            name: "OpenCode Zen",
            iconName: "opencode",
            endpoints: make(chat: "https://opencode.ai/inference/v1",
                            responses: "https://opencode.ai/inference/v1",
                            messages: "https://opencode.ai/inference"),
            extraHeaders: ["x-opencode-client": "ezswitch"],
            aliases: ["opencode", "zen", "console"]
        ),
        ProviderPreset(
            id: "opencode-go",
            name: "OpenCode Go",
            iconName: "opencode",
            endpoints: make(chat: "https://opencode.ai/zen/go/v1",
                            messages: "https://opencode.ai/zen/go"),
            extraHeaders: ["x-opencode-client": "ezswitch"],
            aliases: ["opencode", "go"]
        ),
        // messages 的 base 不含 /v1：/v1/messages 由路由器补齐。
        ProviderPreset(
            id: "commandcode",
            name: "Command Code",
            iconName: "commandcode",
            endpoints: make(chat: "https://api.commandcode.ai/provider/v1",
                            responses: "https://api.commandcode.ai/provider/v1",
                            messages: "https://api.commandcode.ai/provider"),
            extraHeaders: [:],
            aliases: ["command code", "commandcode", "cmd"]
        ),
        ProviderPreset(
            id: "openai",
            name: "OpenAI",
            iconName: "openai",
            endpoints: make(chat: "https://api.openai.com/v1",
                            responses: "https://api.openai.com/v1"),
            extraHeaders: [:],
            aliases: ["gpt", "chatgpt"]
        ),
        ProviderPreset(
            id: "anthropic",
            name: "Anthropic",
            iconName: "anthropic",
            endpoints: make(messages: "https://api.anthropic.com"),
            extraHeaders: [:],
            aliases: ["claude"]
        ),
        ProviderPreset(
            id: "gemini",
            name: "Gemini",
            iconName: "google",
            // chat 走 OpenAI 兼容前缀；gemini 走原生 generateContent（base 只到 /v1beta）。
            endpoints: make(chat: "https://generativelanguage.googleapis.com/v1beta/openai",
                            gemini: "https://generativelanguage.googleapis.com/v1beta"),
            extraHeaders: [:],
            aliases: ["google", "google ai", "gemini", "谷歌"]
        ),
        ProviderPreset(
            id: "deepseek",
            name: "DeepSeek",
            iconName: "deepseek",
            endpoints: make(chat: "https://api.deepseek.com/v1",
                            messages: "https://api.deepseek.com/anthropic"),
            extraHeaders: [:],
            aliases: ["deepseek", "深度求索"]
        ),
        // Kimi 开放平台按量计费；与下面的 Coding 套餐不能混用。
        ProviderPreset(
            id: "kimi",
            name: "Kimi",
            iconName: "kimi",
            endpoints: make(chat: "https://api.moonshot.cn/v1"),
            extraHeaders: [:],
            aliases: ["moonshot", "月之暗面", "moonshot cn", "kimi"]
        ),
        ProviderPreset(
            id: "kimi-coding",
            name: "Kimi Coding",
            iconName: "kimi",
            endpoints: make(chat: "https://api.kimi.com/coding/v1",
                            messages: "https://api.kimi.com/coding"),
            extraHeaders: [:],
            aliases: ["kimi code", "kimicode", "kimi coding", "月之暗面", "moonshot"]
        ),
        ProviderPreset(
            id: "minimax",
            name: "MiniMax（国内）",
            iconName: "minimax",
            endpoints: make(chat: "https://api.minimax.cn/v1",
                            messages: "https://api.minimax.cn/anthropic"),
            extraHeaders: [:],
            aliases: ["minimax", "海螺", "minimaxi", "国内"]
        ),
        ProviderPreset(
            id: "minimax-overseas",
            name: "MiniMax（海外）",
            iconName: "minimax",
            endpoints: make(chat: "https://api.minimax.io/v1",
                            messages: "https://api.minimax.io/anthropic"),
            extraHeaders: [:],
            aliases: ["minimax", "minimax.io", "海外", "overseas"]
        ),
        ProviderPreset(
            id: "bailian",
            name: "阿里云百炼",
            iconName: "alibaba",
            endpoints: make(chat: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                            messages: "https://dashscope.aliyuncs.com/apps/anthropic"),
            extraHeaders: [:],
            aliases: ["alibaba", "aliyun", "dashscope", "百炼", "通义", "qwen"]
        ),
        ProviderPreset(
            id: "siliconflow",
            name: "SiliconFlow",
            iconName: "siliconflow",
            endpoints: make(chat: "https://api.siliconflow.cn/v1",
                            messages: "https://api.siliconflow.cn"),
            extraHeaders: [:],
            aliases: ["siliconflow", "硅基流动", "silicon"]
        ),
        ProviderPreset(
            id: "openrouter",
            name: "OpenRouter",
            iconName: "openrouter",
            endpoints: make(chat: "https://openrouter.ai/api/v1",
                            responses: "https://openrouter.ai/api/v1",
                            messages: "https://openrouter.ai/api"),
            extraHeaders: [:],
            aliases: ["openrouter", "or"]
        ),
    ]

    /// 只启用传入的协议，其余禁用；nil 或空串视为禁用。
    private static func make(chat: String? = nil,
                             responses: String? = nil,
                             messages: String? = nil,
                             gemini: String? = nil) -> APIEndpointSettings {
        APIEndpointSettings(chat: setting(chat), responses: setting(responses),
                            messages: setting(messages), gemini: setting(gemini))
    }

    private static func setting(_ url: String?) -> EndpointSetting {
        guard let url, !url.isEmpty else { return .disabled }
        return EndpointSetting(enabled: true, baseURL: url)
    }
}

extension ProviderPreset {
    /// name / id / aliases 任一包含查询串（大小写不敏感）即命中；空查询匹配全部。
    func matches(query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return name.lowercased().contains(q)
            || id.lowercased().contains(q)
            || aliases.contains { $0.lowercased().contains(q) }
    }
}

/// 已存在供应商 → 品牌图标的判定结果。
enum ProviderBrand: Equatable {
    /// 命中 catalog 品牌，值为 `ProviderPreset.iconName`。
    case known(String)
    /// 无法可靠识别（自定义 / 混用 / 冲突）：调用方改用中性图标。
    case unknown

    /// 品牌图标 key；`.unknown` 为 nil。
    var iconName: String? {
        if case .known(let name) = self { return name }
        return nil
    }
}

/// 把已存在的供应商分组解析到品牌图标：优先按启用的 API Base URL host 精确识别，
/// 识别不到时再用供应商名做严格品牌匹配。纯函数、无状态，直接复用
/// `ProviderPreset.all` 的 endpoints / iconName，不另建品牌库。
///
/// 安全边界：
/// - host 只做**整串相等**（大小写不敏感），绝不用后缀 / 子串，避免 `api.deepseek.com.evil` 冒认。
/// - 名称只做整串相等（预设名 / id / 受控别名），绝不用子串，且忽略过短的通用别名（go / or / glm …）。
/// - 任一 host 未知、或同一供应商的 host 指向不同品牌时都不猜。
enum ProviderBrandResolver {
    /// 供应商分组：先 URL 后名称。
    static func resolve(_ group: RemoteGroup) -> ProviderBrand {
        resolve(provider: group.provider, remotes: group.remotes)
    }

    static func resolve(provider: String, remotes: [RemoteModel]) -> ProviderBrand {
        let hosts = enabledHosts(in: remotes)
        if !hosts.isEmpty {
            let brands = hosts.compactMap(brand(forHost:))
            if brands.count == hosts.count {
                // 全部 host 都精确命中，且同属一个品牌 → 认定。
                let unique = Set(brands)
                if unique.count == 1, let brand = unique.first { return .known(brand) }
                return .unknown   // 不同品牌混用 → 不猜
            }
            // 有已知品牌与未知 host 混用 → 不猜；仅当完全没有可识别 host 时才退化到名称。
            guard brands.isEmpty else { return .unknown }
        }
        if let brand = nameBrand(for: provider) { return .known(brand) }
        return .unknown
    }

    // MARK: - URL 识别

    /// catalog 中每个品牌启用的 host（精确、小写）。同一 host 对应多个不同品牌时记为
    /// 歧义，不参与识别（避免共享 / 相似域名冒认）。
    private static let brandsByHost: [String: Set<String>] = {
        var map: [String: Set<String>] = [:]
        for preset in ProviderPreset.all {
            for kind in EndpointKind.allCases {
                let setting = preset.endpoints[kind]
                guard setting.enabled, let host = host(of: setting.baseURL) else { continue }
                map[host, default: []].insert(preset.iconName)
            }
        }
        return map
    }()

    /// host → 唯一品牌；未知或歧义返回 nil。
    static func brand(forHost host: String) -> String? {
        guard let brands = brandsByHost[host.lowercased()], brands.count == 1 else { return nil }
        return brands.first
    }

    /// 启用协议的有效 Base URL host，按首现去重；禁用 / 空地址不计（`endpointBaseURLs` 已过滤）。
    private static func enabledHosts(in remotes: [RemoteModel]) -> [String] {
        var seen = Set<String>()
        var hosts: [String] = []
        for remote in remotes {
            for url in remote.endpointBaseURLs {
                guard let host = host(of: url), seen.insert(host).inserted else { continue }
                hosts.append(host)
            }
        }
        return hosts
    }

    private static func host(of urlString: String) -> String? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        return host
    }

    // MARK: - 名称识别（兜底）

    /// 供应商名与预设名 / id / 受控别名整串相等时命中品牌。
    /// 只做整串比较、绝不做子串包含；忽略短于 4 字符的通用别名。
    static func nameBrand(for provider: String) -> String? {
        let target = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return nil }
        var brands = Set<String>()
        for preset in ProviderPreset.all {
            let aliasHit = preset.aliases.contains { $0.count >= 4 && $0.lowercased() == target }
            if preset.name.lowercased() == target
                || preset.id.lowercased() == target
                || aliasHit {
                brands.insert(preset.iconName)
            }
        }
        return brands.count == 1 ? brands.first : nil
    }
}
