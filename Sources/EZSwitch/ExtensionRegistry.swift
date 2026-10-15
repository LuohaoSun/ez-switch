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
}

protocol ClientRequestFailure: Error {
    var clientError: Bool { get }
}

struct ConnectorUnavailable: Error, LocalizedError, CustomStringConvertible {
    let source: RemoteSource
    var description: String { "扩展连接不可用：\(source.rawValue)" }
    var errorDescription: String? { description }
}

struct ConnectorDefinition: Sendable {
    let source: RemoteSource
    let settingsKey: String
    let displayName: String
    let endpoints: Set<EndpointKind>
    let forward: @Sendable (ConnectorRequest) async throws -> UpstreamResponse
    let fetchModels: @Sendable () async throws -> [String]
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
        guard let definition = definitions[remote.source], definition.endpoints.contains(endpoint) else {
            return false
        }
        return settings.connectorSettings(for: definition.settingsKey)
            .routes(provider: splitProviderModel(remote.name).provider)
    }

    func fetchModels(source: RemoteSource) async throws -> [String] {
        guard let definition = definitions[source] else { throw ConnectorUnavailable(source: source) }
        return try await definition.fetchModels()
    }

    func forward(_ request: ConnectorRequest, source: RemoteSource) async throws -> UpstreamResponse {
        guard let definition = definitions[source] else { throw ConnectorUnavailable(source: source) }
        return try await definition.forward(request)
    }
}
