import Foundation

enum ClaudeHarnessConfigError: LocalizedError, Equatable {
    case invalidJSON
    case rootNotObject
    case environmentNotObject

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Claude Code 配置文件不是有效 JSON。"
        case .rootNotObject:
            return "Claude Code 配置文件顶层必须是 JSON 对象。"
        case .environmentNotObject:
            return "Claude Code 配置文件中的 env 必须是 JSON 对象。"
        }
    }
}

enum ClaudeHarnessConfig {
    private static let authToken = "ez-switch-local"

    /// Claude Code 可能通过这些变量解析别名或子代理模型；全部指向同一个本机模型，
    /// 避免新增的三个主键被已有配置旁路。
    private static let modelRoutingKeys = [
        "ANTHROPIC_DEFAULT_MODEL",
        "ANTHROPIC_DEFAULT_FABLE_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_SUBAGENT_MODEL",
    ]

    static func configure(_ original: Data?, endpoint: String, modelID: String) throws -> Data {
        var root: [String: Any] = [:]
        if let original {
            let parsed: Any
            do {
                parsed = try JSONSerialization.jsonObject(with: original)
            } catch {
                throw ClaudeHarnessConfigError.invalidJSON
            }
            guard let object = parsed as? [String: Any] else {
                throw ClaudeHarnessConfigError.rootNotObject
            }
            root = object
        }

        var environment: [String: Any]
        if let existing = root["env"] {
            guard let object = existing as? [String: Any] else {
                throw ClaudeHarnessConfigError.environmentNotObject
            }
            environment = object
        } else {
            environment = [:]
        }

        environment["ANTHROPIC_BASE_URL"] = endpoint
        environment["ANTHROPIC_AUTH_TOKEN"] = authToken
        environment["ANTHROPIC_MODEL"] = modelID
        for key in modelRoutingKeys {
            environment[key] = modelID
        }

        root["env"] = environment
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }
}
