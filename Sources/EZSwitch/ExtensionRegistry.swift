import Foundation
import Dispatch
import NIOHTTP1

/// A connector receives the same immutable request snapshot as an HTTP upstream.
struct ConnectorRequest {
    let clientHead: HTTPRequestHead
    let body: Data
    let endpoint: EndpointKind
    let remote: RemoteModel
    let query: String
    let requestStart: DispatchTime?
    let attemptStart: DispatchTime?
    /// 本次转发的出站策略（直连 / 代理）；由候选快照解析，连接器据此选择出口。
    var outboundPolicy: OutboundPolicy = .direct
}

protocol ClientRequestFailure: Error {
    var clientError: Bool { get }
}

struct ConnectorUnavailable: Error, LocalizedError, CustomStringConvertible {
    let source: RemoteSource
    var description: String { "扩展连接不可用：\(source.rawValue)" }
    var errorDescription: String? { description }
}

/// 显式出站代理被拒：连接器未声明支持时绝不静默走直连。
struct ConnectorProxyUnsupported: Error, LocalizedError, CustomStringConvertible {
    let source: RemoteSource
    var description: String { "扩展连接不支持出站代理：\(source.rawValue)" }
    var errorDescription: String? { description }
}

struct ConnectorDefinition: Sendable {
    let source: RemoteSource
    let settingsKey: String
    let displayName: String
    let endpoints: Set<EndpointKind>
    let forward: @Sendable (ConnectorRequest) async throws -> UpstreamResponse
    let fetchModels: @Sendable () async throws -> [String]
    /// 该连接器是否支持出站代理；false 时收到显式代理策略必须抛错。
    var supportsOutboundProxy: Bool = false
    /// 感知出站策略的取模型实现；仅在声明支持时使用，缺省视为不支持。
    var fetchModelsWithPolicy: (@Sendable (OutboundPolicy) async throws -> [String])? = nil
}

/// Immutable registrations; readiness belongs to each router, not this catalog.
struct ExtensionRegistry: Sendable {
    static let builtIn = ExtensionRegistry(connectors: BuiltinExtensions.connectors)
    private let definitions: [RemoteSource: ConnectorDefinition]

    init(connectors: [ConnectorDefinition] = []) {
        precondition(!connectors.contains { $0.source == .api }, "The API source is reserved")
        precondition(!connectors.contains { $0.settingsKey == "chatToResponses" },
                     "Protocol adapter settings cannot be used by a connector")
        precondition(Set(connectors.map(\.source)).count == connectors.count,
                     "Duplicate connector source")
        precondition(Set(connectors.map(\.settingsKey)).count == connectors.count,
                     "Duplicate connector settings key")
        definitions = Dictionary(uniqueKeysWithValues: connectors.map { ($0.source, $0) })
    }

    func connector(for source: RemoteSource) -> ConnectorDefinition? { definitions[source] }

    var registeredConnectors: [ConnectorDefinition] {
        definitions.values.sorted { $0.source.rawValue < $1.source.rawValue }
    }

    func supports(_ endpoint: EndpointKind, remote: RemoteModel,
                  settings: ExtensionSettings) -> Bool {
        guard let definition = definitions[remote.source],
              definition.endpoints.contains(endpoint) else {
            return false
        }
        let connector = settings.connectorSettings(for: definition.settingsKey)
        guard connector.routes(provider: splitProviderModel(remote.name).provider) else {
            return false
        }
        // 现有可用性（注册 + 已开启 + 已绑定）之上再叠「能力 ∩ 配置」：
        // 未配置继承该来源注册全集，显式集合按成员判定，空集即全关。
        return connector.allows(endpoint)
    }

    func fetchModels(source: RemoteSource,
                     outboundPolicy: OutboundPolicy = .direct) async throws -> [String] {
        guard let definition = definitions[source] else { throw ConnectorUnavailable(source: source) }
        if case .invalid(let reason) = outboundPolicy { throw OutboundTransportError.invalidPolicy(reason) }
        // 显式代理要求连接器声明支持且提供 policy 闭包，缺一即抛错，绝不静默降级直连。
        if case .proxy = outboundPolicy,
           !definition.supportsOutboundProxy || definition.fetchModelsWithPolicy == nil {
            throw ConnectorProxyUnsupported(source: source)
        }
        // 声明了 policy 闭包（含 direct）就传本次快照策略，避免闭包读取全局状态。
        if let fetch = definition.fetchModelsWithPolicy { return try await fetch(outboundPolicy) }
        return try await definition.fetchModels()
    }

    func forward(_ request: ConnectorRequest, source: RemoteSource) async throws -> UpstreamResponse {
        guard let definition = definitions[source] else { throw ConnectorUnavailable(source: source) }
        // 后端兜底：显式代理要求支持，无效地址一律拒绝，避免连接器漏实现时静默直连。
        switch request.outboundPolicy {
        case .direct:
            break
        case .proxy:
            guard definition.supportsOutboundProxy else { throw ConnectorProxyUnsupported(source: source) }
        case .invalid(let reason):
            throw OutboundTransportError.invalidPolicy(reason)
        }
        return try await definition.forward(request)
    }
}
