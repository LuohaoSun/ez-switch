import Foundation

// The persisted source string remains unchanged so existing model UUIDs and route bindings survive.
enum CursorExtension {
    static let source = RemoteSource(rawValue: "cursorCLI")
    static let settingsKey = "cursorConnector"
    static let displayName = "Cursor"
    static let proxyVersion = "8.0.28-2"

    static func connector(
        endpoint: @escaping @Sendable () async throws -> CursorProxyEndpoint = {
            try await CursorSidecarClient.shared.requestEndpoint()
        },
        session: URLSession = CursorForwarder.session,
        models: @escaping @Sendable () async throws -> [String] = {
            try await CursorConnectionModel.shared.catalog()
        }
    ) -> ConnectorDefinition {
        ConnectorDefinition(
            source: source,
            settingsKey: settingsKey,
            displayName: displayName,
            endpoints: [.chat, .responses, .messages],
            forward: { request in
                try await CursorForwarder.makeRequest(request, endpoint: try await endpoint(), session: session)
            },
            fetchModels: models)
    }
}

extension RemoteSource {
    static let cursorProxy = CursorExtension.source
}

struct CursorConnectorError: LocalizedError {
    let reason: String?
    var errorDescription: String? {
        reason.map { "Cursor 连接不可用：\($0)" } ?? "Cursor 当前不可用，请先在“扩展”页连接"
    }
}
